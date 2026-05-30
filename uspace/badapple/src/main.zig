// badapple: the real Touhou "Bad Apple!!" shadow-art PV, rendered live on
// ferrite-gpu. Nothing here is a stored video. The frames are a compact
// vector stream (initrd/badapple.vec): per frame, a set of polygon contours
// traced offline from the PV. At runtime we rasterize those polygons
// ourselves with an even-odd scanline fill, one frame at a time, into a small
// cached backbuffer, then scale-blit to the shared GPU framebuffer. So the OS
// is genuinely drawing each frame, not blitting pixels someone else baked.
//
// .vec format (little-endian):
//   magic "FBA1", u16 width, u16 height, u16 interval_ms, u16 reserved,
//   u32 frame_count, then per frame:
//     u16 ring_count, then per ring: u16 vert_count, vert_count x {u16 x, u16 y}
// Rings describe the dark regions of the source (potrace foreground), so they
// fill black on a white canvas: even-odd fill turns nested rings into holes.

const std = @import("std");
const ferrite = std.os.ferrite;
const gpu = @import("ferrite-gpu");
const audio = @import("ferrite-audio");
const synth = @import("synth.zig");

pub const panic = ferrite.panic;

const RW = 320;
const RH = 240;
const N = RW * RH;
const WHITE: u32 = 0xFFFFFF;
const BLACK: u32 = 0x000000;

// Per-frame scratch bounds. The encoder's worst case is ~80 rings and ~200
// verts in a single ring, a few hundred verts per frame; these leave headroom.
const MAX_RINGS = 256;
const MAX_VERTS = 8192;
const MAX_XSECT = 512;

// The polygon stream, compiled into the binary (rodata) at build time. No
// runtime initrd read, no multi-MB scratch buffer; the header is parsed at
// comptime below.
const vec = @embedFile("video.bin");

// 16-byte aligned so the NEON @Vector(4, u32) blit/fill paths can issue
// aligned q-stores without a head/tail scalar prologue.
var back: [N]u32 align(16) = undefined;

// Current frame's geometry, unpacked from the stream.
var ring_off: [MAX_RINGS + 1]u32 = undefined;
var vx: [MAX_VERTS]i32 = undefined;
var vy: [MAX_VERTS]i32 = undefined;
var nrings: u32 = 0;

// Per-frame edge table for an active-edge-table scanline fill. Each edge is
// bucketed by its first canvas scanline; the rasterize loop adds those edges
// to a live "active" set as it descends, drops them when they go inactive, and
// walks ONLY that set per scanline (instead of all edges, every scanline).
// x and dxdy are 16.16 fixed point so per-scanline advance is one integer add
// (one divide per edge in buildEdges; nothing else floats). For complex frames
// this drops rasterize from O(RH * total_edges) to roughly O(total_edge_spans).
const Edge = struct { ymax: i32, x: i32, dxdy: i32 };
var edges: [MAX_VERTS]Edge = undefined;
var enext: [MAX_VERTS]i32 = undefined; // intrusive linked list inside each bucket
var bucket_head: [RH]i32 = undefined;
var nedges: u32 = 0;
// AET working set + per-scanline crossing list, sized to the worst case (every
// edge active and crossing at once) so we never drop a crossing.
var active: [MAX_VERTS]Edge = undefined;
var xs: [MAX_VERTS]i32 = undefined;

fn buildEdges() void {
    nedges = 0;
    var b: usize = 0;
    while (b < RH) : (b += 1) bucket_head[b] = -1;
    var ri: u32 = 0;
    while (ri < nrings) : (ri += 1) {
        const base = ring_off[ri];
        const cnt = ring_off[ri + 1] - base;
        var i: u32 = 0;
        while (i < cnt) : (i += 1) {
            const a = base + i;
            const c = base + (i + 1) % cnt;
            var y0 = vy[a];
            var y1 = vy[c];
            if (y0 == y1) continue; // horizontal: never crosses a scanline
            var x0 = vx[a];
            var x1 = vx[c];
            if (y0 > y1) {
                const ty = y0;
                y0 = y1;
                y1 = ty;
                const tx = x0;
                x0 = x1;
                x1 = tx;
            }
            // Cull edges entirely outside the canvas.
            if (y1 <= 0 or y0 >= RH) continue;
            const dxdy = @divTrunc((x1 - x0) << 16, y1 - y0);
            // Clamp the edge's first scanline to 0 (advancing x by dxdy for
            // each clamped row) and ymax to RH so AET termination is O(1)
            // against the canvas, not the unbounded polygon coords.
            const by: i32 = if (y0 < 0) 0 else y0;
            const x_at_by: i32 = (x0 << 16) + (by - y0) * dxdy;
            const ymax_eff: i32 = if (y1 > RH) RH else y1;
            edges[nedges] = .{ .ymax = ymax_eff, .x = x_at_by, .dxdy = dxdy };
            const bu: usize = @intCast(by);
            enext[nedges] = bucket_head[bu];
            bucket_head[bu] = @intCast(nedges);
            nedges += 1;
        }
    }
}

