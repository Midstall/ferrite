const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const p9 = ferrite.p9;
const fs = ferrite.fs;

// virtio-mmio transport
const VIRTIO_MAGIC: u32 = 0x7472_6976;
const VIRTIO_VERSION_LEGACY: u32 = 1;
const VIRTIO_VERSION_MODERN: u32 = 2;
const VIRTIO_BLK_DEV_ID: u32 = 2;
const SECTOR: u64 = 512;
const VIRTIO_MMIO_COMPATIBLE = "virtio,mmio";

const R = struct {
    const MAGIC = 0x000;
    const VERSION = 0x004;
    const DEV_ID = 0x008;
    const DEV_FEAT = 0x010;
    const DEV_FEAT_SEL = 0x014;
    const DRV_FEAT = 0x020;
    const DRV_FEAT_SEL = 0x024;
    const LEGACY_GUEST_PAGE_SIZE = 0x028;
    const QUEUE_SEL = 0x030;
    const QUEUE_NUM_MAX = 0x034;
    const QUEUE_NUM = 0x038;
    const LEGACY_QUEUE_ALIGN = 0x03C;
    const LEGACY_QUEUE_PFN = 0x040;
    const QUEUE_READY = 0x044;
    const QUEUE_NOTIFY = 0x050;
    const INT_STATUS = 0x060;
    const INT_ACK = 0x064;
    const STATUS = 0x070;
    const QUEUE_DESC_LOW = 0x080;
    const QUEUE_DESC_HIGH = 0x084;
    const QUEUE_DRIVER_LOW = 0x090;
    const QUEUE_DRIVER_HIGH = 0x094;
    const QUEUE_DEVICE_LOW = 0x0A0;
    const QUEUE_DEVICE_HIGH = 0x0A4;
    const CONFIG = 0x100;
};

const S = struct {
    const ACK: u32 = 1;
    const DRIVER: u32 = 2;
    const DRIVER_OK: u32 = 4;
    const FEATURES_OK: u32 = 8;
};

// virtio-pci transport
const VIRTIO_VENDOR: u16 = 0x1af4;
const VIRTIO_BLK_PCI_MODERN: u16 = 0x1042; // 0x1040 + device type 2
const VIRTIO_BLK_PCI_LEGACY: u16 = 0x1001; // transitional
const VIRTIO_F_VERSION_1: u64 = 1 << 32;

const VIRTIO_CAP_COMMON: u8 = 1;
const VIRTIO_CAP_NOTIFY: u8 = 2;
const VIRTIO_CAP_ISR: u8 = 3;
const VIRTIO_CAP_DEVICE: u8 = 4;
const MSIX_NO_VECTOR: u16 = 0xFFFF;

// virtio-pci common config register offsets.
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

const LEGACY_QUEUE_ALIGN_BYTES: u32 = 256;
const QSIZE: u16 = 8;
var page_size: u64 = 0;

const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};
const DESC_NEXT: u16 = 1;
const DESC_WRITE: u16 = 2;

const Avail = extern struct {
    flags: u16,
    idx: u16,
    ring: [QSIZE]u16,
    used_event: u16,
};

const UsedElem = extern struct {
    id: u32,
    len: u32,
};

const Used = extern struct {
    flags: u16,
    idx: u16,
    ring: [QSIZE]UsedElem,
    avail_event: u16,
};

const BlkReq = extern struct {
    type: u32,
    reserved: u32,
    sector: u64,
};

const BLK_IN: u32 = 0;
const BLK_OUT: u32 = 1;

const Transport = enum { mmio, pci };

const Driver = struct {
    transport: Transport = .mmio,
    // mmio
    mmio_base: usize = 0,
    is_legacy: bool = false,
    // pci
    common_base: usize = 0,
    notify_addr: usize = 0,
    // shared queue + request buffer
    desc: [*]volatile Desc = undefined,
    avail: *volatile Avail = undefined,
    used: *volatile Used = undefined,
    last_used: u16 = 0,
    header: *volatile BlkReq = undefined,
    data: [*]volatile u8 = undefined,
    status_byte: *volatile u8 = undefined,
    b_pa: u64 = 0,
    capacity_sectors: u64 = 0,

    // INTx: ISR status register (reading it acks/de-asserts the device's shared,
    // level-triggered line), the device's GIC IRQ, and the IRQ-wait channel.
    // irq_num == 0 (mmio transport / other arches) means no usable IRQ.
    isr_base: usize = 0,
    irq_num: u32 = 0,
    irq_handle: u32 = 0,
    irq_recv: u32 = 0,
};

