const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const p9 = ferrite.p9;
const fs = ferrite.fs;

const VIRTIO_VENDOR: u16 = 0x1af4;
const NET_CLASS: u8 = 0x02;

// virtio cap cfg_type values
const VIRTIO_CAP_COMMON: u8 = 1;
const VIRTIO_CAP_NOTIFY: u8 = 2;
const VIRTIO_CAP_ISR: u8 = 3;
const VIRTIO_CAP_DEVICE: u8 = 4;

// Device status bits
const STATUS_ACK: u8 = 1;
const STATUS_DRIVER: u8 = 2;
const STATUS_DRIVER_OK: u8 = 4;
const STATUS_FEATURES_OK: u8 = 8;
const STATUS_FAILED: u8 = 0x80;

// Feature bits we care about (low 64).
const VIRTIO_NET_F_MAC: u64 = 1 << 5;
const VIRTIO_NET_F_STATUS: u64 = 1 << 16;
const VIRTIO_F_VERSION_1: u64 = 1 << 32;

const VQ_RX: u16 = 0;
const VQ_TX: u16 = 1;
const QSIZE: u16 = 64;
const FRAME_MAX: usize = 1518;
const NET_HDR_LEN: usize = 12; // virtio 1.0 mandates 12-byte header
const BUF_SIZE: usize = NET_HDR_LEN + FRAME_MAX;

// Common config layout (virtio 1.0 §4.1.4.3).
const C = struct {
    const DEVICE_FEATURE_SELECT = 0x00;
    const DEVICE_FEATURE = 0x04;
    const DRIVER_FEATURE_SELECT = 0x08;
    const DRIVER_FEATURE = 0x0C;
    const CONFIG_MSIX_VECTOR = 0x10;
    const NUM_QUEUES = 0x12;
    const DEVICE_STATUS = 0x14;
    const CONFIG_GENERATION = 0x15;
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

const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};
const DESC_NEXT: u16 = 1;
const DESC_WRITE: u16 = 2;

const AvailRing = extern struct {
    flags: u16,
    idx: u16,
    ring: [QSIZE]u16,
    used_event: u16,
};

const UsedElem = extern struct {
    id: u32,
    len: u32,
};
const UsedRing = extern struct {
    flags: u16,
    idx: u16,
    ring: [QSIZE]UsedElem,
    avail_event: u16,
};

const VQueue = struct {
    desc: [*]volatile Desc,
    avail: *volatile AvailRing,
    used: *volatile UsedRing,
    bufs_va: usize,
    bufs_pa: u64,
    notify_addr: usize,
    last_used: u16,
};

