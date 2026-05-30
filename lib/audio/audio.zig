//! ferrite-audio: client library for drv.virtio-sound.
//!
//! The driver is a raw PCM sink. It owns the virtio-snd device and a ring of
//! TX period buffers and does NO synthesis of its own. Any program produces
//! its own audio (a softsynth, a decoder, a plain tone) and streams
//! interleaved S16LE stereo periods here; the driver copies each into a free
//! TX slot and hands it to the device.
//!
//! `writePeriod` is fire-and-forget: it just sends the PCM into the driver's
//! channel, whose buffer holds a few periods. When the driver falls behind and
//! that buffer fills, `send` blocks until the driver drains one - so the
//! producer is paced to the device's real-time rate without any reply, and a
//! caller can just loop `{ render; writePeriod }`. Crucially there is NO
//! per-period capability transfer: the hot loop never touches the process cap
//! table, so it is safe to run on its own thread alongside another thread
//! (e.g. a video loop) doing its own RPCs.
//!
//! Play cursor: at connect() the driver grants a small shared page that it
//! updates with the count of periods it has actually PLAYED (handed to the
//! host backend). A caller can read `playedFrames()` to drive a video clock
//! off true audio playback instead of the wall clock - so A/V stay locked
//! regardless of how deeply the host audio backend (e.g. pulseaudio) buffers.

const std = @import("std");
const ferrite = std.os.ferrite;
const syscall = ferrite.syscall;
const p9 = ferrite.p9;

/// Nameserver URI the driver registers under.
pub const URI = "com.midstall.ferrite.audio@v0";

pub const RATE: u32 = 44100;
pub const CHANNELS: u32 = 2;
/// Frames per period. MUST match the driver's PERIOD_FRAMES. One period is
/// PERIOD_SAMPLES i16s (PERIOD_FRAMES * CHANNELS), PERIOD_BYTES on the wire.
pub const PERIOD_FRAMES: u32 = 2048;
pub const PERIOD_SAMPLES: u32 = PERIOD_FRAMES * CHANNELS;
pub const PERIOD_BYTES: u32 = PERIOD_SAMPLES * 2;

/// Shared play-cursor page (driver writes, client reads). Device/uncached, so
/// a naturally-aligned u64 store/load is coherent without explicit barriers.
pub const Cursor = extern struct {
    /// Periods the device has handed to the host backend (i.e. played).
    played_periods: u64,
};

/// A connect message carrying this 4-byte payload (plus a reply cap) asks the
/// driver to grant the cursor page; a plain PCM `writePeriod` carries no cap.
pub const HELLO = [4]u8{ 'A', 'C', 'U', 'R' };

pub const Error = error{ NoNameserver, NoService, Rpc, BadPeriod };

pub const Sink = struct {
    svc: u32,
    /// Mapped shared cursor page, or null if the driver didn't grant one
    /// (older driver / handshake failed). Callers must check hasCursor().
    cursor: ?*volatile Cursor = null,

    pub fn connect() Error!Sink {
        const ns_h = syscall.nsLookup("nameserver");
        if (ns_h < 0) return error.NoNameserver;

        const lk = syscall.channelCreate(0);
        if (lk < 0) return error.NoService;
        const lk_send: u32 = @truncate(@as(u64, @bitCast(lk)));
        const lk_recv: u32 = @truncate(@as(u64, @bitCast(lk)) >> 32);
        defer _ = syscall.capRelease(lk_recv);

        var req: [p9.MAX_MSG]u8 = undefined;
        const n = p9.encodeLookup(&req, 1, URI) catch return error.NoService;
        if (syscall.send(@intCast(ns_h), req[0..n], lk_send) != 0) {
            _ = syscall.capRelease(lk_send);
            return error.NoService;
        }
        var resp: [p9.MAX_MSG]u8 = undefined;
        var svc: u32 = 0;
        const rn = syscall.recv(lk_recv, &resp, &svc);
        if (rn < 0) return error.NoService;
        const decoded = p9.decodeResponse(resp[0..@intCast(rn)]) catch return error.NoService;
        switch (decoded.resp) {
            .lookup => {},
            else => return error.NoService,
        }
        if (svc == 0) return error.NoService;

        var sink = Sink{ .svc = svc };
        // Best-effort cursor handshake. Failure just leaves cursor=null; the
        // sink still streams audio, the caller falls back to a wall clock.
        sink.cursor = requestCursor(svc);
        return sink;
    }

    fn requestCursor(svc: u32) ?*volatile Cursor {
        const rc = syscall.channelCreate(0);
        if (rc < 0) return null;
        const rc_send: u32 = @truncate(@as(u64, @bitCast(rc)));
        const rc_recv: u32 = @truncate(@as(u64, @bitCast(rc)) >> 32);
        defer _ = syscall.capRelease(rc_send);
        defer _ = syscall.capRelease(rc_recv);

        const dup = syscall.capDup(rc_send);
        if (dup < 0) return null;
        if (syscall.send(svc, &HELLO, @intCast(dup)) != 0) {
            _ = syscall.capRelease(@intCast(dup));
            return null;
        }
        var rbuf: [16]u8 = undefined;
        var cap: u32 = 0;
        const rrn = syscall.recv(rc_recv, &rbuf, &cap);
        if (rrn < 0 or cap == 0) {
            if (cap != 0) _ = syscall.capRelease(cap);
            return null;
        }
        const va = syscall.mmap(cap, syscall.PROT_READ | syscall.PROT_WRITE);
        if (va < 0 and va > -64) {
            _ = syscall.capRelease(cap);
            return null;
        }
        return @ptrFromInt(@as(usize, @bitCast(@as(isize, va))));
    }

    /// True if the driver granted a play-cursor page.
    pub fn hasCursor(self: *const Sink) bool {
        return self.cursor != null;
    }

    /// Total audio frames the device has actually played since the stream
    /// started (monotonic). 0 if no cursor / nothing played yet.
    pub fn playedFrames(self: *const Sink) u64 {
        const c = self.cursor orelse return 0;
        return c.played_periods * PERIOD_FRAMES;
    }

    /// Submit one period of interleaved S16 stereo PCM. `samples.len` must be
    /// PERIOD_SAMPLES. Fire-and-forget: no reply, no capability transfer.
    /// Blocks only when the driver's channel buffer is full, which paces
    /// repeated calls to the device's real-time playback rate.
    pub fn writePeriod(self: *const Sink, samples: []const i16) Error!void {
        if (samples.len != PERIOD_SAMPLES) return error.BadPeriod;
        if (syscall.send(self.svc, std.mem.sliceAsBytes(samples), 0) != 0) return error.Rpc;
    }
};