var driver: Driver = .{};

const MAX_FIDS = 8;

const Fid = struct {
    used: bool = false,
    opened: bool = false,
};

const State = struct {
    fids: [MAX_FIDS]Fid = @splat(.{}),
};

var state: State = .{};

// mmio register access (base-relative).
inline fn r32(off: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(driver.mmio_base + off)).*;
}
inline fn w32(off: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(driver.mmio_base + off)).* = v;
}
// absolute-address access (pci common/notify/device regions).
inline fn a8(addr: usize) u8 {
    return @as(*volatile u8, @ptrFromInt(addr)).*;
}
inline fn a16(addr: usize) u16 {
    return @as(*volatile u16, @ptrFromInt(addr)).*;
}
inline fn a32(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}
inline fn aw8(addr: usize, v: u8) void {
    @as(*volatile u8, @ptrFromInt(addr)).* = v;
}
inline fn aw16(addr: usize, v: u16) void {
    @as(*volatile u16, @ptrFromInt(addr)).* = v;
}
inline fn aw32(addr: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = v;
}
inline fn aw64(addr: usize, v: u64) void {
    @as(*volatile u64, @ptrFromInt(addr)).* = v;
}

pub fn main() void {
    if (!probeAndInit()) return;

    const ch = ferrite.channelCreate(0);
    if (ch < 0) {
        ferrite.console.print("[virtio-blk] channelCreate failed\n", .{}) catch {};
        return;
    }
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);

    fs.registerDevice("blk0", .block, svc_send) catch |e| {
        ferrite.console.print("[virtio-blk] registerDevice failed: {t}\n", .{e}) catch {};
        return;
    };

    state.fids[0] = .{ .used = true, .opened = true };

    const handlers: fs.Handlers(State) = .{
        .on_walk = onWalk,
        .on_open = onOpen,
        .on_read = onRead,
        .on_write = onWrite,
        .on_close = onClose,
        .on_status = onStatus,
    };
    fs.serve(State, svc_recv, &state, &handlers);
}

// Try PCI first (limine/UEFI/x86_64 expose virtio as PCI); fall back to MMIO
// (aarch64 raw/DTB exposes virtio-blk on the virtio-mmio transport).
fn probeAndInit() bool {
    page_size = ferrite.pageSize();
    if (initPci()) {
        driver.transport = .pci;
        ferrite.console.print("[virtio-blk] PCI transport, {d} sectors\n", .{driver.capacity_sectors}) catch {};
        return true;
    }
    if (initMmio()) {
        driver.transport = .mmio;
        ferrite.console.print("[virtio-blk] MMIO transport, {d} sectors\n", .{driver.capacity_sectors}) catch {};
        return true;
    }
    ferrite.console.print("[virtio-blk] no block device found\n", .{}) catch {};
    return false;
}

// Allocate + zero the shared virtqueue (desc/avail/used) and request buffer.
fn allocRings(ring_pa: *u64) bool {
    var q_va: usize = 0;
    var q_pa: u64 = 0;
    if (ferrite.dmaAlloc(1, &q_va, &q_pa) != 0) return false;
    driver.desc = @ptrFromInt(q_va + 0x000);
    driver.avail = @ptrFromInt(q_va + 0x080);
    driver.used = @ptrFromInt(q_va + 0x100);
    var i: u32 = 0;
    while (i < QSIZE) : (i += 1) driver.desc[i] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
    driver.avail.* = std.mem.zeroes(Avail);
    // VIRTQ_AVAIL_F_NO_INTERRUPT: we poll, so suppress interrupts or the device
    // storms a shared INTx line claimed by an IRQ-driven driver.
    driver.avail.flags = 1;
    driver.used.* = std.mem.zeroes(Used);

    var b_va: usize = 0;
    if (ferrite.dmaAlloc(1, &b_va, &driver.b_pa) != 0) return false;
    driver.header = @ptrFromInt(b_va + 0x000);
    driver.data = @ptrFromInt(b_va + 0x010);
    driver.status_byte = @ptrFromInt(b_va + 0x210);
    ring_pa.* = q_pa;
    return true;
}