const NetHdr = extern struct {
    flags: u8 = 0,
    gso_type: u8 = 0,
    hdr_len: u16 = 0,
    gso_size: u16 = 0,
    csum_start: u16 = 0,
    csum_offset: u16 = 0,
    num_buffers: u16 = 0,
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
var mac: [6]u8 = @splat(0);

var rxq: VQueue = undefined;
var txq: VQueue = undefined;

// Each read returns one frame (partial reads truncate); each write sends one.
const MAX_FIDS = 8;
const Fid = struct {
    used: bool = false,
    opened: bool = false,
    is_mac: bool = false,
};
const State = struct {
    fids: [MAX_FIDS]Fid = @splat(.{}),
};
var state: State = .{};

// Async RX machinery: fs.serve drain + pollThread drain race on ring_lock.
// Single waiter slot.
var pending_reply_cap: u32 = 0;
var pending_tag: u8 = 0;
var pending_want: u32 = 0;
var resp_buf: [BUF_SIZE]u8 = undefined;
var ring_lock: u32 = 0;

// INTx: ISR status register (reading it acks/de-asserts the device's line),
// the device's GIC INTID, and the IRQ-wait channel. irq_num == 0 means no
// usable IRQ (other arches), so fall back to polling.
var isr_base: usize = 0;
var irq_num: u32 = 0;
var irq_handle: u32 = 0;
var irq_recv: u32 = 0;

inline fn lockRing() void {
    while (@atomicRmw(u32, &ring_lock, .Xchg, 1, .acquire) != 0) ferrite.yield();
}
inline fn unlockRing() void {
    @atomicStore(u32, &ring_lock, 0, .release);
}

inline fn r8(addr: usize) u8 {
    return @as(*volatile u8, @ptrFromInt(addr)).*;
}
inline fn r16(addr: usize) u16 {
    return @as(*volatile u16, @ptrFromInt(addr)).*;
}
inline fn r32(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}
inline fn r64(addr: usize) u64 {
    return @as(*volatile u64, @ptrFromInt(addr)).*;
}
inline fn w8(addr: usize, v: u8) void {
    @as(*volatile u8, @ptrFromInt(addr)).* = v;
}
inline fn w16(addr: usize, v: u16) void {
    @as(*volatile u16, @ptrFromInt(addr)).* = v;
}
inline fn w32(addr: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = v;
}
inline fn w64(addr: usize, v: u64) void {
    @as(*volatile u64, @ptrFromInt(addr)).* = v;
}

pub fn main() void {
    if (!findAndInit()) return;

    const ch = ferrite.channelCreate(0);
    if (ch < 0) {
        ferrite.console.print("[virtio-net] channelCreate failed\n", .{}) catch {};
        return;
    }
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);

    fs.registerDevice("eth0", .char, svc_send) catch |e| {
        ferrite.console.print("[virtio-net] registerDevice failed: {t}\n", .{e}) catch {};
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
        .on_read_async = onReadAsync,
    };

    if (!startRxThread()) {
        ferrite.console.print("[virtio-net] startRxThread failed\n", .{}) catch {};
        return;
    }

    fs.serve(State, svc_recv, &state, &handlers);
}

