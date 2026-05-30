// virtio-gpu 2D driver. Brings up the device, enumerates scanouts, and serves
// the ferrite-gpu client RPC (zero-copy framebuffer/cursor buffers).
//
// Transport (modern PCI cap walk, BAR mapping, split-ring virtqueue) mirrors
// drv.virtio-net since there is no shared virtqueue module yet.

const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const fs = ferrite.fs;
const syscall = ferrite.syscall;
const gpu = @import("ferrite-gpu");

const VIRTIO_VENDOR: u16 = 0x1af4;
const DISPLAY_CLASS: u8 = 0x03;

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
const QSIZE: u16 = 64;
// QEMU's virtio-gpu cursor queue caps at 16 entries (the control queue is
// larger). Cursor commands are tiny and synchronous, so 16 is ample.
const CURSOR_QSIZE: u16 = 16;

// virtio-gpu control commands (virtio 1.2 §5.7.6).
const CMD_GET_DISPLAY_INFO: u32 = 0x0100;
const CMD_RESOURCE_CREATE_2D: u32 = 0x0101;
const CMD_SET_SCANOUT: u32 = 0x0103;
const CMD_RESOURCE_FLUSH: u32 = 0x0104;
const CMD_TRANSFER_TO_HOST_2D: u32 = 0x0105;
const CMD_RESOURCE_ATTACH_BACKING: u32 = 0x0106;
const RESP_OK_NODATA: u32 = 0x1100;
const RESP_OK_DISPLAY_INFO: u32 = 0x1101;

// B8G8R8X8: bytes B,G,R,X in memory => little-endian u32 0x00RRGGBB.
const FORMAT_B8G8R8X8: u32 = 2;
const MAX_SCANOUTS: usize = 16;
const RESOURCE_ID: u32 = 1;

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

// GPU command wire structs (all little-endian).
const GpuRect = extern struct { x: u32, y: u32, width: u32, height: u32 };
const GpuHdr = extern struct {
    type: u32,
    flags: u32 = 0,
    fence_id: u64 = 0,
    ctx_id: u32 = 0,
    padding: u32 = 0,
};
const DisplayOne = extern struct { r: GpuRect, enabled: u32, flags: u32 };
const RespDisplayInfo = extern struct { hdr: GpuHdr, pmodes: [MAX_SCANOUTS]DisplayOne };
const ResourceCreate2D = extern struct {
    hdr: GpuHdr,
    resource_id: u32,
    format: u32,
    width: u32,
    height: u32,
};
const MemEntry = extern struct { addr: u64, length: u32, padding: u32 = 0 };
const AttachBacking = extern struct {
    hdr: GpuHdr,
    resource_id: u32,
    nr_entries: u32,
    entry: MemEntry,
};
const SetScanout = extern struct {
    hdr: GpuHdr,
    r: GpuRect,
    scanout_id: u32,
    resource_id: u32,
};
const TransferToHost2D = extern struct {
    hdr: GpuHdr,
    r: GpuRect,
    offset: u64,
    resource_id: u32,
    padding: u32 = 0,
};
const ResourceFlush = extern struct {
    hdr: GpuHdr,
    r: GpuRect,
    resource_id: u32,
    padding: u32 = 0,
};

// Cursor queue commands (virtio 1.2 §5.7.6.10).
const VQ_CURSOR: u16 = 1;
const CMD_UPDATE_CURSOR: u32 = 0x0300;
const CMD_MOVE_CURSOR: u32 = 0x0301;
// B8G8R8A8: cursors need an alpha channel; little-endian u32 0xAARRGGBB.
const FORMAT_B8G8R8A8: u32 = 1;
const CURSOR_DIM: u32 = 64;
// Cursor resource id, kept clear of the per-scanout ids (1..MAX_SCANOUTS).
const CURSOR_RES: u32 = 0x100;

const CursorPos = extern struct { scanout_id: u32, x: u32, y: u32, padding: u32 = 0 };
const UpdateCursor = extern struct {
    hdr: GpuHdr,
    pos: CursorPos,
    resource_id: u32,
    hot_x: u32,
    hot_y: u32,
    padding: u32 = 0,
};

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