fn notifyQueue() void {
    switch (driver.transport) {
        .mmio => w32(R.QUEUE_NOTIFY, 0),
        .pci => aw16(driver.notify_addr, 0),
    }
}

fn initMmio() bool {
    var version: u32 = 0;
    var idx: u32 = 0;
    var cached_page: u64 = 0;
    var cached_va: usize = 0;
    while (true) : (idx += 1) {
        const maybe = ferrite.probe.findDevice(VIRTIO_MMIO_COMPATIBLE, idx) catch return false;
        const info = maybe orelse return false;
        const slot_page = info.phys & ~@as(u64, page_size - 1);
        const slot_offset: usize = @intCast(info.phys - slot_page);
        if (slot_page != cached_page) {
            const map_len = (slot_offset + info.size + page_size - 1) & ~@as(u64, page_size - 1);
            const cap_h = ferrite.mmioCreate(slot_page, @intCast(map_len));
            if (cap_h < 0) continue;
            const va = ferrite.mmap(@intCast(cap_h), ferrite.PROT_READ | ferrite.PROT_WRITE);
            if (va < 0 and va > -64) continue;
            cached_page = slot_page;
            cached_va = @bitCast(@as(isize, va));
        }
        driver.mmio_base = cached_va + slot_offset;
        if (r32(R.MAGIC) != VIRTIO_MAGIC) continue;
        if (r32(R.DEV_ID) != VIRTIO_BLK_DEV_ID) continue;
        version = r32(R.VERSION);
        if (version != VIRTIO_VERSION_LEGACY and version != VIRTIO_VERSION_MODERN) continue;
        break;
    }
    driver.is_legacy = (version == VIRTIO_VERSION_LEGACY);
    driver.transport = .mmio;

    w32(R.STATUS, 0);
    w32(R.STATUS, S.ACK);
    w32(R.STATUS, S.ACK | S.DRIVER);

    if (driver.is_legacy) {
        _ = r32(R.DEV_FEAT);
        w32(R.DRV_FEAT, 0);
        w32(R.LEGACY_GUEST_PAGE_SIZE, @intCast(page_size));
    } else {
        w32(R.DEV_FEAT_SEL, 0);
        _ = r32(R.DEV_FEAT);
        w32(R.DRV_FEAT_SEL, 0);
        w32(R.DRV_FEAT, 0);
        w32(R.DRV_FEAT_SEL, 1);
        w32(R.DRV_FEAT, 0);
        w32(R.STATUS, S.ACK | S.DRIVER | S.FEATURES_OK);
        if ((r32(R.STATUS) & S.FEATURES_OK) == 0) return false;
    }

    driver.capacity_sectors = (@as(u64, r32(R.CONFIG + 4)) << 32) | @as(u64, r32(R.CONFIG + 0));

    w32(R.QUEUE_SEL, 0);
    if (r32(R.QUEUE_NUM_MAX) < QSIZE) return false;
    w32(R.QUEUE_NUM, QSIZE);

    var q_pa: u64 = 0;
    if (!allocRings(&q_pa)) return false;

    if (driver.is_legacy) {
        w32(R.LEGACY_QUEUE_ALIGN, LEGACY_QUEUE_ALIGN_BYTES);
        w32(R.LEGACY_QUEUE_PFN, @intCast(q_pa / page_size));
        w32(R.STATUS, S.ACK | S.DRIVER | S.DRIVER_OK);
    } else {
        w32(R.QUEUE_DESC_LOW, @truncate(q_pa));
        w32(R.QUEUE_DESC_HIGH, @truncate(q_pa >> 32));
        w32(R.QUEUE_DRIVER_LOW, @truncate(q_pa + 0x080));
        w32(R.QUEUE_DRIVER_HIGH, @truncate((q_pa + 0x080) >> 32));
        w32(R.QUEUE_DEVICE_LOW, @truncate(q_pa + 0x100));
        w32(R.QUEUE_DEVICE_HIGH, @truncate((q_pa + 0x100) >> 32));
        w32(R.QUEUE_READY, 1);
        w32(R.STATUS, S.ACK | S.DRIVER | S.FEATURES_OK | S.DRIVER_OK);
    }
    return true;
}