fn findAndInit() bool {
    var bdf_buf: [12]u8 = undefined;
    if (!findVirtioNet(&bdf_buf)) {
        ferrite.console.print("[virtio-net] no virtio-net device on PCI\n", .{}) catch {};
        return false;
    }

    var caps: Caps = .{};
    if (!walkVirtioCaps(&bdf_buf, &caps)) {
        ferrite.console.print("[virtio-net] cap walk failed\n", .{}) catch {};
        return false;
    }
    const common = caps.common orelse {
        ferrite.console.print("[virtio-net] no common cfg cap\n", .{}) catch {};
        return false;
    };
    const notify_cap = caps.notify orelse {
        ferrite.console.print("[virtio-net] no notify cap\n", .{}) catch {};
        return false;
    };
    const device = caps.device orelse {
        ferrite.console.print("[virtio-net] no device cfg cap\n", .{}) catch {};
        return false;
    };

    // QEMU virt puts common/notify/isr in BAR4, so map each BAR once.
    var bar_va: [6]?usize = @splat(null);
    bar_va[common.bar] = mapBar(&bdf_buf, common.bar) orelse return false;
    if (bar_va[notify_cap.bar] == null) bar_va[notify_cap.bar] = mapBar(&bdf_buf, notify_cap.bar) orelse return false;
    if (bar_va[device.bar] == null) bar_va[device.bar] = mapBar(&bdf_buf, device.bar) orelse return false;

    common_base = bar_va[common.bar].? + common.offset;
    notify_base = bar_va[notify_cap.bar].? + notify_cap.offset;
    notify_multiplier = notify_cap.notify_multiplier;
    device_base = bar_va[device.bar].? + device.offset;

    // Map the ISR status register: reading it after an INTx interrupt clears
    // the device's interrupt cause and de-asserts the (shared, level-triggered)
    // line. Without this the GIC line stays asserted after unmask.
    if (caps.isr) |isr| {
        if (bar_va[isr.bar] == null) bar_va[isr.bar] = mapBar(&bdf_buf, isr.bar);
        if (bar_va[isr.bar]) |b| isr_base = b + isr.offset;
    }

    // net runs IRQ-driven RX (other virtio drivers still poll). irq_num != 0
    // spawns the IRQ RX thread; 0 falls back to the nanosleep poll thread.
    irq_num = readIrq(&bdf_buf);

    w8(common_base + C.DEVICE_STATUS, 0);
    var resets: u32 = 0;
    while (r8(common_base + C.DEVICE_STATUS) != 0) {
        resets += 1;
        if (resets > 1_000_000) {
            ferrite.console.print("[virtio-net] device stuck in reset\n", .{}) catch {};
            return false;
        }
    }
    w8(common_base + C.DEVICE_STATUS, STATUS_ACK);
    w8(common_base + C.DEVICE_STATUS, STATUS_ACK | STATUS_DRIVER);

    const dev_features = readFeatures();
    const wanted = VIRTIO_F_VERSION_1 | VIRTIO_NET_F_MAC;
    if ((dev_features & wanted) != wanted) {
        ferrite.console.print("[virtio-net] device missing required features (0x{x})\n", .{dev_features}) catch {};
        w8(common_base + C.DEVICE_STATUS, STATUS_FAILED);
        return false;
    }
    writeFeatures(wanted);

    w8(common_base + C.DEVICE_STATUS, STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK);
    if ((r8(common_base + C.DEVICE_STATUS) & STATUS_FEATURES_OK) == 0) {
        ferrite.console.print("[virtio-net] features rejected\n", .{}) catch {};
        return false;
    }

    for (&mac, 0..) |*b, i| b.* = r8(device_base + i);

    if (!setupQueue(&rxq, VQ_RX, true)) return false;
    if (!setupQueue(&txq, VQ_TX, false)) return false;

    w8(common_base + C.DEVICE_STATUS, STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK);

    primeRx();

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
const BUF_PAGES: u64 = 32; // 64 buffers of 2048B
const DESC_BYTES: usize = @sizeOf(Desc) * QSIZE;
const AVAIL_BYTES: usize = @sizeOf(AvailRing);
const USED_OFFSET: usize = 0x800;

fn setupQueue(q: *VQueue, qidx: u16, fill_rx: bool) bool {
    _ = fill_rx;
    w16(common_base + C.QUEUE_SELECT, qidx);
    const max = r16(common_base + C.QUEUE_SIZE);
    if (max < QSIZE) {
        ferrite.console.print("[virtio-net] queue {d} too small (max={d})\n", .{ qidx, max }) catch {};
        return false;
    }
    w16(common_base + C.QUEUE_SIZE, QSIZE);

    var ring_va: usize = 0;
    var ring_pa: u64 = 0;
    if (ferrite.dmaAlloc(RING_PAGES, &ring_va, &ring_pa) != 0) {
        ferrite.console.print("[virtio-net] dmaAlloc(ring) failed\n", .{}) catch {};
        return false;
    }
    var bufs_va: usize = 0;
    var bufs_pa: u64 = 0;
    if (ferrite.dmaAlloc(BUF_PAGES, &bufs_va, &bufs_pa) != 0) {
        ferrite.console.print("[virtio-net] dmaAlloc(bufs) failed\n", .{}) catch {};
        return false;
    }

    q.desc = @ptrFromInt(@as(usize, @intCast(ring_va)));
    q.avail = @ptrFromInt(@as(usize, @intCast(ring_va)) + DESC_BYTES);
    q.used = @ptrFromInt(@as(usize, @intCast(ring_va)) + USED_OFFSET);
    q.bufs_va = @intCast(bufs_va);
    q.bufs_pa = bufs_pa;
    q.last_used = 0;

    var i: u32 = 0;
    while (i < QSIZE) : (i += 1) {
        q.desc[i] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
    }
    q.avail.* = std.mem.zeroes(AvailRing);
    q.used.* = std.mem.zeroes(UsedRing);

    w16(common_base + C.QUEUE_MSIX_VECTOR, MSIX_NO_VECTOR);
    w64(common_base + C.QUEUE_DESC, ring_pa);
    w64(common_base + C.QUEUE_AVAIL, ring_pa + DESC_BYTES);
    w64(common_base + C.QUEUE_USED, ring_pa + USED_OFFSET);

    const notify_off = r16(common_base + C.QUEUE_NOTIFY_OFF);
    q.notify_addr = notify_base + (@as(usize, notify_off) * @as(usize, notify_multiplier));

    w16(common_base + C.QUEUE_ENABLE, 1);
    return true;
}

fn primeRx() void {
    var i: u16 = 0;
    while (i < QSIZE) : (i += 1) {
        rxq.desc[i] = .{
            .addr = rxq.bufs_pa + @as(u64, i) * BUF_SIZE,
            .len = BUF_SIZE,
            .flags = DESC_WRITE,
            .next = 0,
        };
        rxq.avail.ring[i] = i;
    }
    ferrite.barrier.storeStore();
    rxq.avail.idx = QSIZE;
    ferrite.barrier.full();
    notify(&rxq, VQ_RX);
}

fn notify(q: *VQueue, qidx: u16) void {
    w16(q.notify_addr, qidx);
}

fn findVirtioNet(out_bdf: *[12]u8) bool {
    var attempts: u32 = 0;
    while (attempts < 16) : (attempts += 1) {
        if (tryFindVirtioNet(out_bdf)) return true;
        var i: u32 = 0;
        while (i < 8) : (i += 1) ferrite.yield();
    }
    return false;
}

fn tryFindVirtioNet(out_bdf: *[12]u8) bool {
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
        const bdf = line;
        if (matchVirtioNet(bdf)) {
            @memcpy(out_bdf, bdf[0..12]);
            return true;
        }
    }
    return false;
}

