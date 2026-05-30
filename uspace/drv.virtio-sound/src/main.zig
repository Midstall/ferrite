// virtio-sound (virtio-snd) driver. Brings up the device, configures PCM
// stream 0 (S16 stereo 44.1 kHz), and then acts as a raw PCM sink: it owns a
// ring of TX period buffers and does NO synthesis of its own. Any program
// (see lib/audio) connects over the nameserver and streams interleaved S16
// stereo periods, which the driver receives straight into a free TX slot and
// hands to the device. The per-period ack is the back-pressure gate, pacing
// the producer to the device's real-time drain rate.
//
// Transport (modern PCI cap walk, BAR mapping, split-ring virtqueue) mirrors
// drv.virtio-gpu / drv.virtio-net since there is no shared virtqueue module.

const std = @import("std");
const ferrite = std.os.ferrite;
const audio = @import("ferrite-audio");

pub const panic = ferrite.panic;
const fs = ferrite.fs;
const syscall = ferrite.syscall;

const VIRTIO_VENDOR: u16 = 0x1af4;
const AUDIO_CLASS: u8 = 0x04; // PCI base class: multimedia controller

const VIRTIO_CAP_COMMON: u8 = 1;
const VIRTIO_CAP_NOTIFY: u8 = 2;
const VIRTIO_CAP_ISR: u8 = 3;
const VIRTIO_CAP_DEVICE: u8 = 4;

const STATUS_ACK: u8 = 1;
const STATUS_DRIVER: u8 = 2;
const STATUS_DRIVER_OK: u8 = 4;
const STATUS_FEATURES_OK: u8 = 8;
const STATUS_FAILED: u8 = 0x80;

const VIRTIO_F_VERSION_1: u64 = 1 << 32;

const VQ_CONTROL: u16 = 0;
const VQ_EVENT: u16 = 1;
const VQ_TX: u16 = 2;
const VQ_RX: u16 = 3;
const QSIZE: u16 = 64;

// virtio-snd request codes (virtio 1.2 §5.14.6).
const R_PCM_INFO: u32 = 0x0100;
const R_PCM_SET_PARAMS: u32 = 0x0101;
const R_PCM_PREPARE: u32 = 0x0102;
const R_PCM_RELEASE: u32 = 0x0103;
const R_PCM_START: u32 = 0x0104;
const R_PCM_STOP: u32 = 0x0105;
const S_OK: u32 = 0x8000;

const FMT_S16: u8 = 5;
const RATE_44100: u8 = 6;

const C = struct {
    const DEVICE_FEATURE_SELECT = 0x00;
    const DEVICE_FEATURE = 0x04;
    const DRIVER_FEATURE_SELECT = 0x08;
    const DRIVER_FEATURE = 0x0C;
    const NUM_QUEUES = 0x12;
    const DEVICE_STATUS = 0x14;
    const QUEUE_SELECT = 0x16;
    const QUEUE_SIZE = 0x18;
    const QUEUE_MSIX_VECTOR = 0x1A;
    const QUEUE_ENABLE = 0x1C;
    const QUEUE_NOTIFY_OFF = 0x1E;
    const QUEUE_DESC = 0x20;
    const QUEUE_AVAIL = 0x28;
    const QUEUE_USED = 0x30;
};
const MSIX_NO_VECTOR: u16 = 0xFFFF;

const Desc = extern struct { addr: u64, len: u32, flags: u16, next: u16 };
const DESC_NEXT: u16 = 1;
const DESC_WRITE: u16 = 2;

const AvailRing = extern struct {
    flags: u16,
    idx: u16,
    ring: [QSIZE]u16,
    used_event: u16,
};
const UsedElem = extern struct { id: u32, len: u32 };
const UsedRing = extern struct {
    flags: u16,
    idx: u16,
    ring: [QSIZE]UsedElem,
    avail_event: u16,
};

// virtio-snd wire structs (little-endian).
const SndHdr = extern struct { code: u32 };
const PcmHdr = extern struct { code: u32, stream_id: u32 };
const PcmSetParams = extern struct {
    hdr: PcmHdr,
    buffer_bytes: u32,
    period_bytes: u32,
    features: u32 = 0,
    channels: u8,
    format: u8,
    rate: u8,
    padding: u8 = 0,
};
const PcmStatus = extern struct { status: u32 = 0, latency_bytes: u32 = 0 };