// virtio_gpu_config.num_scanouts byte offset in the device-cfg region.
const GPU_CFG_NUM_SCANOUTS: usize = 8;

// Control queue.
var cq_desc: [*]volatile Desc = undefined;
var cq_avail: *volatile AvailRing = undefined;
var cq_used: *volatile UsedRing = undefined;
var cq_notify_addr: usize = 0;
var cq_last_used: u16 = 0;
var cq_avail_idx: u16 = 0;

// Cursor queue (shares the cmd DMA buffer; the serve loop is single-threaded
// so control and cursor submissions never overlap).
var cur_desc: [*]volatile Desc = undefined;
var cur_avail: *volatile AvailRing = undefined;
var cur_used: *volatile UsedRing = undefined;
var cur_notify_addr: usize = 0;
var cur_last_used: u16 = 0;
var cur_avail_idx: u16 = 0;

// Command DMA region: request half + response half in one page.
var cmd_va: usize = 0;
var cmd_pa: u64 = 0;
const CMD_REQ_OFF: usize = 0;
const CMD_RESP_OFF: usize = 2048;

// INTx: ISR status register (reading it acks/de-asserts the device's shared,
// level-triggered line), the device's GIC IRQ, and the IRQ-wait channel.
// irq_num == 0 means no usable IRQ (other arches), so submit paths spin-poll.
var isr_base: usize = 0;
var irq_num: u32 = 0;
var irq_handle: u32 = 0;
var irq_recv: u32 = 0;

// Per-scanout state. Resource id for display i is i+1.
const Display = struct {
    enabled: bool = false,
    w: u32 = 0,
    h: u32 = 0,
    has_buffer: bool = false,
};
var displays: [MAX_SCANOUTS]Display = @splat(.{});
var display_count: u32 = 0;

// Hardware cursor (single 64x64 image shared across scanouts).
var cursor_pa: u64 = 0;
var has_cursor = false;

inline fn r8(a: usize) u8 {
    return @as(*volatile u8, @ptrFromInt(a)).*;
}
inline fn r16(a: usize) u16 {
    return @as(*volatile u16, @ptrFromInt(a)).*;
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
inline fn r32(a: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(a)).*;
}

pub fn main() void {
    if (!findAndInit()) return;
    if (!queryDisplay()) return;
    ferrite.console.print("[virtio-gpu] {d} scanout(s), display 0 = {d}x{d}\n", .{ display_count, displays[0].w, displays[0].h }) catch {};
    serve();
}

