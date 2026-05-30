const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const p9 = ferrite.p9;
const fs = ferrite.fs;

const VIRTIO_VENDOR: u16 = 0x1af4;
// Modern virtio device id = 0x1040 + device type. Input is type 18.
const VIRTIO_INPUT_DEV_ID: u16 = 0x1052;

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

// virtio-input device-config selectors (virtio 1.x §5.8.4).
const CFG_ID_NAME: u8 = 0x01;

const VQ_EVENT: u16 = 0; // eventq carries device->driver input events
const QSIZE: u16 = 64;

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

const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};
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

// The wire event format is identical to Linux evdev: a packed
// {type, code, value} that consumers parse directly off /dev/input/eventN.
const InputEvent = extern struct {
    type: u16,
    code: u16,
    value: u32,
};
const EV_SIZE: usize = @sizeOf(InputEvent); // 8

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

const RING_PAGES: u64 = 1; // desc(1024) + avail + used all fit one page at QSIZE=64
const BUF_PAGES: u64 = 1; // QSIZE * 8 = 512 bytes of event buffers
const DESC_BYTES: usize = @sizeOf(Desc) * QSIZE;
const USED_OFFSET: usize = 0x800;

const FIFO_CAP: usize = 256; // software event backlog per device
const RESP_BYTES: usize = 512; // max bytes per read (64 events)

const Device = struct {
    common_base: usize = 0,
    notify_addr: usize = 0,

    desc: [*]volatile Desc = undefined,
    avail: *volatile AvailRing = undefined,
    used: *volatile UsedRing = undefined,
    bufs_va: usize = 0,
    bufs_pa: u64 = 0,
    last_used: u16 = 0,

    name: [48]u8 = @splat(0),
    name_len: usize = 0,

    // Software FIFO of drained events. The poll thread fills it; reads drain it.
    fifo: [FIFO_CAP]InputEvent = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    // Single outstanding async read (one reader per device is the norm).
    pending_cap: u32 = 0,
    pending_tag: u8 = 0,
    pending_want: u32 = 0,
    resp: [RESP_BYTES]u8 = undefined,

    // INTx: ISR status register (reading it acks/de-asserts the device's line),
    // the GIC IRQ this device's INTx lands on, and the IRQ-wait channel.
    // irq_num == 0 means no usable IRQ (other arches), so it falls back to polling.
    isr_base: usize = 0,
    irq_num: u32 = 0,
    irq_handle: u32 = 0,
    irq_recv: u32 = 0,
};

const MAX_DEVICES = 8;
var devices: [MAX_DEVICES]Device = undefined;
var ndev: usize = 0;

// fs.serve, the irq threads, and the poll fallback all touch device rings + FIFOs.
var ring_lock: u32 = 0;
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

const URI_PREFIX = "com.midstall.ferrite.input@v0";
const MOUNT_PREFIX = "/dev/input";

const FidKind = enum { root, devices_file, event };
const Fid = struct {
    used: bool = false,
    opened: bool = false,
    kind: FidKind = .root,
    dev: usize = 0,
};
const MAX_FIDS = 32;
const State = struct {
    fids: [MAX_FIDS]Fid = @splat(.{}),
};
var state: State = .{};

var serve_resp: [RESP_BYTES]u8 = undefined;

pub fn main() void {
    enumerateDevices();
    if (ndev == 0) {
        ferrite.console.print("[virtio-input] no devices on PCI\n", .{}) catch {};
        return;
    }

    setupInterrupts();

    const ch = ferrite.channelCreate(0);
    if (ch < 0) return;
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);

    fs.register(URI_PREFIX, svc_send) catch |e| {
        ferrite.console.print("[virtio-input] register failed: {t}\n", .{e}) catch {};
        return;
    };
    fs.mount(MOUNT_PREFIX, URI_PREFIX) catch |e| switch (e) {
        // Permission = nameserver already mounted us via /etc/mounts.
        error.Permission => {},
        else => {
            ferrite.console.print("[virtio-input] mount({s}) failed: {t}\n", .{ MOUNT_PREFIX, e }) catch {};
            return;
        },
    };

    state.fids[0] = .{ .used = true, .opened = true, .kind = .root };

    ferrite.console.print("[virtio-input] {d} device(s) at {s}\n", .{ ndev, MOUNT_PREFIX }) catch {};
    var di: usize = 0;
    while (di < ndev) : (di += 1) {
        const dev = &devices[di];
        if (dev.irq_num != 0) {
            ferrite.console.print("[virtio-input]   event{d}: {s} (irq {d})\n", .{ di, dev.name[0..dev.name_len], dev.irq_num }) catch {};
        } else {
            ferrite.console.print("[virtio-input]   event{d}: {s} (polled)\n", .{ di, dev.name[0..dev.name_len] }) catch {};
        }
    }

    const handlers: fs.Handlers(State) = .{
        .on_walk = onWalk,
        .on_open = onOpen,
        .on_read = onRead,
        .on_write = onWrite,
        .on_close = onClose,
        .on_status = onStatus,
        .on_read_async = onReadAsync,
    };
    fs.serve(State, svc_recv, &state, &handlers);
}