const VirtioCap = struct {
    bar: u8,
    offset: u32,
    length: u32,
    notify_multiplier: u32 = 0,
};
const Caps = struct {
    common: ?VirtioCap = null,
    notify: ?VirtioCap = null,
    isr: ?VirtioCap = null,
    device: ?VirtioCap = null,
};

var common_base: usize = 0;
var notify_base: usize = 0;
var notify_multiplier: u32 = 0;
var device_base: usize = 0;

// INTx: ISR status register (reading it acks/de-asserts the device's shared,
// level-triggered line), the device's GIC IRQ, and the IRQ-wait channel.
// irq_num == 0 means no usable IRQ (other arches), so spin/yield poll instead.
var isr_base: usize = 0;
var irq_num: u32 = 0;
var irq_handle: u32 = 0;
var irq_recv: u32 = 0;

inline fn r8(a: usize) u8 {
    return @as(*volatile u8, @ptrFromInt(a)).*;
}
inline fn r16(a: usize) u16 {
    return @as(*volatile u16, @ptrFromInt(a)).*;
}
inline fn r32(a: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(a)).*;
}
inline fn w8(a: usize, v: u8) void {
    @as(*volatile u8, @ptrFromInt(a)).* = v;
}
inline fn w16(a: usize, v: u16) void {
    @as(*volatile u16, @ptrFromInt(a)).* = v;
}
inline fn w32(a: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(a)).* = v;
}
inline fn w64(a: usize, v: u64) void {
    @as(*volatile u64, @ptrFromInt(a)).* = v;
}

const Queue = struct {
    desc: [*]volatile Desc = undefined,
    avail: *volatile AvailRing = undefined,
    used: *volatile UsedRing = undefined,
    notify_addr: usize = 0,
    last_used: u16 = 0,
    avail_idx: u16 = 0,
};
var ctrlq: Queue = .{};
var txq: Queue = .{};

const DESC_BYTES: usize = @sizeOf(Desc) * QSIZE;
const USED_OFFSET: usize = 0x800;

// Control request/response DMA (one page: request half + response half).
var ctrl_va: usize = 0;
var ctrl_pa: u64 = 0;
const CTRL_REQ_OFF: usize = 0;
const CTRL_RESP_OFF: usize = 2048;

// PCM stream + TX buffers.
const STREAM_ID: u32 = 0;
const CHANNELS: u8 = @intCast(audio.CHANNELS);
const RATE: u32 = audio.RATE;
const PERIOD_FRAMES: u32 = audio.PERIOD_FRAMES;
const PERIOD_BYTES: u32 = PERIOD_FRAMES * CHANNELS * 2; // S16 = 2 bytes/sample
// Keep many periods in flight: TCG + a yield-poll refill is slow, so deep
// buffering (here ~0.75 s) absorbs refill latency before the stream underruns.
const N_PERIODS: u32 = 16;
const BUFFER_BYTES: u32 = PERIOD_BYTES * N_PERIODS;

// Per-period TX scratch: [u32 stream_id][PCM data][PcmStatus], one slot each.
var tx_va: usize = 0;
var tx_pa: u64 = 0;
const SLOT_HDR: usize = 0; // 4 bytes stream_id (8-byte aligned slot)
const SLOT_DATA: usize = 16; // PCM data
const SLOT_STATUS_OFF: usize = 16 + PERIOD_BYTES; // PcmStatus
const SLOT_STRIDE: usize = (SLOT_STATUS_OFF + 16 + 4095) & ~@as(usize, 4095);

pub fn main() void {
    if (!findAndInit()) return;
    if (!setupPcm()) {
        ferrite.console.print("[virtio-sound] PCM setup failed\n", .{}) catch {};
        return;
    }
    // Audio drains in real time, so the serve loop must outrank any client's
    // compute (e.g. a video thread at rt_mid doing a heavy rasterize). At
    // rt_high we still spend almost all of our wall-clock time blocked on
    // `recv` or the back-pressure nanosleep, so we don't actually starve
    // anything - we just can't be starved BY anything.
    _ = ferrite.setThreadPriority(.rt_high);
    ferrite.console.print("[virtio-sound] stream {d}: S16 {d}ch {d}Hz, PCM sink\n", .{ STREAM_ID, CHANNELS, RATE }) catch {};
    serve();
}