fn matchVirtioNet(bdf: []const u8) bool {
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
    return class_byte == NET_CLASS;
}

fn readIrq(bdf: *const [12]u8) u32 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/dev/pci/{s}/irq", .{bdf}) catch return 0;
    var text: [16]u8 = undefined;
    const len = readPath(path, &text) orelse return 0;
    return std.fmt.parseInt(u32, text[0..len], 10) catch 0; // "none" -> 0
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

    // Status reg bit 4 = capabilities list present.
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

    // text: "phys=0x... size=0x..."
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
    // i386's USER_MMAP_BASE is 0x8000_0000, negative as i32. A plain
    // `va < 0` would reject valid VAs; errors are small negatives only.
    const va = ferrite.mmap(@intCast(cap), ferrite.PROT_READ | ferrite.PROT_WRITE);
    if (va < 0 and va > -64) return null;
    const va_u: usize = @bitCast(@as(isize, va));
    return va_u + @as(usize, @intCast(phys - aligned_phys));
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

fn onWalk(s: *State, fid: u32, path: []const u8) fs.HandlerError!fs.WalkResult {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    var is_mac = s.fids[fid].is_mac;
    while (it.next()) |comp| {
        if (is_mac) return error.NotFound;
        if (std.mem.eql(u8, comp, "mac")) {
            is_mac = true;
        } else return error.NotFound;
    }
    var i: u32 = 1;
    while (i < MAX_FIDS) : (i += 1) {
        if (!s.fids[i].used) {
            s.fids[i] = .{ .used = true, .opened = false, .is_mac = is_mac };
            return .{ .bound = i };
        }
    }
    return error.ServerBusy;
}

fn onOpen(s: *State, fid: u32, _: p9.Mode) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    s.fids[fid].opened = true;
}