// --- device bring-up ------------------------------------------------------

fn enumerateDevices() void {
    // drv.pci may still be probing; retry the bus scan a few times.
    var attempts: u32 = 0;
    while (attempts < 16 and ndev == 0) : (attempts += 1) {
        scanBus();
        if (ndev == 0) {
            var i: u32 = 0;
            while (i < 8) : (i += 1) ferrite.yield();
        }
    }
}

fn scanBus() void {
    var uri_buf: [128]u8 = undefined;
    const pci_uri = fs.resolvePath("/dev/pci", &uri_buf) catch return;
    const pci_dir = fs.open(pci_uri, .{ .mode = .read }) catch return;
    defer pci_dir.close();

    var listing: [2048]u8 = undefined;
    var total: usize = 0;
    while (total < listing.len) {
        const n = pci_dir.read(total, listing[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    var it = std.mem.tokenizeScalar(u8, listing[0..total], '\n');
    while (it.next()) |line| {
        if (line.len != 12) continue;
        if (ndev >= MAX_DEVICES) return;
        if (!matchDevice(line[0..12].*)) continue;
        const dev = &devices[ndev];
        dev.* = .{};
        if (initDevice(line[0..12].*, dev)) {
            ndev += 1;
        }
    }
}

fn matchDevice(bdf: [12]u8) bool {
    var path_buf: [64]u8 = undefined;
    const v_path = std.fmt.bufPrint(&path_buf, "/dev/pci/{s}/vendor", .{bdf[0..12]}) catch return false;
    var v_text: [16]u8 = undefined;
    const v_len = readPath(v_path, &v_text) orelse return false;
    if ((parseHex(v_text[0..v_len]) orelse return false) != VIRTIO_VENDOR) return false;

    const d_path = std.fmt.bufPrint(&path_buf, "/dev/pci/{s}/device", .{bdf[0..12]}) catch return false;
    var d_text: [16]u8 = undefined;
    const d_len = readPath(d_path, &d_text) orelse return false;
    return (parseHex(d_text[0..d_len]) orelse return false) == VIRTIO_INPUT_DEV_ID;
}

fn initDevice(bdf: [12]u8, dev: *Device) bool {
    var caps: Caps = .{};
    if (!walkVirtioCaps(&bdf, &caps)) return false;
    const common = caps.common orelse return false;
    const notify_cap = caps.notify orelse return false;

    var bar_va: [6]?usize = @splat(null);
    bar_va[common.bar] = mapBar(&bdf, common.bar) orelse return false;
    if (bar_va[notify_cap.bar] == null) bar_va[notify_cap.bar] = mapBar(&bdf, notify_cap.bar) orelse return false;

    dev.common_base = bar_va[common.bar].? + common.offset;
    const notify_base = bar_va[notify_cap.bar].? + notify_cap.offset;

    // Map the ISR status register: reading it after an INTx interrupt clears the
    // device's interrupt cause and de-asserts the (shared, level-triggered) line.
    if (caps.isr) |isr| {
        if (bar_va[isr.bar] == null) bar_va[isr.bar] = mapBar(&bdf, isr.bar);
        if (bar_va[isr.bar]) |b| dev.isr_base = b + isr.offset;
    }

    const cb = dev.common_base;
    w8(cb + C.DEVICE_STATUS, 0);
    while (r8(cb + C.DEVICE_STATUS) != 0) {}
    w8(cb + C.DEVICE_STATUS, STATUS_ACK);
    w8(cb + C.DEVICE_STATUS, STATUS_ACK | STATUS_DRIVER);

    const dev_features = readFeatures(cb);
    if ((dev_features & VIRTIO_F_VERSION_1) != VIRTIO_F_VERSION_1) {
        w8(cb + C.DEVICE_STATUS, STATUS_FAILED);
        return false;
    }
    writeFeatures(cb, VIRTIO_F_VERSION_1);

    w8(cb + C.DEVICE_STATUS, STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK);
    if ((r8(cb + C.DEVICE_STATUS) & STATUS_FEATURES_OK) == 0) return false;

    if (!setupEventQueue(dev, notify_base, notify_cap.notify_multiplier)) return false;

    w8(cb + C.DEVICE_STATUS, STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK);

    // Best-effort name read so consumers can tell keyboard/mouse/tablet apart.
    readName(dev, &bdf, caps.device, &bar_va);
    if (dev.name_len == 0) {
        const fallback = "virtio-input";
        @memcpy(dev.name[0..fallback.len], fallback);
        dev.name_len = fallback.len;
    }

    // GIC INTID for this device's INTx (0 = none/other arch -> poll fallback).
    dev.irq_num = readIrq(&bdf);

    primeEventBuffers(dev);
    return true;
}

fn readIrq(bdf: *const [12]u8) u32 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/dev/pci/{s}/irq", .{bdf}) catch return 0;
    var text: [16]u8 = undefined;
    const len = readPath(path, &text) orelse return 0;
    return std.fmt.parseInt(u32, text[0..len], 10) catch 0; // "none" -> 0
}

fn readFeatures(cb: usize) u64 {
    w32(cb + C.DEVICE_FEATURE_SELECT, 0);
    const lo = r32(cb + C.DEVICE_FEATURE);
    w32(cb + C.DEVICE_FEATURE_SELECT, 1);
    const hi = r32(cb + C.DEVICE_FEATURE);
    return (@as(u64, hi) << 32) | @as(u64, lo);
}

fn writeFeatures(cb: usize, f: u64) void {
    w32(cb + C.DRIVER_FEATURE_SELECT, 0);
    w32(cb + C.DRIVER_FEATURE, @truncate(f));
    w32(cb + C.DRIVER_FEATURE_SELECT, 1);
    w32(cb + C.DRIVER_FEATURE, @truncate(f >> 32));
}

fn setupEventQueue(dev: *Device, notify_base: usize, notify_multiplier: u32) bool {
    const cb = dev.common_base;
    w16(cb + C.QUEUE_SELECT, VQ_EVENT);
    const max = r16(cb + C.QUEUE_SIZE);
    if (max < QSIZE) return false;
    w16(cb + C.QUEUE_SIZE, QSIZE);

    var ring_va: usize = 0;
    var ring_pa: u64 = 0;
    if (ferrite.dmaAlloc(RING_PAGES, &ring_va, &ring_pa) != 0) return false;
    var b_va: usize = 0;
    var b_pa: u64 = 0;
    if (ferrite.dmaAlloc(BUF_PAGES, &b_va, &b_pa) != 0) return false;

    dev.desc = @ptrFromInt(ring_va);
    dev.avail = @ptrFromInt(ring_va + DESC_BYTES);
    dev.used = @ptrFromInt(ring_va + USED_OFFSET);
    dev.bufs_va = b_va;
    dev.bufs_pa = b_pa;
    dev.last_used = 0;

    var i: u32 = 0;
    while (i < QSIZE) : (i += 1) dev.desc[i] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
    dev.avail.* = std.mem.zeroes(AvailRing);
    dev.used.* = std.mem.zeroes(UsedRing);

    w16(cb + C.QUEUE_MSIX_VECTOR, MSIX_NO_VECTOR);
    w64(cb + C.QUEUE_DESC, ring_pa);
    w64(cb + C.QUEUE_AVAIL, ring_pa + DESC_BYTES);
    w64(cb + C.QUEUE_USED, ring_pa + USED_OFFSET);

    const notify_off = r16(cb + C.QUEUE_NOTIFY_OFF);
    dev.notify_addr = notify_base + (@as(usize, notify_off) * @as(usize, notify_multiplier));

    w16(cb + C.QUEUE_ENABLE, 1);
    return true;
}

// Hand every event buffer to the device so it can fill them as input arrives.
fn primeEventBuffers(dev: *Device) void {
    var i: u16 = 0;
    while (i < QSIZE) : (i += 1) {
        dev.desc[i] = .{
            .addr = dev.bufs_pa + @as(u64, i) * EV_SIZE,
            .len = @intCast(EV_SIZE),
            .flags = DESC_WRITE,
            .next = 0,
        };
        dev.avail.ring[i] = i;
    }
    ferrite.barrier.storeStore();
    dev.avail.idx = QSIZE;
    ferrite.barrier.full();
    w16(dev.notify_addr, VQ_EVENT);
}

fn readName(dev: *Device, bdf: *const [12]u8, device_cap: ?VirtioCap, bar_va: *[6]?usize) void {
    const dcap = device_cap orelse return;
    if (bar_va[dcap.bar] == null) bar_va[dcap.bar] = mapBar(bdf, dcap.bar);
    const base = (bar_va[dcap.bar] orelse return) + dcap.offset;

    // virtio_input_config: select@0, subsel@1, size@2, payload@8.
    w8(base + 0, CFG_ID_NAME);
    w8(base + 1, 0);
    const size = r8(base + 2);
    const n = @min(@as(usize, size), dev.name.len);
    var i: usize = 0;
    while (i < n) : (i += 1) dev.name[i] = r8(base + 8 + i);
    dev.name_len = n;
}

// --- event draining -------------------------------------------------------

inline fn fifoPush(dev: *Device, ev: InputEvent) void {
    if (dev.count == FIFO_CAP) {
        // Backlog full (no reader). Drop the oldest so newest input survives.
        dev.head = (dev.head + 1) % FIFO_CAP;
        dev.count -= 1;
    }
    dev.fifo[dev.tail] = ev;
    dev.tail = (dev.tail + 1) % FIFO_CAP;
    dev.count += 1;
}

// Move events off the hardware used ring into the software FIFO, recycling
// each buffer back to the device. Caller holds ring_lock.
fn drainHwToFifo(dev: *Device) void {
    ferrite.barrier.full();
    var notified = false;
    while (dev.used.idx != dev.last_used) {
        const slot = dev.last_used % QSIZE;
        const u = dev.used.ring[slot];
        const desc_idx: u16 = @intCast(u.id);
        dev.last_used +%= 1;

        if (u.len >= EV_SIZE) {
            const src_va = dev.bufs_va + @as(usize, desc_idx) * EV_SIZE;
            fifoPush(dev, @as(*const InputEvent, @ptrFromInt(src_va)).*);
        }

        dev.avail.ring[dev.avail.idx % QSIZE] = desc_idx;
        ferrite.barrier.storeStore();
        dev.avail.idx +%= 1;
        notified = true;
    }
    if (notified) {
        ferrite.barrier.full();
        w16(dev.notify_addr, VQ_EVENT);
    }
}

// Pop whole events into `out`. Caller holds ring_lock. Returns bytes written.
fn popEvents(dev: *Device, out: []u8) usize {
    const max_ev = @min(out.len / EV_SIZE, dev.count);
    var i: usize = 0;
    while (i < max_ev) : (i += 1) {
        const ev = dev.fifo[dev.head];
        dev.head = (dev.head + 1) % FIFO_CAP;
        dev.count -= 1;
        @memcpy(out[i * EV_SIZE ..][0..EV_SIZE], std.mem.asBytes(&ev));
    }
    return max_ev * EV_SIZE;
}

// One irq-wait thread per device blocks on the device's INTx and drains on
// demand (zero CPU when idle). Devices with no usable IRQ (irq_num == 0, e.g.
// non-aarch64) fall back to a single shared nanosleep poll thread.

const STACK_PAGES: usize = 8;

// Drain a device's used ring into the FIFO and fulfill its parked read, if any.
// Shared by the irq threads and the poll fallback.
fn drainAndFulfill(dev: *Device) void {
    lockRing();
    drainHwToFifo(dev);
    if (@atomicLoad(u32, &dev.pending_cap, .acquire) == 0 or dev.count == 0) {
        unlockRing();
        return;
    }
    const want: usize = @min(@as(usize, dev.pending_want), dev.resp.len);
    const n = popEvents(dev, dev.resp[0..want]);
    const claimed = @atomicRmw(u32, &dev.pending_cap, .Xchg, @as(u32, 0), .acquire);
    const tag = dev.pending_tag;
    unlockRing();
    if (claimed == 0) return;
    const pr: fs.PendingRead = .{ .reply_cap = claimed, .tag = tag, .fid = 0, .offset = 0, .want = @intCast(want) };
    if (n > 0) pr.respondRead(dev.resp[0..n]) else pr.respondRead("");
}

// Block on the IRQ channel; on wake read the ISR (de-asserts the device's
// shared, level-triggered INTx line), drain, then ack to unmask the GIC line.
fn irqThread(idx: usize) noreturn {
    const dev = &devices[idx];
    var msg: [16]u8 = undefined;
    while (true) {
        var cap_out: u32 = 0;
        const n = ferrite.recv(dev.irq_recv, &msg, &cap_out);
        if (n < 0) {
            ferrite.nanosleep(10_000_000);
            continue;
        }
        if (dev.isr_base != 0) _ = @as(*volatile u8, @ptrFromInt(dev.isr_base)).*;
        drainAndFulfill(dev);
        _ = ferrite.irqAck(dev.irq_handle);
    }
}

// threadSpawn can't pass args, so bind each device index at comptime.
const irq_thread_entries: [MAX_DEVICES]*const fn () callconv(.c) noreturn = blk: {
    var arr: [MAX_DEVICES]*const fn () callconv(.c) noreturn = undefined;
    for (&arr, 0..) |*slot, i| {
        slot.* = &struct {
            const idx: usize = i;
            fn f() callconv(.c) noreturn {
                irqThread(idx);
            }
        }.f;
    }
    break :blk arr;
};

fn spawnThread(entry: usize) bool {
    var stack_va: usize = 0;
    if (ferrite.allocPages(STACK_PAGES, &stack_va) != 0) return false;
    const stack_top = stack_va + STACK_PAGES * ferrite.pageSize() - 16;
    return ferrite.threadSpawn(entry, stack_top) >= 0;
}

fn bindIrq(dev: *Device) bool {
    const h = ferrite.irqCreate(dev.irq_num);
    if (h < 0) return false;
    dev.irq_handle = @intCast(h);
    const rh = ferrite.irqListen(dev.irq_handle);
    if (rh < 0) return false;
    dev.irq_recv = @intCast(rh);
    return true;
}

fn setupInterrupts() void {
    var need_poll = false;
    var i: usize = 0;
    while (i < ndev) : (i += 1) {
        const dev = &devices[i];
        if (dev.irq_num != 0 and bindIrq(dev) and spawnThread(@intFromPtr(irq_thread_entries[i]))) continue;
        dev.irq_num = 0; // no IRQ (or setup failed): poll this device instead
        need_poll = true;
    }
    if (need_poll) _ = spawnThread(@intFromPtr(&pollThread));
}

// Fallback for no-IRQ devices only; irq-driven devices are skipped.
fn pollThread() callconv(.c) noreturn {
    while (true) {
        ferrite.nanosleep(4_000_000);
        var di: usize = 0;
        while (di < ndev) : (di += 1) {
            if (devices[di].irq_num != 0) continue;
            drainAndFulfill(&devices[di]);
        }
    }
}

// --- 9P handlers ----------------------------------------------------------

fn allocFid(s: *State) ?u32 {
    var i: u32 = 1;
    while (i < MAX_FIDS) : (i += 1) {
        if (!s.fids[i].used) return i;
    }
    return null;
}

fn onWalk(s: *State, fid: u32, path: []const u8) fs.HandlerError!fs.WalkResult {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;

    var rest = path;
    while (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    while (rest.len > 0 and rest[rest.len - 1] == '/') rest = rest[0 .. rest.len - 1];

    const new_fid = allocFid(s) orelse return error.ServerBusy;

    if (rest.len == 0) {
        s.fids[new_fid] = .{ .used = true, .kind = .root };
        return .{ .bound = new_fid };
    }
    if (std.mem.eql(u8, rest, "devices")) {
        s.fids[new_fid] = .{ .used = true, .kind = .devices_file };
        return .{ .bound = new_fid };
    }
    if (std.mem.startsWith(u8, rest, "event")) {
        const idx = std.fmt.parseInt(usize, rest["event".len..], 10) catch return error.NotFound;
        if (idx >= ndev) return error.NotFound;
        s.fids[new_fid] = .{ .used = true, .kind = .event, .dev = idx };
        return .{ .bound = new_fid };
    }
    return error.NotFound;
}

fn onOpen(s: *State, fid: u32, _: p9.Mode) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    s.fids[fid].opened = true;
}

fn onClose(s: *State, fid: u32) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    if (fid != 0) s.fids[fid] = .{};
}

fn onStatus(s: *State, fid: u32) fs.HandlerError!p9.StatusReply {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    return switch (s.fids[fid].kind) {
        .root => .{ .kind = .dir, .size = 0 },
        .devices_file, .event => .{ .kind = .file, .size = 0 },
    };
}

fn onWrite(_: *State, _: u32, _: u64, _: []const u8) fs.HandlerError!u32 {
    return error.BadOp;
}

// Event streams read through onReadAsync (they block). The directory and the
// `devices` info file are finite text and answered synchronously here.
fn onRead(s: *State, fid: u32, offset: u64, out: []u8) fs.HandlerError!usize {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    var buf: [1024]u8 = undefined;
    const view = switch (s.fids[fid].kind) {
        .root => renderListing(&buf),
        .devices_file => renderDevices(&buf),
        // Non-blocking fallback: drain whatever is queued, never park here.
        .event => return drainNonBlocking(s.fids[fid].dev, out),
    };
    if (offset >= view.len) return 0;
    const start: usize = @intCast(offset);
    const n = @min(view.len - start, out.len);
    @memcpy(out[0..n], view[start..][0..n]);
    return n;
}

fn onReadAsync(s: *State, pending: fs.PendingRead) fs.HandlerError!fs.ReadOutcome {
    if (pending.fid >= MAX_FIDS) return error.BadFid;
    const f = &s.fids[pending.fid];
    if (!f.used or !f.opened) return error.BadFid;
    if (f.kind != .event) return .fall_through;

    const dev = &devices[f.dev];
    const want: usize = @min(@as(usize, pending.want), serve_resp.len);

    lockRing();
    drainHwToFifo(dev);
    if (dev.count > 0) {
        const n = popEvents(dev, serve_resp[0..want]);
        unlockRing();
        return .{ .immediate = serve_resp[0..n] };
    }
    // Single-slot: a second waiter while one is parked gets an empty read.
    if (@atomicLoad(u32, &dev.pending_cap, .acquire) != 0) {
        unlockRing();
        return .{ .immediate = "" };
    }
    dev.pending_tag = pending.tag;
    dev.pending_want = pending.want;
    @atomicStore(u32, &dev.pending_cap, pending.reply_cap, .release);

    // Re-drain to close the arrived-between-drain-and-stash race.
    drainHwToFifo(dev);
    if (dev.count > 0) {
        const n = popEvents(dev, serve_resp[0..want]);
        const claimed = @atomicRmw(u32, &dev.pending_cap, .Xchg, @as(u32, 0), .acquire);
        unlockRing();
        if (claimed != 0) {
            const pr: fs.PendingRead = .{ .reply_cap = claimed, .tag = dev.pending_tag, .fid = pending.fid, .offset = 0, .want = dev.pending_want };
            pr.respondRead(serve_resp[0..n]);
        }
        return .deferred;
    }
    unlockRing();
    return .deferred;
}

fn drainNonBlocking(di: usize, out: []u8) fs.HandlerError!usize {
    if (di >= ndev) return error.NotFound;
    const dev = &devices[di];
    lockRing();
    defer unlockRing();
    drainHwToFifo(dev);
    return popEvents(dev, out);
}

fn renderListing(buf: []u8) []const u8 {
    var fbs = std.Io.Writer.fixed(buf);
    var i: usize = 0;
    while (i < ndev) : (i += 1) fbs.print("event{d}\n", .{i}) catch break;
    fbs.print("devices\n", .{}) catch {};
    return buf[0..fbs.end];
}

fn renderDevices(buf: []u8) []const u8 {
    var fbs = std.Io.Writer.fixed(buf);
    var i: usize = 0;
    while (i < ndev) : (i += 1) {
        fbs.print("event{d}: {s}\n", .{ i, devices[i].name[0..devices[i].name_len] }) catch break;
    }
    return buf[0..fbs.end];
}

// --- PCI helpers (shared shape with the other virtio drivers) -------------

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