fn findAndInit() bool {
    var bdf_buf: [12]u8 = undefined;
    if (!findDevice(&bdf_buf)) {
        ferrite.console.print("[virtio-sound] no virtio-sound device on PCI\n", .{}) catch {};
        return false;
    }
    var caps: Caps = .{};
    if (!walkVirtioCaps(&bdf_buf, &caps)) return false;
    const common = caps.common orelse return false;
    const notify_cap = caps.notify orelse return false;

    var bar_va: [6]?usize = @splat(null);
    bar_va[common.bar] = mapBar(&bdf_buf, common.bar) orelse return false;
    if (bar_va[notify_cap.bar] == null) bar_va[notify_cap.bar] = mapBar(&bdf_buf, notify_cap.bar) orelse return false;
    common_base = bar_va[common.bar].? + common.offset;
    notify_base = bar_va[notify_cap.bar].? + notify_cap.offset;
    notify_multiplier = notify_cap.notify_multiplier;
    if (caps.device) |dev_cap| {
        if (bar_va[dev_cap.bar] == null) bar_va[dev_cap.bar] = mapBar(&bdf_buf, dev_cap.bar);
        if (bar_va[dev_cap.bar]) |b| device_base = b + dev_cap.offset;
    }
    // Map the ISR status register: reading it after an INTx interrupt clears
    // the device's interrupt cause and de-asserts the (shared, level-triggered)
    // line. Needed before we can IRQ-wait on the control queue.
    if (caps.isr) |isr| {
        if (bar_va[isr.bar] == null) bar_va[isr.bar] = mapBar(&bdf_buf, isr.bar);
        if (bar_va[isr.bar]) |b| isr_base = b + isr.offset;
    }

    w8(common_base + C.DEVICE_STATUS, 0);
    var resets: u32 = 0;
    while (r8(common_base + C.DEVICE_STATUS) != 0) {
        resets += 1;
        if (resets > 1_000_000) return false;
    }
    w8(common_base + C.DEVICE_STATUS, STATUS_ACK);
    w8(common_base + C.DEVICE_STATUS, STATUS_ACK | STATUS_DRIVER);

    const dev_features = readFeatures();
    if ((dev_features & VIRTIO_F_VERSION_1) == 0) {
        ferrite.console.print("[virtio-sound] device not virtio 1.0+\n", .{}) catch {};
        w8(common_base + C.DEVICE_STATUS, STATUS_FAILED);
        return false;
    }
    writeFeatures(VIRTIO_F_VERSION_1);
    w8(common_base + C.DEVICE_STATUS, STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK);
    if ((r8(common_base + C.DEVICE_STATUS) & STATUS_FEATURES_OK) == 0) return false;

    if (!setupQueue(VQ_CONTROL, &ctrlq)) return false;
    if (!setupQueue(VQ_TX, &txq)) return false;

    w8(common_base + C.DEVICE_STATUS, STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK);

    // Control req/resp page.
    if (ferrite.dmaAlloc(1, &ctrl_va, &ctrl_pa) != 0) return false;
    // TX buffers: N_PERIODS slots, each padded to a page boundary.
    const tx_pages: u32 = @intCast((SLOT_STRIDE * N_PERIODS + 4095) / 4096);
    if (ferrite.dmaAlloc(tx_pages, &tx_va, &tx_pa) != 0) return false;

    // IRQ disabled: inline block-on-IRQ in submitCtrl is incompatible with
    // shared, level-triggered INTx (an idle sound in fs.serve never acks the
    // shared line, stranding the mask, which hung setup). Poll instead until
    // the dedicated-irq-thread + completion-channel model lands.
    // See ferrite-irq-userspace.
    irq_num = 0;
    return true;
}