inline fn readU16(off: usize) u32 {
    return @as(u32, vec[off]) | (@as(u32, vec[off + 1]) << 8);
}
inline fn readU32(off: usize) u32 {
    return readU16(off) | (readU16(off + 2) << 16);
}

const DATA_START = 16;
// Header fields are comptime-known since `vec` is comptime-known.
const interval_ms: u32 = readU16(8);
const frame_count: u32 = readU32(12);

comptime {
    if (vec.len < DATA_START or !std.mem.eql(u8, vec[0..4], "FBA1")) @compileError("badapple.vec: bad magic/size");
    if (readU16(4) != RW or readU16(6) != RH) @compileError("badapple.vec: dimensions != 320x240");
}

// Parse the frame at byte `cur` into the scratch arrays, returning the next
// frame's offset. Rings/verts beyond the scratch caps are skipped, not stored.
fn parseFrame(cur: usize) usize {
    var off = cur;
    const rc = readU16(off);
    off += 2;
    nrings = 0;
    var vcount: u32 = 0;
    var ri: u32 = 0;
    while (ri < rc) : (ri += 1) {
        const vc = readU16(off);
        off += 2;
        const room = nrings < MAX_RINGS and vcount + vc <= MAX_VERTS;
        if (room) ring_off[nrings] = vcount;
        var vi: u32 = 0;
        while (vi < vc) : (vi += 1) {
            if (room) {
                vx[vcount] = @intCast(readU16(off));
                vy[vcount] = @intCast(readU16(off + 2));
                vcount += 1;
            }
            off += 4;
        }
        if (room) nrings += 1;
    }
    ring_off[nrings] = vcount;
    return off;
}

fn rasterize() void {
    @memset(&back, WHITE);
    buildEdges();
    var nact: u32 = 0;
    var y: i32 = 0;
    while (y < RH) : (y += 1) {
        // Add edges whose first canvas scanline is y.
        var ei = bucket_head[@as(usize, @intCast(y))];
        while (ei >= 0) {
            const eu: u32 = @intCast(ei);
            active[nact] = edges[eu];
            nact += 1;
            ei = enext[eu];
        }
        // Drop edges that no longer cross this scanline (ymax <= y).
        var w: u32 = 0;
        var r: u32 = 0;
        while (r < nact) : (r += 1) {
            if (active[r].ymax > y) {
                active[w] = active[r];
                w += 1;
            }
        }
        nact = w;
        // Collect crossings: each active edge crosses exactly once at this y.
        var k: u32 = 0;
        while (k < nact) : (k += 1) {
            xs[k] = (active[k].x + 0x8000) >> 16;
        }
        // Insertion sort the crossings, then fill black between pairs.
        var i: u32 = 1;
        while (i < nact) : (i += 1) {
            const v = xs[i];
            var j: i32 = @as(i32, @intCast(i)) - 1;
            while (j >= 0 and xs[@intCast(j)] > v) : (j -= 1) {
                xs[@intCast(j + 1)] = xs[@intCast(j)];
            }
            xs[@intCast(j + 1)] = v;
        }
        const row: u32 = @as(u32, @intCast(y)) * RW;
        var kk: u32 = 0;
        while (kk + 1 < nact) : (kk += 2) {
            var xa = xs[kk];
            var xb = xs[kk + 1];
            if (xa < 0) xa = 0;
            if (xb > RW) xb = RW;
            var x: u32 = @intCast(xa);
            const xe: u32 = @intCast(xb);
            // Scalar head until 16-byte aligned in the row.
            while (x < xe and (x & 3) != 0) : (x += 1) back[row + x] = BLACK;
            // 4-wide NEON fill for the bulk of the span. This is what wins back
            // the time on Bad Apple's wide black silhouettes.
            const VBLACK: @Vector(4, u32) = @splat(BLACK);
            while (x + 4 <= xe) : (x += 4) {
                const dst: *@Vector(4, u32) = @ptrCast(@alignCast(&back[row + x]));
                dst.* = VBLACK;
            }
            while (x < xe) : (x += 1) back[row + x] = BLACK;
        }
        // Advance each active edge's x for the next scanline.
        k = 0;
        while (k < nact) : (k += 1) active[k].x += active[k].dxdy;
    }
}