fn initPci() bool {
    var bdf: [12]u8 = undefined;
    if (!findDevice(&bdf)) return false;

    var caps: Caps = .{};
    if (!walkVirtioCaps(&bdf, &caps)) return false;
    const common = caps.common orelse return false;
    const notify_cap = caps.notify orelse return false;
    const device = caps.device orelse return false;

    var bar_va: [6]?usize = @splat(null);
    bar_va[common.bar] = mapBar(&bdf, common.bar) orelse return false;
    if (bar_va[notify_cap.bar] == null) bar_va[notify_cap.bar] = mapBar(&bdf, notify_cap.bar) orelse return false;
    if (bar_va[device.bar] == null) bar_va[device.bar] = mapBar(&bdf, device.bar) orelse return false;

    driver.common_base = bar_va[common.bar].? + common.offset;
    const notify_base = bar_va[notify_cap.bar].? + notify_cap.offset;
    const device_base = bar_va[device.bar].? + device.offset;
    driver.transport = .pci;

    // Map the ISR status register: reading it after an INTx interrupt clears the
    // device's interrupt cause and de-asserts the (shared, level-triggered) line.
    if (caps.isr) |isr| {
        if (bar_va[isr.bar] == null) bar_va[isr.bar] = mapBar(&bdf, isr.bar);
        if (bar_va[isr.bar]) |b| driver.isr_base = b + isr.offset;
    }

    const cb = driver.common_base;
    aw8(cb + C.DEVICE_STATUS, 0);
    while (a8(cb + C.DEVICE_STATUS) != 0) {}
    aw8(cb + C.DEVICE_STATUS, S.ACK);
    aw8(cb + C.DEVICE_STATUS, S.ACK | S.DRIVER);

    // Negotiate VERSION_1 only.
    aw32(cb + C.DEVICE_FEATURE_SELECT, 0);
    _ = a32(cb + C.DEVICE_FEATURE);
    aw32(cb + C.DEVICE_FEATURE_SELECT, 1);
    const feat_hi = a32(cb + C.DEVICE_FEATURE);
    if ((feat_hi & 0x1) == 0) { // VIRTIO_F_VERSION_1 is bit 32
        aw8(cb + C.DEVICE_STATUS, 0x80);
        return false;
    }
    aw32(cb + C.DRIVER_FEATURE_SELECT, 0);
    aw32(cb + C.DRIVER_FEATURE, 0);
    aw32(cb + C.DRIVER_FEATURE_SELECT, 1);
    aw32(cb + C.DRIVER_FEATURE, 1); // set VERSION_1
    aw8(cb + C.DEVICE_STATUS, S.ACK | S.DRIVER | S.FEATURES_OK);
    if ((a8(cb + C.DEVICE_STATUS) & S.FEATURES_OK) == 0) return false;

    // blk device config: capacity is a u64 at device-config offset 0.
    driver.capacity_sectors = (@as(u64, a32(device_base + 4)) << 32) | @as(u64, a32(device_base + 0));

    aw16(cb + C.QUEUE_SELECT, 0);
    if (a16(cb + C.QUEUE_SIZE) < QSIZE) return false;
    aw16(cb + C.QUEUE_SIZE, QSIZE);

    var q_pa: u64 = 0;
    if (!allocRings(&q_pa)) return false;

    aw16(cb + C.QUEUE_MSIX_VECTOR, MSIX_NO_VECTOR);
    aw64(cb + C.QUEUE_DESC, q_pa);
    aw64(cb + C.QUEUE_AVAIL, q_pa + 0x080);
    aw64(cb + C.QUEUE_USED, q_pa + 0x100);

    const notify_off = a16(cb + C.QUEUE_NOTIFY_OFF);
    driver.notify_addr = notify_base + (@as(usize, notify_off) * @as(usize, notify_cap.notify_multiplier));

    aw16(cb + C.QUEUE_ENABLE, 1);
    aw8(cb + C.DEVICE_STATUS, S.ACK | S.DRIVER | S.FEATURES_OK | S.DRIVER_OK);

    // IRQ disabled: inline block-on-IRQ in the completion path is incompatible
    // with shared, level-triggered INTx (an idle blk in fs.serve never acks the
    // shared line, stranding the mask). Poll instead until the dedicated-irq-
    // thread + completion-channel model lands. See ferrite-irq-userspace.
    driver.irq_num = 0;
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
    const h = ferrite.irqCreate(driver.irq_num);
    if (h < 0) return false;
    driver.irq_handle = @intCast(h);
    const rh = ferrite.irqListen(driver.irq_handle);
    if (rh < 0) return false;
    driver.irq_recv = @intCast(rh);
    return true;
}