fn readIrq(bdf: *const [12]u8) u32 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/dev/pci/{s}/irq", .{bdf}) catch return 0;
    var text: [16]u8 = undefined;
    const len = readPath(path, &text) orelse return 0;
    return std.fmt.parseInt(u32, text[0..len], 10) catch 0; // "none" -> 0
}

fn bindIrq() bool {
    const h = ferrite.irqCreate(irq_num);
    if (h < 0) return false;
    irq_handle = @intCast(h);
    const rh = ferrite.irqListen(irq_handle);
    if (rh < 0) return false;
    irq_recv = @intCast(rh);
    return true;
}

fn readFeatures() u64 {
    w32(common_base + C.DEVICE_FEATURE_SELECT, 0);
    const lo = r32(common_base + C.DEVICE_FEATURE);
    w32(common_base + C.DEVICE_FEATURE_SELECT, 1);
    const hi = r32(common_base + C.DEVICE_FEATURE);
    return (@as(u64, hi) << 32) | @as(u64, lo);
}
fn writeFeatures(f: u64) void {
    w32(common_base + C.DRIVER_FEATURE_SELECT, 0);
    w32(common_base + C.DRIVER_FEATURE, @truncate(f));
    w32(common_base + C.DRIVER_FEATURE_SELECT, 1);
    w32(common_base + C.DRIVER_FEATURE, @truncate(f >> 32));
}

fn setupQueue(idx: u16, q: *Queue) bool {
    w16(common_base + C.QUEUE_SELECT, idx);
    const max = r16(common_base + C.QUEUE_SIZE);
    if (max < QSIZE) {
        ferrite.console.print("[virtio-sound] queue {d} too small (max={d})\n", .{ idx, max }) catch {};
        return false;
    }
    w16(common_base + C.QUEUE_SIZE, QSIZE);

    var ring_va: usize = 0;
    var ring_pa: u64 = 0;
    if (ferrite.dmaAlloc(1, &ring_va, &ring_pa) != 0) return false;
    q.desc = @ptrFromInt(ring_va);
    q.avail = @ptrFromInt(ring_va + DESC_BYTES);
    q.used = @ptrFromInt(ring_va + USED_OFFSET);
    var i: u32 = 0;
    while (i < QSIZE) : (i += 1) q.desc[i] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
    q.avail.* = std.mem.zeroes(AvailRing);
    // VIRTQ_AVAIL_F_NO_INTERRUPT: we poll, so suppress interrupts or the device
    // storms a (possibly shared) INTx line claimed by an IRQ-driven driver.
    q.avail.flags = 1;
    q.used.* = std.mem.zeroes(UsedRing);
    q.last_used = 0;
    q.avail_idx = 0;

    w16(common_base + C.QUEUE_MSIX_VECTOR, MSIX_NO_VECTOR);
    w64(common_base + C.QUEUE_DESC, ring_pa);
    w64(common_base + C.QUEUE_AVAIL, ring_pa + DESC_BYTES);
    w64(common_base + C.QUEUE_USED, ring_pa + USED_OFFSET);
    const notify_off = r16(common_base + C.QUEUE_NOTIFY_OFF);
    q.notify_addr = notify_base + (@as(usize, notify_off) * @as(usize, notify_multiplier));
    w16(common_base + C.QUEUE_ENABLE, 1);
    return true;
}