/// Caller holds ring_lock. Acquire load on used.idx is mandatory on aarch64:
/// the device publishes idx with release, and without the matching acquire
/// the ring entry write is invisible, so inbound packets get missed.
fn drainOne(out: []u8) ?usize {
    const idx_now = @atomicLoad(u16, &rxq.used.idx, .acquire);
    if (idx_now == rxq.last_used) return null;
    const slot = rxq.last_used % QSIZE;
    const used = rxq.used.ring[slot];
    rxq.last_used +%= 1;

    const desc_idx: u16 = @intCast(used.id);
    const total: usize = @intCast(used.len);
    if (total < NET_HDR_LEN) {
        rxq.avail.ring[rxq.avail.idx % QSIZE] = desc_idx;
        ferrite.barrier.storeStore();
        rxq.avail.idx +%= 1;
        notify(&rxq, VQ_RX);
        return 0;
    }
    const frame_len = total - NET_HDR_LEN;
    const copy = @min(frame_len, out.len);
    const src = rxq.bufs_va + @as(usize, desc_idx) * BUF_SIZE + NET_HDR_LEN;
    const src_p: [*]const u8 = @ptrFromInt(src);
    @memcpy(out[0..copy], src_p[0..copy]);

    // dmb so the ring entry hits memory before avail.idx advances.
    rxq.avail.ring[rxq.avail.idx % QSIZE] = desc_idx;
    ferrite.barrier.storeStore();
    rxq.avail.idx +%= 1;
    ferrite.barrier.storeStore();
    notify(&rxq, VQ_RX);

    return copy;
}

fn onRead(s: *State, fid: u32, offset: u64, out: []u8) fs.HandlerError!usize {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    if (s.fids[fid].is_mac) return readMac(offset, out);

    // Sync fallback; non-blocking. Frame reads normally go via onReadAsync.
    lockRing();
    defer unlockRing();
    return drainOne(out) orelse 0;
}

/// Single-slot async; second waiter while one is parked returns empty.
fn onReadAsync(s: *State, pending: fs.PendingRead) fs.HandlerError!fs.ReadOutcome {
    if (pending.fid >= MAX_FIDS) return error.BadFid;
    const f = &s.fids[pending.fid];
    if (!f.used or !f.opened) return error.BadFid;
    if (f.is_mac) return .fall_through;

    const want: usize = @min(@as(usize, pending.want), resp_buf.len);

    lockRing();
    if (drainOne(resp_buf[0..want])) |n| {
        unlockRing();
        return .{ .immediate = resp_buf[0..n] };
    }

    if (@atomicLoad(u32, &pending_reply_cap, .acquire) != 0) {
        unlockRing();
        return .{ .immediate = "" };
    }
    pending_tag = pending.tag;
    pending_want = pending.want;
    @atomicStore(u32, &pending_reply_cap, pending.reply_cap, .release);

    // Re-drain under lock to close the arrived-between-drain-and-stash race.
    if (drainOne(resp_buf[0..want])) |n| {
        const claimed = @atomicRmw(u32, &pending_reply_cap, .Xchg, @as(u32, 0), .acquire);
        unlockRing();
        if (claimed != 0) {
            const p: fs.PendingRead = .{
                .reply_cap = claimed,
                .tag = pending_tag,
                .fid = pending.fid,
                .offset = 0,
                .want = pending_want,
            };
            p.respondRead(resp_buf[0..n]);
        }
        return .deferred;
    }
    unlockRing();
    return .deferred;
}

/// Drain the RX used ring and fulfill the parked async read, if any.
/// Shared by the irq-wait thread and the poll fallback.
fn drainAndFulfill() void {
    if (@atomicLoad(u32, &pending_reply_cap, .acquire) == 0) return;

    lockRing();
    const want: usize = @min(@as(usize, pending_want), resp_buf.len);
    const got = drainOne(resp_buf[0..want]);
    if (got) |n| {
        const claimed = @atomicRmw(u32, &pending_reply_cap, .Xchg, @as(u32, 0), .acquire);
        unlockRing();
        if (claimed != 0) {
            const p: fs.PendingRead = .{
                .reply_cap = claimed,
                .tag = pending_tag,
                .fid = 0,
                .offset = 0,
                .want = pending_want,
            };
            p.respondRead(resp_buf[0..n]);
        }
    } else {
        unlockRing();
    }
}