// Requests, transport-independent ring usage.
fn submitRequest(op: u32, sector: u64) bool {
    driver.header.* = .{ .type = op, .reserved = 0, .sector = sector };
    driver.status_byte.* = 0xff;

    const data_flags: u16 = if (op == BLK_IN) (DESC_NEXT | DESC_WRITE) else DESC_NEXT;
    driver.desc[0] = .{ .addr = driver.b_pa + 0x000, .len = 16, .flags = DESC_NEXT, .next = 1 };
    driver.desc[1] = .{ .addr = driver.b_pa + 0x010, .len = 512, .flags = data_flags, .next = 2 };
    driver.desc[2] = .{ .addr = driver.b_pa + 0x210, .len = 1, .flags = DESC_WRITE, .next = 0 };

    const idx = driver.avail.idx;
    driver.avail.ring[idx % QSIZE] = 0;
    ferrite.barrier.storeStore();
    driver.avail.idx = idx +% 1;
    ferrite.barrier.full();
    notifyQueue();

    if (!waitForCompletion(idx)) return false;
    ferrite.barrier.full();
    if (driver.transport == .mmio) w32(R.INT_ACK, r32(R.INT_STATUS));
    return driver.status_byte.* == 0;
}

// Block until the used ring advances past `idx` (request complete). With a
// usable INTx, sleep on the IRQ channel (zero CPU while the device works);
// otherwise spin-poll. Detection is `driver.used.idx != idx` either way.
fn waitForCompletion(idx: u16) bool {
    if (driver.irq_num != 0) {
        var msg: [16]u8 = undefined;
        // Bound the number of blocking waits so a lost/coalesced interrupt can't
        // hang us forever; each wake re-checks the ring, and a recv error drops
        // us into the spin-poll fallback below.
        var waits: u32 = 0;
        while (waits < 1000) : (waits += 1) {
            ferrite.barrier.full();
            if (driver.used.idx != idx) return true;

            var cap_out: u32 = 0;
            const n = ferrite.recv(driver.irq_recv, &msg, &cap_out);
            if (n < 0) break; // recv failed: fall back to polling.

            // Read the ISR to de-assert the device's shared, level-triggered
            // line, re-check the used ring, then ack to unmask the GIC line.
            // The line may be shared with another device, so an empty ISR /
            // unchanged ring just means we re-wait.
            if (driver.isr_base != 0) _ = @as(*volatile u8, @ptrFromInt(driver.isr_base)).*;
            ferrite.barrier.full();
            const done = driver.used.idx != idx;
            _ = ferrite.irqAck(driver.irq_handle);
            if (done) return true;
        }
    }

    // Spin-poll fallback (no usable IRQ, or recv/IRQ path gave up).
    var spins: u64 = 0;
    while (driver.used.idx == idx) {
        spins +%= 1;
        if (spins > 50_000_000) return false;
    }
    return true;
}

inline fn readSector(sector: u64) bool {
    return submitRequest(BLK_IN, sector);
}
inline fn writeSector(sector: u64) bool {
    return submitRequest(BLK_OUT, sector);
}

fn onWalk(s: *State, fid: u32, path: []const u8) fs.HandlerError!fs.WalkResult {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    if (it.next() != null) return error.NotFound;
    var i: u32 = 1;
    while (i < MAX_FIDS) : (i += 1) {
        if (!s.fids[i].used) {
            s.fids[i] = .{ .used = true, .opened = false };
            return .{ .bound = i };
        }
    }
    return error.ServerBusy;
}