// Submit a control request (req_len bytes already in the ctrl request half) and
// block for the response header. Returns the response status code.
fn submitCtrl(req_len: usize) u32 {
    ctrlq.desc[0] = .{ .addr = ctrl_pa + CTRL_REQ_OFF, .len = @intCast(req_len), .flags = DESC_NEXT, .next = 1 };
    ctrlq.desc[1] = .{ .addr = ctrl_pa + CTRL_RESP_OFF, .len = @sizeOf(SndHdr), .flags = DESC_WRITE, .next = 0 };

    ctrlq.avail.ring[ctrlq.avail_idx % QSIZE] = 0;
    ferrite.barrier.storeStore();
    ctrlq.avail_idx +%= 1;
    ctrlq.avail.idx = ctrlq.avail_idx;
    ferrite.barrier.full();
    w16(ctrlq.notify_addr, VQ_CONTROL);

    if (irq_num != 0) {
        // IRQ-driven wait: block on the control-queue INTx instead of busy
        // yielding. The line is shared and level-triggered, so on each wake
        // re-check the used ring, then read the ISR (de-asserts the device
        // line) and ack (unmasks the GIC line) before re-blocking. A recv error
        // drops us into the bounded yield-poll below so a control command can
        // never hang. submitCtrl runs only at setup / XRUN recovery, never in
        // the steady-state PCM path, so this does not touch playback timing.
        var msg: [16]u8 = undefined;
        var fell_back = false;
        while (ctrlq.used.idx == ctrlq.last_used) {
            var cap_out: u32 = 0;
            const n = ferrite.recv(irq_recv, &msg, &cap_out);
            if (n < 0) {
                fell_back = true;
                break;
            }
            const advanced = ctrlq.used.idx != ctrlq.last_used;
            if (isr_base != 0) _ = @as(*volatile u8, @ptrFromInt(isr_base)).*;
            _ = ferrite.irqAck(irq_handle);
            if (advanced) break;
        }
        if (!fell_back) {
            ctrlq.last_used +%= 1;
            ferrite.barrier.full();
            const resp: *volatile SndHdr = @ptrFromInt(ctrl_va + CTRL_RESP_OFF);
            return resp.code;
        }
    }

    var spins: u64 = 0;
    while (ctrlq.used.idx == ctrlq.last_used) {
        spins += 1;
        if (spins > 5_000_000) return 0xFFFFFFFF;
        ferrite.yield();
    }
    ctrlq.last_used +%= 1;
    ferrite.barrier.full();
    const resp: *volatile SndHdr = @ptrFromInt(ctrl_va + CTRL_RESP_OFF);
    return resp.code;
}

fn pcmCmd(code: u32) bool {
    const req: *PcmHdr = @ptrFromInt(ctrl_va + CTRL_REQ_OFF);
    req.* = .{ .code = code, .stream_id = STREAM_ID };
    const st = submitCtrl(@sizeOf(PcmHdr));
    return st == S_OK;
}

fn setupPcm() bool {
    const params: *PcmSetParams = @ptrFromInt(ctrl_va + CTRL_REQ_OFF);
    params.* = .{
        .hdr = .{ .code = R_PCM_SET_PARAMS, .stream_id = STREAM_ID },
        .buffer_bytes = BUFFER_BYTES,
        .period_bytes = PERIOD_BYTES,
        .channels = CHANNELS,
        .format = FMT_S16,
        .rate = RATE_44100,
    };
    if (submitCtrl(@sizeOf(PcmSetParams)) != S_OK) {
        ferrite.console.print("[virtio-sound] SET_PARAMS rejected\n", .{}) catch {};
        return false;
    }
    if (!pcmCmd(R_PCM_PREPARE)) {
        ferrite.console.print("[virtio-sound] PREPARE rejected\n", .{}) catch {};
        return false;
    }
    if (!pcmCmd(R_PCM_START)) {
        ferrite.console.print("[virtio-sound] START rejected\n", .{}) catch {};
        return false;
    }
    return true;
}

inline fn slotBase(i: u32) usize {
    return tx_va + SLOT_STRIDE * i;
}
inline fn slotPa(i: u32) u64 {
    return tx_pa + @as(u64, SLOT_STRIDE) * i;
}

fn queuePeriod(i: u32) void {
    const hdr: *u32 = @ptrFromInt(slotBase(i) + SLOT_HDR);
    hdr.* = STREAM_ID;
    const status: *PcmStatus = @ptrFromInt(slotBase(i) + SLOT_STATUS_OFF);
    status.* = .{};

    const d0 = i * 3;
    txq.desc[d0] = .{ .addr = slotPa(i) + SLOT_HDR, .len = 4, .flags = DESC_NEXT, .next = @intCast(d0 + 1) };
    txq.desc[d0 + 1] = .{ .addr = slotPa(i) + SLOT_DATA, .len = PERIOD_BYTES, .flags = DESC_NEXT, .next = @intCast(d0 + 2) };
    txq.desc[d0 + 2] = .{ .addr = slotPa(i) + SLOT_STATUS_OFF, .len = @sizeOf(PcmStatus), .flags = DESC_WRITE, .next = 0 };

    txq.avail.ring[txq.avail_idx % QSIZE] = @intCast(d0);
    ferrite.barrier.storeStore();
    txq.avail_idx +%= 1;
    txq.avail.idx = txq.avail_idx;
    ferrite.barrier.full();
    w16(txq.notify_addr, VQ_TX);
}