// 1:1 copy of the cached backbuffer into the GPU framebuffer. The framebuffer
// is Device memory, so writes MUST be aligned word stores (a wide/@memcpy copy
// faults with EC=0x24 alignment). Aligned NEON q-stores are fine: 16 bytes,
// 16-byte aligned, no misalignment. Native 320x240 = 76800 stores; the 4-wide
// NEON path drops it to 19200, the dominant per-frame cost in TCG.
fn blit(fb: *gpu.Buffer) void {
    const pitch = fb.stride / 4;
    const w = @min(fb.width, RW);
    const h = @min(fb.height, RH);
    const wv: u32 = w & ~@as(u32, 3); // largest multiple of 4 <= w
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const srow = y * RW;
        const drow = y * pitch;
        var x: u32 = 0;
        while (x < wv) : (x += 4) {
            const src: *const @Vector(4, u32) = @ptrCast(@alignCast(&back[srow + x]));
            const dst: *@Vector(4, u32) = @ptrCast(@alignCast(&fb.pixels[drow + x]));
            dst.* = src.*;
        }
        // Tail: w isn't a multiple of 4 (rare; RW=320 is, but fb.width may
        // differ if the driver clamped).
        while (x < w) : (x += 1) fb.pixels[drow + x] = back[srow + x];
    }
}

// ----- Audio: our own softsynth feeding the PCM sink -----
//
// The synth + score (synth.zig, score.bin) live here, in the app, not in the
// driver: drv.virtio-sound is a generic sink, so any program plays its own
// sounds. We run the synth on a dedicated thread because writePeriod blocks at
// the device's real-time drain rate (~46 ms/period), which would otherwise
// stall the video loop. Both threads pace to the wall clock independently, so
// the picture stays in sync with the music.

var audio_buf: [audio.PERIOD_SAMPLES]i16 = undefined;
const AUDIO_STACK_PAGES = 16;
// Connected by the main (video) thread before this thread is spawned, so the
// connect's cap-table churn never races a present. See connectAudioStep().
var g_sink: audio.Sink = undefined;
// Shared wall-clock origin (set by main before the video loop) so audio and
// video are paced from the SAME t=0 and stay in sync.
var g_start: u64 = 0;

// One audio period's real-time duration.
const PERIOD_NS: u64 = @as(u64, audio.PERIOD_FRAMES) * std.time.ns_per_s / audio.RATE;
// How many periods we keep queued ahead of the wall clock (jitter cushion).
const AUDIO_LEAD: u64 = 4;

fn audioThread() callconv(.c) noreturn {
    // Above the video thread (rt_mid) so a refill always wins the CPU. It is
    // almost always blocked in writePeriod/nanosleep anyway, so video does not
    // starve. This thread NEVER mutates the cap table (writePeriod is a
    // fire-and-forget send with no cap transfer), so it cannot race the video
    // thread's present capDup on our shared, unlocked process cap table.
    _ = ferrite.setThreadPriority(.rt_high);

    // Play the score from the start, paced to real time (one period per
    // PERIOD_NS, at most AUDIO_LEAD ahead). The pacing keeps us from rendering
    // full-speed and piling up audio; the VIDEO follows this stream's true play
    // cursor (see the video loop), so the picture stays locked to whatever is
    // actually being heard no matter how the host backend buffers. The cursor
    // counts periods played from row 0, so we must NOT seek - it maps straight
    // to song position.
    const a_start = ferrite.clockMono();
    var produced: u64 = 0;
    while (true) {
        const due_ns = (produced -| AUDIO_LEAD) * PERIOD_NS;
        const now = ferrite.clockMono() - a_start;
        if (now < due_ns) ferrite.nanosleep(due_ns - now);
        synth.render(&audio_buf, audio.PERIOD_FRAMES);
        g_sink.writePeriod(&audio_buf) catch {
            ferrite.nanosleep(10 * std.time.ns_per_ms);
        };
        produced += 1;
    }
}

fn spawnAudioThread() void {
    var stack_va: usize = 0;
    if (ferrite.allocPages(AUDIO_STACK_PAGES, &stack_va) != 0) {
        ferrite.console.print("[badapple] audio stack alloc failed\n", .{}) catch {};
        return;
    }
    const stack_top = stack_va + AUDIO_STACK_PAGES * ferrite.pageSize() - 16;
    _ = ferrite.threadSpawn(@intFromPtr(&audioThread), stack_top);
}

// State for the main thread's once-per-frame attempt to bring up audio. The
// connect (and its channelCreate/send) runs on the SAME thread as present, so
// the two never mutate the unlocked cap table concurrently. Once connected we
// hand off to audioThread, which from then on only sends (no cap churn).
var audio_ready = false;
var audio_done = false;
var audio_tries: u32 = 0;