fn findAndInit() bool {
    var bdf_buf: [12]u8 = undefined;
    if (!findVirtioGpu(&bdf_buf)) {
        ferrite.console.print("[virtio-gpu] no virtio-gpu device on PCI\n", .{}) catch {};
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

    // Device-cfg region (for num_scanouts). Optional: fall back to 1 scanout.
    if (caps.device) |dev_cap| {
        if (bar_va[dev_cap.bar] == null) bar_va[dev_cap.bar] = mapBar(&bdf_buf, dev_cap.bar);
        if (bar_va[dev_cap.bar]) |b| device_base = b + dev_cap.offset;
    }

    // Map the ISR status register: reading it after an INTx interrupt clears
    // the device's interrupt cause and de-asserts the (shared, level-triggered)
    // line. Optional: without it we fall back to spin polling.
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
        ferrite.console.print("[virtio-gpu] device not virtio 1.0+\n", .{}) catch {};
        w8(common_base + C.DEVICE_STATUS, STATUS_FAILED);
        return false;
    }
    writeFeatures(VIRTIO_F_VERSION_1);
    w8(common_base + C.DEVICE_STATUS, STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK);
    if ((r8(common_base + C.DEVICE_STATUS) & STATUS_FEATURES_OK) == 0) return false;

    if (!setupControlQueue()) return false;
    if (!setupCursorQueue()) return false;

    w8(common_base + C.DEVICE_STATUS, STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK);

    if (ferrite.dmaAlloc(1, &cmd_va, &cmd_pa) != 0) return false;

    // IRQ disabled: inline block-on-IRQ in the per-present submit path livelocks
    // against an always-waiting sibling listener on a shared, level-triggered
    // INTx (froze badapple). Poll instead until the dedicated-irq-thread +
    // completion-channel model lands. See ferrite-irq-userspace.
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

// Block on the device's INTx until the given used ring advances past `last`.
// On each wake: re-check the ring (the line is shared between controlq and
// cursorq, so a wake may belong to the other queue), then read the ISR to
// de-assert the device line and ack to unmask the GIC line. If recv ever
// errors, signal the caller to fall back to the spin/deadline poll so
// rendering can't hang.
fn waitUsed(used: *volatile UsedRing, last: u16) bool {
    var msg: [16]u8 = undefined;
    while (used.idx == last) {
        var cap_out: u32 = 0;
        const n = ferrite.recv(irq_recv, &msg, &cap_out);
        // Read ISR + ack after re-checking the ring on the next loop iteration.
        if (isr_base != 0) _ = @as(*volatile u8, @ptrFromInt(isr_base)).*;
        _ = ferrite.irqAck(irq_handle);
        if (n < 0) return false; // recv failed -> caller falls back to spin poll
        ferrite.barrier.full();
    }
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

const RING_PAGES: u64 = 1;
const DESC_BYTES: usize = @sizeOf(Desc) * QSIZE;
const USED_OFFSET: usize = 0x800;

fn setupControlQueue() bool {
    w16(common_base + C.QUEUE_SELECT, VQ_CONTROL);
    const max = r16(common_base + C.QUEUE_SIZE);
    if (max < QSIZE) return false;
    w16(common_base + C.QUEUE_SIZE, QSIZE);

    var ring_va: usize = 0;
    var ring_pa: u64 = 0;
    if (ferrite.dmaAlloc(RING_PAGES, &ring_va, &ring_pa) != 0) return false;

    cq_desc = @ptrFromInt(ring_va);
    cq_avail = @ptrFromInt(ring_va + DESC_BYTES);
    cq_used = @ptrFromInt(ring_va + USED_OFFSET);
    var i: u32 = 0;
    while (i < QSIZE) : (i += 1) cq_desc[i] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
    cq_avail.* = std.mem.zeroes(AvailRing);
    // VIRTQ_AVAIL_F_NO_INTERRUPT: we poll. Without it the device asserts our
    // (possibly shared) INTx line, storming an IRQ-claiming driver (net) that
    // shares the GIC SPI but can't clear our ISR.
    cq_avail.flags = 1;
    cq_used.* = std.mem.zeroes(UsedRing);

    w16(common_base + C.QUEUE_MSIX_VECTOR, MSIX_NO_VECTOR);
    w64(common_base + C.QUEUE_DESC, ring_pa);
    w64(common_base + C.QUEUE_AVAIL, ring_pa + DESC_BYTES);
    w64(common_base + C.QUEUE_USED, ring_pa + USED_OFFSET);
    const notify_off = r16(common_base + C.QUEUE_NOTIFY_OFF);
    cq_notify_addr = notify_base + (@as(usize, notify_off) * @as(usize, notify_multiplier));
    w16(common_base + C.QUEUE_ENABLE, 1);
    return true;
}

// Submit a request/response pair on the control queue and block until the
// device returns the descriptor. Returns the response header type.
fn submitCmd(req: []const u8, resp_len: usize) u32 {
    const req_pa = cmd_pa + CMD_REQ_OFF;
    const resp_pa = cmd_pa + CMD_RESP_OFF;
    const req_dst: [*]u8 = @ptrFromInt(cmd_va + CMD_REQ_OFF);
    @memcpy(req_dst[0..req.len], req);

    const head: u16 = 0;
    cq_desc[0] = .{ .addr = req_pa, .len = @intCast(req.len), .flags = DESC_NEXT, .next = 1 };
    cq_desc[1] = .{ .addr = resp_pa, .len = @intCast(resp_len), .flags = DESC_WRITE, .next = 0 };

    cq_avail.ring[cq_avail_idx % QSIZE] = head;
    ferrite.barrier.storeStore();
    cq_avail_idx +%= 1;
    cq_avail.idx = cq_avail_idx;
    ferrite.barrier.full();
    w16(cq_notify_addr, VQ_CONTROL);

    // IRQ-driven: block on INTx until the control used ring advances. On recv
    // failure, fall through to the spin/deadline poll so rendering can't hang.
    if (irq_num == 0 or !waitUsed(cq_used, cq_last_used)) {
        var spins: u64 = 0;
        while (cq_used.idx == cq_last_used) {
            spins += 1;
            if (spins > 5_000_000) {
                ferrite.console.print("[virtio-gpu] command timeout\n", .{}) catch {};
                return 0;
            }
            ferrite.yield();
        }
    }
    cq_last_used +%= 1;
    ferrite.barrier.full();
    const resp_hdr: *volatile GpuHdr = @ptrFromInt(cmd_va + CMD_RESP_OFF);
    return resp_hdr.type;
}

fn setupCursorQueue() bool {
    w16(common_base + C.QUEUE_SELECT, VQ_CURSOR);
    const max = r16(common_base + C.QUEUE_SIZE);
    if (max < CURSOR_QSIZE) {
        ferrite.console.print("[virtio-gpu] cursorq too small (max={d})\n", .{max}) catch {};
        return false;
    }
    w16(common_base + C.QUEUE_SIZE, CURSOR_QSIZE);

    var ring_va: usize = 0;
    var ring_pa: u64 = 0;
    if (ferrite.dmaAlloc(RING_PAGES, &ring_va, &ring_pa) != 0) return false;
    cur_desc = @ptrFromInt(ring_va);
    cur_avail = @ptrFromInt(ring_va + DESC_BYTES);
    cur_used = @ptrFromInt(ring_va + USED_OFFSET);
    var i: u32 = 0;
    while (i < QSIZE) : (i += 1) cur_desc[i] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
    cur_avail.* = std.mem.zeroes(AvailRing);
    cur_avail.flags = 1; // VIRTQ_AVAIL_F_NO_INTERRUPT: we poll (see cq_avail).
    cur_used.* = std.mem.zeroes(UsedRing);

    w16(common_base + C.QUEUE_MSIX_VECTOR, MSIX_NO_VECTOR);
    w64(common_base + C.QUEUE_DESC, ring_pa);
    w64(common_base + C.QUEUE_AVAIL, ring_pa + DESC_BYTES);
    w64(common_base + C.QUEUE_USED, ring_pa + USED_OFFSET);
    const notify_off = r16(common_base + C.QUEUE_NOTIFY_OFF);
    cur_notify_addr = notify_base + (@as(usize, notify_off) * @as(usize, notify_multiplier));
    w16(common_base + C.QUEUE_ENABLE, 1);
    return true;
}

// Mirror of submitCmd on the cursor queue (shares the cmd DMA buffer).
fn submitCursor(req: []const u8, resp_len: usize) u32 {
    const req_dst: [*]u8 = @ptrFromInt(cmd_va + CMD_REQ_OFF);
    @memcpy(req_dst[0..req.len], req);
    cur_desc[0] = .{ .addr = cmd_pa + CMD_REQ_OFF, .len = @intCast(req.len), .flags = DESC_NEXT, .next = 1 };
    cur_desc[1] = .{ .addr = cmd_pa + CMD_RESP_OFF, .len = @intCast(resp_len), .flags = DESC_WRITE, .next = 0 };
    cur_avail.ring[cur_avail_idx % CURSOR_QSIZE] = 0;
    ferrite.barrier.storeStore();
    cur_avail_idx +%= 1;
    cur_avail.idx = cur_avail_idx;
    ferrite.barrier.full();
    w16(cur_notify_addr, VQ_CURSOR);

    // IRQ-driven: block on the (shared) INTx until the cursor used ring
    // advances. On recv failure, fall through to the spin/deadline poll.
    if (irq_num == 0 or !waitUsed(cur_used, cur_last_used)) {
        var spins: u64 = 0;
        while (cur_used.idx == cur_last_used) {
            spins += 1;
            if (spins > 5_000_000) return 0;
            ferrite.yield();
        }
    }
    cur_last_used +%= 1;
    ferrite.barrier.full();
    const resp_hdr: *volatile GpuHdr = @ptrFromInt(cmd_va + CMD_RESP_OFF);
    return resp_hdr.type;
}

// Enumerate scanouts. Resource creation/backing/scanout are deferred to the
// client's CREATE_BUFFER so each framebuffer's backing can be the shared,
// client-mapped DMA region (zero-copy).
fn queryDisplay() bool {
    const req = GpuHdr{ .type = CMD_GET_DISPLAY_INFO };
    const t = submitCmd(std.mem.asBytes(&req), @sizeOf(RespDisplayInfo));
    if (t != RESP_OK_DISPLAY_INFO) {
        ferrite.console.print("[virtio-gpu] GET_DISPLAY_INFO failed (0x{x})\n", .{t}) catch {};
        return false;
    }
    const info: *volatile RespDisplayInfo = @ptrFromInt(cmd_va + CMD_RESP_OFF);

    // The device advertises how many scanouts it supports via num_scanouts.
    // The per-scanout `enabled` flag only means "a monitor is plugged in"
    // (often false headless), so we drive every scanout the device exposes,
    // taking the preferred mode when present and a sane default otherwise.
    var n: u32 = if (device_base != 0) r32(device_base + GPU_CFG_NUM_SCANOUTS) else 1;
    if (n == 0) n = 1;
    if (n > MAX_SCANOUTS) n = MAX_SCANOUTS;
    display_count = n;

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const pm = info.pmodes[i];
        const w: u32 = if (pm.enabled != 0 and pm.r.width != 0) pm.r.width else 1024;
        const h: u32 = if (pm.enabled != 0 and pm.r.height != 0) pm.r.height else 768;
        displays[i] = .{ .enabled = true, .w = w, .h = h };
    }
    return true;
}

// Allocate display `id`'s framebuffer, attach it to resource id+1, bind it to
// scanout `id`, and mint a grantable mem_region cap over its backing so the
// client can map and draw into it. Returns the cap handle or null.
// A client may request a buffer smaller than the display (0 = full display);
// SET_SCANOUT then resizes the scanout to that buffer, so the buffer drives
// the displayed resolution.
fn createScanoutBuffer(id: u32, req_w: u32, req_h: u32) ?u32 {
    const res = id + 1;
    const w = if (req_w != 0) req_w else displays[id].w;
    const h = if (req_h != 0) req_h else displays[id].h;
    const bytes: usize = @as(usize, w) * @as(usize, h) * 4;
    const ps = ferrite.pageSize();
    const pages = (bytes + ps - 1) / ps;
    const aligned = pages * ps;
    var va: usize = 0;
    var pa: u64 = 0;
    if (ferrite.dmaAlloc(@intCast(pages), &va, &pa) != 0) return null;

    const create = ResourceCreate2D{
        .hdr = .{ .type = CMD_RESOURCE_CREATE_2D },
        .resource_id = res,
        .format = FORMAT_B8G8R8X8,
        .width = w,
        .height = h,
    };
    if (submitCmd(std.mem.asBytes(&create), @sizeOf(GpuHdr)) != RESP_OK_NODATA) return null;

    const attach = AttachBacking{
        .hdr = .{ .type = CMD_RESOURCE_ATTACH_BACKING },
        .resource_id = res,
        .nr_entries = 1,
        .entry = .{ .addr = pa, .length = @intCast(bytes) },
    };
    if (submitCmd(std.mem.asBytes(&attach), @sizeOf(GpuHdr)) != RESP_OK_NODATA) return null;

    const scanout = SetScanout{
        .hdr = .{ .type = CMD_SET_SCANOUT },
        .r = .{ .x = 0, .y = 0, .width = w, .height = h },
        .scanout_id = id,
        .resource_id = res,
    };
    if (submitCmd(std.mem.asBytes(&scanout), @sizeOf(GpuHdr)) != RESP_OK_NODATA) return null;

    const cap = syscall.mmioCreate(pa, aligned);
    if (cap < 0) return null;
    displays[id].w = w;
    displays[id].h = h;
    displays[id].has_buffer = true;
    return @intCast(cap);
}

fn presentRect(id: u32, x: u32, y: u32, w: u32, h: u32) void {
    if (id >= MAX_SCANOUTS or !displays[id].has_buffer) return;
    const res = id + 1;
    const cw = if (w == 0) displays[id].w else w;
    const ch = if (h == 0) displays[id].h else h;
    const xfer = TransferToHost2D{
        .hdr = .{ .type = CMD_TRANSFER_TO_HOST_2D },
        .r = .{ .x = x, .y = y, .width = cw, .height = ch },
        .offset = (@as(u64, y) * @as(u64, displays[id].w) + @as(u64, x)) * 4,
        .resource_id = res,
    };
    _ = submitCmd(std.mem.asBytes(&xfer), @sizeOf(GpuHdr));

    const flush = ResourceFlush{
        .hdr = .{ .type = CMD_RESOURCE_FLUSH },
        .r = .{ .x = x, .y = y, .width = cw, .height = ch },
        .resource_id = res,
    };
    _ = submitCmd(std.mem.asBytes(&flush), @sizeOf(GpuHdr));
}

// 64x64 B8G8R8A8 cursor image, backed by a client-mappable DMA region.
fn createCursorBuffer() ?u32 {
    const bytes: usize = @as(usize, CURSOR_DIM) * @as(usize, CURSOR_DIM) * 4;
    const ps = ferrite.pageSize();
    const pages = (bytes + ps - 1) / ps;
    const aligned = pages * ps;
    var va: usize = 0;
    var pa: u64 = 0;
    if (ferrite.dmaAlloc(@intCast(pages), &va, &pa) != 0) return null;

    const create = ResourceCreate2D{
        .hdr = .{ .type = CMD_RESOURCE_CREATE_2D },
        .resource_id = CURSOR_RES,
        .format = FORMAT_B8G8R8A8,
        .width = CURSOR_DIM,
        .height = CURSOR_DIM,
    };
    if (submitCmd(std.mem.asBytes(&create), @sizeOf(GpuHdr)) != RESP_OK_NODATA) return null;

    const attach = AttachBacking{
        .hdr = .{ .type = CMD_RESOURCE_ATTACH_BACKING },
        .resource_id = CURSOR_RES,
        .nr_entries = 1,
        .entry = .{ .addr = pa, .length = @intCast(bytes) },
    };
    if (submitCmd(std.mem.asBytes(&attach), @sizeOf(GpuHdr)) != RESP_OK_NODATA) return null;

    const cap = syscall.mmioCreate(pa, aligned);
    if (cap < 0) return null;
    cursor_pa = pa;
    has_cursor = true;
    return @intCast(cap);
}

// Upload the (client-drawn) cursor image and show it via the cursor queue.
fn setCursor(id: u32, x: u32, y: u32, hot_x: u32, hot_y: u32) bool {
    if (!has_cursor) return false;
    const xfer = TransferToHost2D{
        .hdr = .{ .type = CMD_TRANSFER_TO_HOST_2D },
        .r = .{ .x = 0, .y = 0, .width = CURSOR_DIM, .height = CURSOR_DIM },
        .offset = 0,
        .resource_id = CURSOR_RES,
    };
    _ = submitCmd(std.mem.asBytes(&xfer), @sizeOf(GpuHdr));

    const upd = UpdateCursor{
        .hdr = .{ .type = CMD_UPDATE_CURSOR },
        .pos = .{ .scanout_id = id, .x = x, .y = y },
        .resource_id = CURSOR_RES,
        .hot_x = hot_x,
        .hot_y = hot_y,
    };
    return submitCursor(std.mem.asBytes(&upd), @sizeOf(GpuHdr)) == RESP_OK_NODATA;
}

fn moveCursor(id: u32, x: u32, y: u32) bool {
    if (!has_cursor) return false;
    const mv = UpdateCursor{
        .hdr = .{ .type = CMD_MOVE_CURSOR },
        .pos = .{ .scanout_id = id, .x = x, .y = y },
        .resource_id = 0,
        .hot_x = 0,
        .hot_y = 0,
    };
    return submitCursor(std.mem.asBytes(&mv), @sizeOf(GpuHdr)) == RESP_OK_NODATA;
}

fn serve() void {
    const ch = ferrite.channelCreate(0);
    if (ch < 0) return;
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);
    fs.register(gpu.URI, svc_send) catch |e| {
        ferrite.console.print("[virtio-gpu] register failed: {t}\n", .{e}) catch {};
        return;
    };

    var reqbuf: [@sizeOf(gpu.wire.Req)]u8 = undefined;
    while (true) {
        var reply_cap: u32 = 0;
        const rn = syscall.recv(svc_recv, &reqbuf, &reply_cap);
        if (rn < @sizeOf(gpu.wire.Req) or reply_cap == 0) {
            if (reply_cap != 0) _ = syscall.capRelease(reply_cap);
            continue;
        }
        const req: *const gpu.wire.Req = @ptrCast(@alignCast(&reqbuf));
        handleRpc(req.*, reply_cap);
    }
}