fn onOpen(s: *State, fid: u32, _: p9.Mode) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    s.fids[fid].opened = true;
}

fn onRead(_: *State, fid: u32, offset: u64, out: []u8) fs.HandlerError!usize {
    if (fid >= MAX_FIDS or !state.fids[fid].used or !state.fids[fid].opened) return error.BadFid;
    const total_bytes = driver.capacity_sectors * SECTOR;
    if (offset >= total_bytes) return 0;

    const sector = offset / SECTOR;
    const within: usize = @intCast(offset - sector * SECTOR);
    if (!readSector(sector)) return error.BadOp;

    const remaining_in_sector = SECTOR - within;
    const remaining_in_file: usize = @intCast(total_bytes - offset);
    const want = @min(@min(remaining_in_sector, remaining_in_file), out.len);
    var i: usize = 0;
    while (i < want) : (i += 1) out[i] = driver.data[within + i];
    return want;
}

fn onWrite(_: *State, fid: u32, offset: u64, data: []const u8) fs.HandlerError!u32 {
    if (fid >= MAX_FIDS or !state.fids[fid].used or !state.fids[fid].opened) return error.BadFid;
    const total_bytes = driver.capacity_sectors * SECTOR;
    if (offset >= total_bytes or data.len == 0) return 0;

    const sector = offset / SECTOR;
    const within: usize = @intCast(offset - sector * SECTOR);
    const remaining_in_sector = SECTOR - within;
    const remaining_in_file = total_bytes - offset;
    const want = @min(@min(remaining_in_sector, remaining_in_file), data.len);

    if (within != 0 or want != SECTOR) {
        if (!readSector(sector)) return error.BadOp;
    }
    var i: usize = 0;
    while (i < want) : (i += 1) driver.data[within + i] = data[i];
    if (!writeSector(sector)) return error.BadOp;
    return @intCast(want);
}

fn onClose(s: *State, fid: u32) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    if (fid != 0) s.fids[fid] = .{};
}

fn onStatus(_: *State, fid: u32) fs.HandlerError!p9.StatusReply {
    if (fid >= MAX_FIDS or !state.fids[fid].used) return error.BadFid;
    return .{ .kind = .file, .size = driver.capacity_sectors * SECTOR };
}

// PCI discovery helpers, mirrors drv.virtio-rng.
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
        if (matchDevice(line[0..12].*)) {
            @memcpy(out_bdf, line[0..12]);
            return true;
        }
    }
    return false;
}

fn matchDevice(bdf: [12]u8) bool {
    var path_buf: [64]u8 = undefined;
    const v_path = std.fmt.bufPrint(&path_buf, "/dev/pci/{s}/vendor", .{bdf[0..12]}) catch return false;
    var v_text: [16]u8 = undefined;
    const v_len = readPath(v_path, &v_text) orelse return false;
    const vendor = parseHex(v_text[0..v_len]) orelse return false;
    if (vendor != VIRTIO_VENDOR) return false;

    const d_path = std.fmt.bufPrint(&path_buf, "/dev/pci/{s}/device", .{bdf[0..12]}) catch return false;
    var d_text: [16]u8 = undefined;
    const d_len = readPath(d_path, &d_text) orelse return false;
    const dev_id = parseHex(d_text[0..d_len]) orelse return false;
    return dev_id == VIRTIO_BLK_PCI_MODERN or dev_id == VIRTIO_BLK_PCI_LEGACY;
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

    const ps: usize = ferrite.pageSize();
    const aligned_phys = phys & ~@as(u64, ps - 1);
    const aligned_size = (size + (phys - aligned_phys) + ps - 1) & ~@as(u64, ps - 1);
    const cap = ferrite.mmioCreate(aligned_phys, @intCast(aligned_size));
    if (cap < 0) return null;
    const va = ferrite.mmap(@intCast(cap), ferrite.PROT_READ | ferrite.PROT_WRITE);
    if (va < 0 and va > -64) return null;
    const va_u: usize = @bitCast(@as(isize, va));
    return va_u + @as(usize, @intCast(phys - aligned_phys));
}