// Shared play-cursor page (mapped read-write by the client). We publish the
// running `completed` (periods the device has played) here so a client can
// drive a video clock off true audio playback. See audio.Cursor.
var cursor_va: usize = 0;

// Reap every TX period the device has returned, advancing `completed`, and
// publish the new play cursor to the shared page.
fn drainUsed(completed: *u64) void {
    ferrite.barrier.full();
    while (txq.used.idx != txq.last_used) {
        txq.last_used +%= 1;
        completed.* += 1;
    }
    if (cursor_va != 0) {
        const cur: *volatile audio.Cursor = @ptrFromInt(cursor_va);
        cur.played_periods = completed.*;
    }
}

// virtio-snd stops the stream on its first underrun and only resumes after a
// STOP -> PREPARE -> START sequence (the XRUN recovery path in the spec).
// Without this the stream dies permanently the first time the host backend
// stalls long enough to drain our TX ring - which is what OBS (host pulseaudio
// + display capture pressure) reliably triggers within a couple seconds. The
// in-flight ~700 ms of PCM is lost (a brief audio glitch); the stream resumes.
fn recoverStream(queued: *u64, completed: *u64) void {
    ferrite.console.print("[virtio-sound] xrun: stream stalled, restarting\n", .{}) catch {};
    _ = pcmCmd(R_PCM_STOP);
    // STOP returns all pending TX buffers; let them land then snap accounting.
    ferrite.nanosleep(5 * std.time.ns_per_ms);
    drainUsed(completed);
    completed.* = queued.*;
    _ = pcmCmd(R_PCM_PREPARE);
    _ = pcmCmd(R_PCM_START);
}

// Channel buffer depth (periods the producer may run ahead while we are busy
// in the device back-pressure wait). The real audio buffer is the N_PERIODS
// virtio ring; this just smooths scheduling jitter between us and the client.
const SINK_QUEUE: usize = 8;

// PCM sink: register the nameserver URI and serve a client. Each message is one
// period of S16 stereo PCM, received straight into a free TX slot and queued to
// the device. Fire-and-forget: there is no reply, so the hot path transfers no
// capabilities. Back-pressure is implicit - while we wait for a TX slot to
// drain (keeping at most N_PERIODS-1 in flight, ~700 ms), we stop receiving,
// the channel buffer fills, and the client's send blocks. That paces the
// producer to the device's real-time rate without anyone tracking time.
fn serve() void {
    const ch = syscall.channelCreate(SINK_QUEUE);
    if (ch < 0) {
        ferrite.console.print("[virtio-sound] channelCreate failed\n", .{}) catch {};
        return;
    }
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);
    fs.register(audio.URI, svc_send) catch |e| {
        ferrite.console.print("[virtio-sound] register failed: {t}\n", .{e}) catch {};
        return;
    };
    ferrite.console.print("[virtio-sound] PCM sink ready at {s}\n", .{audio.URI}) catch {};

    // Allocate the shared play-cursor page and mint a grantable cap over it.
    var cursor_pa: u64 = 0;
    var cursor_cap: isize = -1;
    if (ferrite.dmaAlloc(1, &cursor_va, &cursor_pa) == 0) {
        const cur: *volatile audio.Cursor = @ptrFromInt(cursor_va);
        cur.played_periods = 0;
        cursor_cap = ferrite.mmioCreate(cursor_pa, @intCast(ferrite.pageSize()));
        if (cursor_cap < 0) cursor_va = 0; // mint failed; disable cursor
    }

    var queued: u64 = 0;
    var completed: u64 = 0;
    while (true) {
        // Back-pressure: wait until the slot we are about to reuse has drained.
        // If `completed` makes no forward progress for ~500 ms, the device has
        // underrun (XRUN) and won't recover on its own. Restart the stream.
        var stall_ms: u32 = 0;
        while (queued - completed >= N_PERIODS) {
            const c0 = completed;
            drainUsed(&completed);
            if (completed != c0) stall_ms = 0;
            if (queued - completed >= N_PERIODS) {
                ferrite.nanosleep(2 * std.time.ns_per_ms);
                stall_ms += 2;
                if (stall_ms >= 500) {
                    recoverStream(&queued, &completed);
                    stall_ms = 0;
                }
            }
        }
        drainUsed(&completed);

        const slot: u32 = @intCast(queued % N_PERIODS);
        const data: [*]u8 = @ptrFromInt(slotBase(slot) + SLOT_DATA);
        var xfer_cap: u32 = 0;
        const rn = syscall.recv(svc_recv, data[0..PERIOD_BYTES], &xfer_cap);
        // A message carrying a reply cap is the cursor handshake (audio.HELLO),
        // not PCM: grant a dup of the cursor page cap and don't queue it.
        if (xfer_cap != 0) {
            var ack: u32 = 0;
            var grant: u32 = 0;
            if (cursor_cap >= 0) {
                const dup = syscall.capDup(@intCast(cursor_cap));
                if (dup >= 0) grant = @intCast(dup);
            }
            _ = syscall.send(xfer_cap, std.mem.asBytes(&ack), grant);
            _ = syscall.capRelease(xfer_cap);
            continue;
        }
        if (rn < 0) continue;
        // A short period means stop/flush; zero the tail so we never emit
        // stale samples from a previous period in this slot.
        if (@as(usize, @intCast(rn)) < PERIOD_BYTES) @memset(data[@intCast(rn)..PERIOD_BYTES], 0);

        queuePeriod(slot);
        queued += 1;
    }
}