fn handleRpc(req: gpu.wire.Req, reply_cap: u32) void {
    defer _ = syscall.capRelease(reply_cap);
    var resp = gpu.wire.Resp{ .status = 0 };
    var xfer: u32 = 0;
    switch (req.op) {
        @intFromEnum(gpu.Op.info) => {
            resp.count = display_count;
            if (req.a < MAX_SCANOUTS and displays[req.a].enabled) {
                resp.width = displays[req.a].w;
                resp.height = displays[req.a].h;
            } // width==0 signals a disabled scanout
        },
        @intFromEnum(gpu.Op.create_buffer) => {
            const id = req.a;
            if (id >= MAX_SCANOUTS or !displays[id].enabled or displays[id].has_buffer) {
                resp.status = -1;
            } else if (createScanoutBuffer(id, req.b, req.c)) |cap| {
                xfer = cap;
                resp.width = displays[id].w;
                resp.height = displays[id].h;
                resp.stride = displays[id].w * 4;
            } else {
                resp.status = -1;
            }
        },
        @intFromEnum(gpu.Op.present) => {
            presentRect(req.a, req.b, req.c, req.d, req.e);
        },
        @intFromEnum(gpu.Op.create_cursor) => {
            if (has_cursor) {
                resp.status = -1;
            } else if (createCursorBuffer()) |cap| {
                xfer = cap;
                resp.width = CURSOR_DIM;
                resp.height = CURSOR_DIM;
                resp.stride = CURSOR_DIM * 4;
            } else {
                resp.status = -1;
            }
        },
        @intFromEnum(gpu.Op.set_cursor) => {
            if (!setCursor(req.a, req.b, req.c, req.d, req.e)) resp.status = -1;
        },
        @intFromEnum(gpu.Op.move_cursor) => {
            if (!moveCursor(req.a, req.b, req.c)) resp.status = -1;
        },
        else => resp.status = -1,
    }
    _ = syscall.send(reply_cap, std.mem.asBytes(&resp), xfer);
}

// PCI discovery + BAR mapping, mirrors drv.virtio-net.
fn findVirtioGpu(out_bdf: *[12]u8) bool {
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
        if (matchGpu(line)) {
            @memcpy(out_bdf, line[0..12]);
            return true;
        }
    }
    return false;
}

fn matchGpu(bdf: []const u8) bool {
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
    return class_byte == DISPLAY_CLASS;
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