fn connectAudioStep() void {
    if (audio_ready or audio_done) return;
    if (audio.Sink.connect()) |s| {
        g_sink = s;
        ferrite.console.print("[badapple] audio connected, synth playing\n", .{}) catch {};
        spawnAudioThread();
        audio_ready = true;
    } else |_| {
        audio_tries += 1;
        if (audio_tries > 400) { // ~13 s of frames; the sink never appeared
            ferrite.console.print("[badapple] no audio sink, playing video only\n", .{}) catch {};
            audio_done = true;
        }
    }
}

pub fn main() void {
    ferrite.console.print("[badapple] booting\n", .{}) catch {};

    // Bind the synth's loop to the video's wall-clock period so audio and
    // video wrap together. The synth zero-pads with silence past the score's
    // last row, so even when the MIDI transcription is slightly shorter than
    // the PV the next iteration starts with both lined up on row 0 + frame 0.
    synth.loop_samples = @as(u64, frame_count) * @as(u64, interval_ms) * @as(u64, audio.RATE) / 1000;
    var dev: gpu.Device = blk: {
        var tries: u32 = 0;
        while (tries < 300) : (tries += 1) {
            if (gpu.Device.connect()) |d| break :blk d else |_| {}
            ferrite.nanosleep(50 * std.time.ns_per_ms);
        }
        ferrite.console.print("[badapple] no drv.virtio-gpu\n", .{}) catch {};
        return;
    };

    var fb = dev.createBuffer(0, RW, RH) catch {
        ferrite.console.print("[badapple] createBuffer failed\n", .{}) catch {};
        return;
    };
    ferrite.console.print("[badapple] gpu buffer {d}x{d}\n", .{ fb.width, fb.height }) catch {};

    // Video runs at rt_mid - below the audio thread (rt_high), above
    // login/idle. The scheduler doing real-time work is the whole point.
    _ = ferrite.setThreadPriority(.rt_mid);

    ferrite.console.print("[badapple] {d} frames {d}x{d} -> {d}x{d} (video {d} KB + score {d} KB)\n", .{ frame_count, RW, RH, fb.width, fb.height, vec.len / 1024, synth.score.len / 1024 }) catch {};

    // Sync to the wall clock instead of "render every frame in order". The
    // frame that should be on screen now is elapsed/interval; if rasterizing
    // fell behind real time we parse-skip (drop) the intermediate frames and
    // draw only the current one. Audio is also wall-clock paced, so dropping
    // video frames keeps the picture locked to the music rather than drifting.
    const target_ns: u64 = @as(u64, interval_ms) * std.time.ns_per_ms;
    // Shared origin for both the video loop and the audio thread so they pace
    // from the same t=0 and stay locked together.
    g_start = ferrite.clockMono();
    var cur: usize = DATA_START;
    var stream_idx: u32 = 0; // index of the NEXT frame to parse out of the stream
    var shown: i64 = -1; // absolute index of the frame currently on screen
    while (true) {
        const elapsed = ferrite.clockMono() - g_start;
        var want: i64 = @intCast(elapsed / target_ns); // wall-clock ceiling
        // Audio-master sync: drive the frame from the device's TRUE play
        // cursor so the picture is locked to what's actually being heard,
        // regardless of how deep the host audio backend buffers. Clamp to the
        // wall clock so an instant-completion backend (audiodev=none) can't run
        // the video faster than real time; fall back to wall clock with no
        // cursor / no audio.
        if (audio_ready and g_sink.hasCursor()) {
            const played = g_sink.playedFrames();
            const af: i64 = @intCast(@as(u128, played) * 1000 / (@as(u128, audio.RATE) * @as(u128, interval_ms)));
            if (af < want) want = af;
        }
        if (want > shown) {
            // Advance to `want`, parse-skipping (not rasterizing) the frames we
            // are behind, wrapping the stream when we pass the end.
            while (shown < want) {
                if (stream_idx >= frame_count) {
                    stream_idx = 0;
                    cur = DATA_START;
                }
                cur = parseFrame(cur);
                stream_idx += 1;
                shown += 1;
            }
            rasterize();
            blit(&fb);
            dev.present(0, 0, 0, fb.width, fb.height) catch {};
        }
        // Bring up audio on this same thread (so its connect never races a
        // present on the unlocked cap table); hands off to audioThread once up.
        connectAudioStep();
        // Sleep until the next frame boundary on the wall clock.
        const next_ns: u64 = @as(u64, @intCast(shown + 1)) * target_ns;
        const now = ferrite.clockMono() - g_start;
        if (now < next_ns) ferrite.nanosleep(next_ns - now);
    }
}