// PCI discovery + BAR mapping, mirrors drv.virtio-gpu.
fn findDevice(out_bdf: *[12]u8) bool {
    var attempts: u32 = 0;
    while (attempts < 16) : (attempts += 1) {
        if (tryFind(out_bdf)) return true;
        var i: u32 = 0;
        while (i < 8) : (i += 1) ferrite.yield();
    }
    return false;
}

fn tryFind(out_bdf: *[12]u8) bool {
    var uri_buf: [128]u8 = undefined;
    const pci_uri = fs.resolvePath("/dev/pci", &uri_buf) catch return false;
    const pci_dir = fs.open(pci_uri, .{ .mode = .read }) catch return false;
    defer pci_dir.close();
    var listing: [1024]u8 = undefined;
    var total: usize = 0;
    while (total < listing.len) {
        const n = pci_dir.read(total, listing[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    var it = std.mem.tokenizeScalar(u8, listing[0..total], '\n');
    while (it.next()) |line| {
        if (line.len != 12) continue;
        if (matchDevice(line)) {
            @memcpy(out_bdf, line[0..12]);
            return true;
        }
    }
    return false;
}

fn matchDevice(bdf: []const u8) bool {
    var path_buf: [64]u8 = undefined;
    const v_path = std.fmt.bufPrint(&path_buf, "/dev/pci/{s}/vendor", .{bdf}) catch return false;
    var v_text: [16]u8 = undefined;
    const v_len = readPath(v_path, &v_text) orelse return false;
    const vendor = parseHex(v_text[0..v_len]) orelse return false;
    if (vendor != VIRTIO_VENDOR) return false;

    const c_path = std.fmt.bufPrint(&path_buf, "/dev/pci/{s}/class", .{bdf}) catch return false;
    var c_text: [16]u8 = undefined;
    const c_len = readPath(c_path, &c_text) orelse return false;
    if (c_len < 2) return false;
    const class_byte = parseHex(c_text[0..2]) orelse return false;
    return class_byte == AUDIO_CLASS;
}

fn readPath(path: []const u8, out: []u8) ?usize {
    var uri_buf: [128]u8 = undefined;
    const uri = fs.resolvePath(path, &uri_buf) catch return null;
    const f = fs.open(uri, .{ .mode = .read }) catch return null;
    defer f.close();
    var total: usize = 0;
    while (total < out.len) {
        const n = f.read(total, out[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    if (total > 0 and out[total - 1] == '\n') total -= 1;
    return total;
}

fn parseHex(s: []const u8) ?u32 {
    var v: u32 = 0;
    for (s) |c| {
        const d: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        v = (v << 4) | d;
    }
    return v;
}

fn parseHex64(s: []const u8) ?u64 {
    var v: u64 = 0;
    for (s) |c| {
        const d: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        v = (v << 4) | d;
    }
    return v;
}

fn walkVirtioCaps(bdf: *const [12]u8, caps: *Caps) bool {
    var path_buf: [64]u8 = undefined;
    const cfg_path = std.fmt.bufPrint(&path_buf, "/dev/pci/{s}/config", .{bdf}) catch return false;
    var cfg: [256]u8 = undefined;
    var uri_buf: [128]u8 = undefined;
    const cfg_uri = fs.resolvePath(cfg_path, &uri_buf) catch return false;
    const cfg_file = fs.open(cfg_uri, .{ .mode = .read }) catch return false;
    defer cfg_file.close();
    var got: usize = 0;
    while (got < cfg.len) {
        const n = cfg_file.read(got, cfg[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    if (got < 0x40) return false;
    if ((cfg[0x06] & 0x10) == 0) return false;
    var ptr: u16 = cfg[0x34] & 0xFC;
    var hops: u8 = 0;
    while (ptr != 0 and hops < 32) : (hops += 1) {
        if (ptr + 16 > cfg.len) return false;
        const cap_id = cfg[ptr];
        const next = cfg[ptr + 1];
        if (cap_id == 0x09) {
            const cfg_type = cfg[ptr + 3];
            const bar = cfg[ptr + 4];
            const offset = std.mem.readInt(u32, cfg[ptr + 8 ..][0..4], .little);
            const length = std.mem.readInt(u32, cfg[ptr + 12 ..][0..4], .little);
            const cap: VirtioCap = .{ .bar = bar, .offset = offset, .length = length };
            switch (cfg_type) {
                VIRTIO_CAP_COMMON => caps.common = cap,
                VIRTIO_CAP_NOTIFY => {
                    var c = cap;
                    if (ptr + 20 <= cfg.len) c.notify_multiplier = std.mem.readInt(u32, cfg[ptr + 16 ..][0..4], .little);
                    caps.notify = c;
                },
                VIRTIO_CAP_ISR => caps.isr = cap,
                VIRTIO_CAP_DEVICE => caps.device = cap,
                else => {},
            }
        }
        ptr = next;
    }
    return true;
}

fn mapBar(bdf: *const [12]u8, bar_idx: u8) ?usize {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/dev/pci/{s}/bar{d}", .{ bdf, bar_idx }) catch return null;
    var text: [64]u8 = undefined;
    const len = readPath(path, &text) orelse return null;
    if (len == 0) return null;

    const phys_kw = "phys=0x";
    const size_kw = "size=0x";
    const phys_at = std.mem.indexOf(u8, text[0..len], phys_kw) orelse return null;
    const after_phys = phys_at + phys_kw.len;
    const space = std.mem.indexOfScalarPos(u8, text[0..len], after_phys, ' ') orelse return null;
    const phys = parseHex64(text[after_phys..space]) orelse return null;

    const size_at = std.mem.indexOfPos(u8, text[0..len], space, size_kw) orelse return null;
    const after_size = size_at + size_kw.len;
    const end = blk: {
        var i = after_size;
        while (i < len and text[i] != '\n' and text[i] != ' ') : (i += 1) {}
        break :blk i;
    };
    const size = parseHex64(text[after_size..end]) orelse return null;

    const page_size: usize = ferrite.pageSize();
    const aligned_phys = phys & ~(page_size - 1);
    const aligned_size = (size + (phys - aligned_phys) + page_size - 1) & ~(page_size - 1);
    const cap = ferrite.mmioCreate(aligned_phys, @intCast(aligned_size));
    if (cap < 0) return null;
    const va = ferrite.mmap(@intCast(cap), ferrite.PROT_READ | ferrite.PROT_WRITE);
    if (va < 0 and va > -64) return null;
    const va_u: usize = @bitCast(@as(isize, va));
    return va_u + @as(usize, @intCast(phys - aligned_phys));
}