/// No-IRQ fallback (e.g. arches reporting irq "none"): poll with nanosleep.
fn pollThread() callconv(.c) noreturn {
    while (true) {
        ferrite.nanosleep(2_000_000);
        drainAndFulfill();
    }
}

/// IRQ-driven RX: block on the device's INTx channel (zero CPU when idle),
/// read the ISR to de-assert the shared, level-triggered line, drain + fulfill,
/// then ack to unmask the GIC line. A recv error falls back to a short sleep.
fn irqThread() callconv(.c) noreturn {
    var msg: [16]u8 = undefined;
    while (true) {
        var cap_out: u32 = 0;
        const n = ferrite.recv(irq_recv, &msg, &cap_out);
        if (n < 0) {
            ferrite.nanosleep(10_000_000);
            continue;
        }
        if (isr_base != 0) _ = @as(*volatile u8, @ptrFromInt(isr_base)).*;
        drainAndFulfill();
        _ = ferrite.irqAck(irq_handle);
    }
}

const POLL_STACK_PAGES: usize = 8;

fn spawnThread(entry: usize) bool {
    var stack_va: usize = 0;
    if (ferrite.allocPages(POLL_STACK_PAGES, &stack_va) != 0) return false;
    const stack_top = stack_va + POLL_STACK_PAGES * ferrite.pageSize() - 16;
    return ferrite.threadSpawn(entry, stack_top) >= 0;
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

/// Spawn the IRQ-wait thread when an INTID is available; otherwise fall back to
/// the nanosleep poll thread. Returns false only if no RX path could start.
fn startRxThread() bool {
    if (irq_num != 0 and bindIrq()) {
        return spawnThread(@intFromPtr(&irqThread));
    }
    irq_num = 0; // no IRQ (or bind failed): poll instead
    return spawnThread(@intFromPtr(&pollThread));
}

fn readMac(offset: u64, out: []u8) fs.HandlerError!usize {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}\n", .{
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
    }) catch return error.BadOp;
    if (offset >= text.len) return 0;
    const start: usize = @intCast(offset);
    const n = @min(text.len - start, out.len);
    @memcpy(out[0..n], text[start..][0..n]);
    return n;
}

fn onWrite(s: *State, fid: u32, _: u64, data: []const u8) fs.HandlerError!u32 {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    if (s.fids[fid].is_mac) return error.BadOp;
    if (data.len == 0 or data.len > FRAME_MAX) return error.BadOp;

    reapTx();

    const desc_idx: u16 = txq.avail.idx % QSIZE;
    const buf_va: usize = txq.bufs_va + @as(usize, desc_idx) * BUF_SIZE;
    const buf_pa: u64 = txq.bufs_pa + @as(u64, desc_idx) * BUF_SIZE;

    const hdr_p: *NetHdr = @ptrFromInt(buf_va);
    hdr_p.* = .{};
    const frame_p: [*]u8 = @ptrFromInt(buf_va + NET_HDR_LEN);
    @memcpy(frame_p[0..data.len], data);

    txq.desc[desc_idx] = .{
        .addr = buf_pa,
        .len = @intCast(NET_HDR_LEN + data.len),
        .flags = 0,
        .next = 0,
    };
    txq.avail.ring[txq.avail.idx % QSIZE] = desc_idx;
    ferrite.barrier.storeStore();
    txq.avail.idx +%= 1;
    ferrite.barrier.full();
    notify(&txq, VQ_TX);

    return @intCast(data.len);
}

fn reapTx() void {
    while (txq.used.idx != txq.last_used) {
        txq.last_used +%= 1;
    }
}

fn onClose(s: *State, fid: u32) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    if (fid != 0) s.fids[fid] = .{};
}

fn onStatus(s: *State, fid: u32) fs.HandlerError!p9.StatusReply {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    return .{ .kind = .file, .size = 0 };
}
