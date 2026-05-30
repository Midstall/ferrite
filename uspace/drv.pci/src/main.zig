const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const p9 = ferrite.p9;
const fs = ferrite.fs;

const DEV_NAME = "pci";
const ECAM_COMPATIBLE = "pci-host-ecam-generic";

const MAX_DEVICES = 64;
const MAX_FIDS = 32;
const BDF_LEN = 12; // "0000:00:01.0"
const NUM_BARS = 6;
const LEAF_NAMES: []const []const u8 = &.{
    "vendor", "device", "class", "revision", "info", "config",
    "bar0",   "bar1",   "bar2",  "bar3",     "bar4", "bar5",
    "irq",
};
const LEAF_BAR0_INDEX = 6;
const LEAF_IRQ_INDEX = LEAF_BAR0_INDEX + NUM_BARS; // 12
const CONFIG_SIZE = 256;
const INFO_BUF_MAX = 256;

const Bar = struct {
    phys: u64 = 0,
    size: u64 = 0,
    /// 0 = absent or I/O space; 1 = 32-bit mem; 2 = 64-bit mem (consumes next slot).
    kind: u8 = 0,
};

const Device = struct {
    bus: u8,
    dev: u5,
    func: u3,
    vendor: u16,
    device_id: u16,
    class: u8,
    subclass: u8,
    prog_if: u8,
    revision: u8,
    config: [CONFIG_SIZE]u8,
    bars: [NUM_BARS]Bar = @splat(.{}),
};

const FidKind = enum { root, dev_dir, leaf };

const Fid = struct {
    used: bool = false,
    opened: bool = false,
    kind: FidKind = .root,
    dev_idx: u16 = 0,
    leaf: u8 = 0,
};

const State = struct {
    fids: [MAX_FIDS]Fid = @splat(.{}),
};

var state: State = .{};
var devices: [MAX_DEVICES]Device = undefined;
var device_count: u16 = 0;
var ecam_base_va: usize = 0;
var ecam_bus_count: u16 = 0;
/// Routes config access through SYS_PCI_CFG_{READ,WRITE} instead of ECAM
/// MMIO. Set on x86 (i440fx) which has no ECAM.
var use_io_ports: bool = false;

pub fn main() void {
    var ecam_phys: u64 = 0;
    var ecam_size: u64 = 0;
    if (ferrite.probe.findDevice(ECAM_COMPATIBLE, 0)) |maybe_ecam| {
        if (maybe_ecam) |ecam| {
            ecam_phys = ecam.phys;
            ecam_size = ecam.size;
        }
    } else |_| {}
    // riscv64-limine boots without a probe service (Limine doesn't forward
    // U-Boot's DTB); fall back to hardcoded ECAM for QEMU virt machines.
    if (ecam_phys == 0) {
        ecam_phys = qemu_fallback_ecam_phys;
        ecam_size = qemu_fallback_ecam_size;
    }

    if (ecam_phys != 0) {
        const page_size: u64 = ferrite.pageSize();
        const base = ecam_phys & ~(page_size - 1);
        const span = (ecam_size + (ecam_phys - base) + page_size - 1) & ~(page_size - 1);
        const cap_h = ferrite.mmioCreate(base, @intCast(span));
        if (cap_h < 0) {
            ferrite.console.print("[drv.pci] mmioCreate failed: {d}\n", .{cap_h}) catch {};
            return;
        }
        // i386 user mmap range starts at 0x8000_0000, which is negative as
        // i32, so a plain `< 0` check rejects valid VAs. Errors are small.
        const va = ferrite.mmap(@intCast(cap_h), ferrite.PROT_READ | ferrite.PROT_WRITE);
        if (va < 0 and va > -64) {
            ferrite.console.print("[drv.pci] mmap failed: {d}\n", .{va}) catch {};
            return;
        }
        ecam_base_va = @intCast(va);
        ecam_bus_count = @intCast(ecam_size / 0x10_0000);
        if (ecam_bus_count == 0) ecam_bus_count = 1;
    } else if (@import("builtin").cpu.arch == .x86) {
        // i440fx has no ECAM; route through 0xCF8/0xCFC IO ports.
        use_io_ports = true;
        ecam_bus_count = 256;
    } else {
        ferrite.console.print("[drv.pci] no ECAM host bridge. Exiting\n", .{}) catch {};
        return;
    }

    scanBus(0);

    if (device_count == 0) {
        ferrite.console.print("[drv.pci] no devices found. Exiting\n", .{}) catch {};
        return;
    }

    // Raw + Limine boots leave BARs with phys=0; pick one from the host
    // bridge's MMIO window for each.
    assignUnsetBars();

    const ch = ferrite.channelCreate(0);
    if (ch < 0) return;
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);

    fs.registerDevice(DEV_NAME, .char, svc_send) catch |e| {
        ferrite.console.print("[drv.pci] registerDevice failed: {t}\n", .{e}) catch {};
        return;
    };

    state.fids[0] = .{ .used = true, .opened = true, .kind = .root };

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

fn cfgPtr(bus: u8, dev: u5, func: u3) [*]volatile u8 {
    const off: usize = (@as(usize, bus) << 20) | (@as(usize, dev) << 15) | (@as(usize, func) << 12);
    return @ptrFromInt(ecam_base_va + off);
}

inline fn ioBdf(bus: u8, dev: u5, func: u3) u16 {
    return (@as(u16, bus) << 8) | (@as(u16, dev) << 3) | @as(u16, func);
}

fn cfgRead16(bus: u8, dev: u5, func: u3, off: u16) u16 {
    if (use_io_ports) {
        const rc = ferrite.pciCfgRead(ioBdf(bus, dev, func), off, 2);
        return if (rc < 0) 0xFFFF else @truncate(@as(u32, @bitCast(@as(i32, @truncate(rc)))));
    }
    const p = cfgPtr(bus, dev, func);
    return @as(u16, p[off]) | (@as(u16, p[off + 1]) << 8);
}

fn cfgRead8(bus: u8, dev: u5, func: u3, off: u16) u8 {
    if (use_io_ports) {
        const rc = ferrite.pciCfgRead(ioBdf(bus, dev, func), off, 1);
        return if (rc < 0) 0xFF else @truncate(@as(u32, @bitCast(@as(i32, @truncate(rc)))));
    }
    return cfgPtr(bus, dev, func)[off];
}

fn scanBus(bus: u8) void {
    var d: u8 = 0;
    while (d < 32) : (d += 1) {
        scanDeviceSlot(bus, @intCast(d));
    }
}

fn scanDeviceSlot(bus: u8, dev: u5) void {
    if (cfgRead16(bus, dev, 0, 0x00) == 0xFFFF) return;
    captureFunction(bus, dev, 0);
    const header_type = cfgRead8(bus, dev, 0, 0x0E);
    if ((header_type & 0x80) != 0) {
        var f: u8 = 1;
        while (f < 8) : (f += 1) {
            if (cfgRead16(bus, dev, @intCast(f), 0x00) != 0xFFFF) {
                captureFunction(bus, dev, @intCast(f));
            }
        }
    }
}

fn cfgRead32(bus: u8, dev: u5, func: u3, off: u16) u32 {
    if (use_io_ports) {
        const rc = ferrite.pciCfgRead(ioBdf(bus, dev, func), off, 4);
        return if (rc < 0) 0xFFFFFFFF else @bitCast(@as(i32, @truncate(rc)));
    }
    const p = cfgPtr(bus, dev, func);
    var v: u32 = 0;
    inline for (0..4) |i| v |= @as(u32, p[off + i]) << (i * 8);
    return v;
}

fn cfgWrite32(bus: u8, dev: u5, func: u3, off: u16, v: u32) void {
    if (use_io_ports) {
        _ = ferrite.pciCfgWrite(ioBdf(bus, dev, func), off, 4, v);
        return;
    }
    const p = cfgPtr(bus, dev, func);
    inline for (0..4) |i| p[off + i] = @intCast((v >> (i * 8)) & 0xff);
}

fn captureFunction(bus: u8, dev: u5, func: u3) void {
    if (device_count >= MAX_DEVICES) return;
    const e = &devices[device_count];
    e.bus = bus;
    e.dev = dev;
    e.func = func;
    e.bars = @splat(.{});

    // IO-port mode goes one dword at a time. MMIO mode can bulk-copy.
    if (use_io_ports) {
        var i: usize = 0;
        while (i < CONFIG_SIZE) : (i += 4) {
            const v = cfgRead32(bus, dev, func, @intCast(i));
            inline for (0..4) |b| e.config[i + b] = @intCast((v >> (b * 8)) & 0xff);
        }
    } else {
        const p = cfgPtr(bus, dev, func);
        var i: usize = 0;
        while (i < CONFIG_SIZE) : (i += 1) {
            e.config[i] = p[i];
        }
    }

    e.vendor = std.mem.readInt(u16, e.config[0x00..0x02], .little);
    e.device_id = std.mem.readInt(u16, e.config[0x02..0x04], .little);
    e.revision = e.config[0x08];
    e.prog_if = e.config[0x09];
    e.subclass = e.config[0x0A];
    e.class = e.config[0x0B];

    // PCI spec: BARs must be sized with memory + IO decode off so the
    // device doesn't try to claim addresses while we're writing probe
    // values. i440fx's virtio-pci is even stricter: leaving decode on
    // makes any BAR read with bit 31 set return 0xFFFFFFFF.
    const cmd_orig = cfgRead32(bus, dev, func, 0x04);
    cfgWrite32(bus, dev, func, 0x04, cmd_orig & ~@as(u32, 0x07));

    discoverBars(bus, dev, func, &e.bars, e.config[0x0E] & 0x7F);

    cfgWrite32(bus, dev, func, 0x04, (cmd_orig & ~@as(u32, 0x07)) | 0x07);

    device_count += 1;

    // PCI-to-PCI bridge: secondary bus number at offset 0x19.
    if (e.class == 0x06 and e.subclass == 0x04) {
        const secondary = e.config[0x19];
        if (secondary != bus and secondary < ecam_bus_count) scanBus(secondary);
    }
}

/// Pool for unassigned BAR phys addresses (raw + Limine boots).
const arch_mmio_base: u64 = switch (@import("builtin").cpu.arch) {
    .aarch64 => 0x1000_0000,
    .riscv64 => 0x4000_0000,
    // i440fx rejects BAR writes with bit 31 set, so the documented PCI
    // hole at 0xC000_0000+ is unusable. Pick above RAM but under 2 GB.
    .x86 => 0x4000_0000,
    else => 0x1000_0000,
};

/// Hardcoded ECAM for arches where no probe service surfaces it.
const qemu_fallback_ecam_phys: u64 = switch (@import("builtin").cpu.arch) {
    .riscv64 => 0x3000_0000,
    .aarch64 => 0x4010_0000_0000,
    else => 0,
};
const qemu_fallback_ecam_size: u64 = switch (@import("builtin").cpu.arch) {
    .riscv64 => 0x1000_0000,
    .aarch64 => 0x1000_0000,
    else => 0,
};

fn assignUnsetBars() void {
    var next: u64 = arch_mmio_base;
    var di: u16 = 0;
    while (di < device_count) : (di += 1) {
        const d = &devices[di];
        // BAR writes need decode off; see captureFunction for why.
        const cmd_orig = cfgRead32(d.bus, d.dev, d.func, 0x04);
        cfgWrite32(d.bus, d.dev, d.func, 0x04, cmd_orig & ~@as(u32, 0x07));
        defer cfgWrite32(d.bus, d.dev, d.func, 0x04, (cmd_orig & ~@as(u32, 0x07)) | 0x07);

        var bi: usize = 0;
        while (bi < NUM_BARS) : (bi += 1) {
            const b = &d.bars[bi];
            if (b.size == 0) continue;
            if (b.phys != 0) continue;
            const aligned = (next + b.size - 1) & ~(b.size - 1);
            d.bars[bi].phys = aligned;
            const off: u16 = @intCast(0x10 + bi * 4);
            cfgWrite32(d.bus, d.dev, d.func, off, @intCast(aligned & 0xFFFF_FFFF));
            if (b.kind == 2) cfgWrite32(d.bus, d.dev, d.func, off + 4, @intCast(aligned >> 32));
            next = aligned + b.size;
        }
    }
}

/// Type 0 header: 6 BARs at 0x10. Type 1 (bridge): 2 BARs. Others: skip.
fn discoverBars(bus: u8, dev: u5, func: u3, bars: *[NUM_BARS]Bar, header_type: u8) void {
    const slot_count: usize = switch (header_type) {
        0 => 6,
        1 => 2,
        else => 0,
    };
    var i: usize = 0;
    while (i < slot_count) {
        const off: u16 = @intCast(0x10 + i * 4);
        // SeaBIOS parks BARs at 0xFFFFFFFF when it can't fit them; reset
        // both halves (in case 64-bit) to 0 before probing or the type
        // bits we read back are garbage.
        var orig_lo = cfgRead32(bus, dev, func, off);
        const next_off: u16 = off + 4;
        var orig_hi: u32 = if (i + 1 < slot_count) cfgRead32(bus, dev, func, next_off) else 0;
        if (orig_lo == 0xFFFF_FFFF) {
            cfgWrite32(bus, dev, func, off, 0);
            orig_lo = cfgRead32(bus, dev, func, off);
            if (i + 1 < slot_count and orig_hi == 0xFFFF_FFFF) {
                cfgWrite32(bus, dev, func, next_off, 0);
                orig_hi = cfgRead32(bus, dev, func, next_off);
            }
        }
        // Standard probe is `write 0xFFFFFFFF`, but i440fx virtio-pci
        // rejects bit-31-set writes (BAR reads then return 0xFFFFFFFF).
        // Probe with 0x7FFFFFFF and OR bit 31 back into the inferred
        // mask, since memory BARs always have it writable.
        cfgWrite32(bus, dev, func, off, 0x7FFF_FFFF);
        const probe_lo_raw = cfgRead32(bus, dev, func, off);
        cfgWrite32(bus, dev, func, off, orig_lo);
        const probe_lo = probe_lo_raw | 0x8000_0000;

        if (probe_lo_raw == 0 or probe_lo_raw == orig_lo) {
            i += 1;
            continue;
        }
        // Type bits are RO; orig_lo (post-reset) is authoritative, fall
        // back to probe_lo if it's still 0.
        const type_lo = if (orig_lo != 0) orig_lo else probe_lo;
        if ((type_lo & 0x1) != 0) {
            i += 1;
            continue;
        }
        const is_64 = ((type_lo & 0x6) == 0x4);
        const mask_lo = probe_lo & 0xFFFF_FFF0;

        if (mask_lo == 0) {
            i += 1;
            continue;
        }

        if (is_64 and i + 1 < slot_count) {
            cfgWrite32(bus, dev, func, next_off, 0x7FFF_FFFF);
            const probe_hi_raw = cfgRead32(bus, dev, func, next_off);
            cfgWrite32(bus, dev, func, next_off, orig_hi);
            const probe_hi = probe_hi_raw | 0x8000_0000;

            const phys = (@as(u64, orig_hi) << 32) | @as(u64, orig_lo & 0xFFFF_FFF0);
            const mask = (@as(u64, probe_hi) << 32) | @as(u64, mask_lo);
            bars[i] = .{ .phys = phys, .size = (~mask) + 1, .kind = 2 };
            i += 2;
        } else {
            const phys = @as(u64, orig_lo & 0xFFFF_FFF0);
            const size = (~@as(u64, mask_lo)) +% 1;
            bars[i] = .{ .phys = phys, .size = size & 0xFFFF_FFFF, .kind = 1 };
            i += 1;
        }
    }
}

fn writeBdf(out: *[BDF_LEN]u8, e: *const Device) void {
    _ = std.fmt.bufPrint(out, "0000:{x:0>2}:{x:0>2}.{d}", .{ e.bus, @as(u8, e.dev), @as(u8, e.func) }) catch unreachable;
}

fn findDeviceByBdf(name: []const u8) ?u16 {
    if (name.len != BDF_LEN) return null;
    var i: u16 = 0;
    while (i < device_count) : (i += 1) {
        var buf: [BDF_LEN]u8 = undefined;
        writeBdf(&buf, &devices[i]);
        if (std.mem.eql(u8, &buf, name)) return i;
    }
    return null;
}

fn findLeaf(name: []const u8) ?u8 {
    for (LEAF_NAMES, 0..) |leaf, i| {
        if (std.mem.eql(u8, leaf, name)) return @intCast(i);
    }
    return null;
}

const Resolved = union(enum) {
    root,
    dev: u16,
    leaf: struct { dev_idx: u16, leaf: u8 },
};

fn resolve(path: []const u8) ?Resolved {
    var p = path;
    while (p.len > 0 and p[0] == '/') p = p[1..];
    while (p.len > 0 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    if (p.len == 0) return .root;

    if (std.mem.indexOfScalar(u8, p, '/')) |slash| {
        const bdf = p[0..slash];
        const rest = p[slash + 1 ..];
        const dev_idx = findDeviceByBdf(bdf) orelse return null;
        const leaf = findLeaf(rest) orelse return null;
        return .{ .leaf = .{ .dev_idx = dev_idx, .leaf = leaf } };
    }
    const dev_idx = findDeviceByBdf(p) orelse return null;
    return .{ .dev = dev_idx };
}

fn allocFid(s: *State) ?u32 {
    var i: u32 = 1;
    while (i < MAX_FIDS) : (i += 1) {
        if (!s.fids[i].used) return i;
    }
    return null;
}

fn fidPath(s: *State, fid: u32, out: *[BDF_LEN + 1 + 16]u8) []const u8 {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return out[0..0];
    switch (s.fids[fid].kind) {
        .root => return out[0..0],
        .dev_dir => {
            writeBdf(out[0..BDF_LEN], &devices[s.fids[fid].dev_idx]);
            return out[0..BDF_LEN];
        },
        .leaf => {
            writeBdf(out[0..BDF_LEN], &devices[s.fids[fid].dev_idx]);
            out[BDF_LEN] = '/';
            const leaf = LEAF_NAMES[s.fids[fid].leaf];
            @memcpy(out[BDF_LEN + 1 ..][0..leaf.len], leaf);
            return out[0 .. BDF_LEN + 1 + leaf.len];
        },
    }
}

fn onWalk(s: *State, fid: u32, path: []const u8) fs.HandlerError!fs.WalkResult {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;

    var base_buf: [BDF_LEN + 1 + 16]u8 = undefined;
    const base = fidPath(s, fid, &base_buf);

    var full_buf: [BDF_LEN + 1 + 16 + 1 + 16]u8 = undefined;
    var n: usize = 0;
    @memcpy(full_buf[0..base.len], base);
    n = base.len;
    if (path.len > 0) {
        if (n > 0) {
            full_buf[n] = '/';
            n += 1;
        }
        if (n + path.len > full_buf.len) return error.NotFound;
        @memcpy(full_buf[n..][0..path.len], path);
        n += path.len;
    }

    const r = resolve(full_buf[0..n]) orelse return error.NotFound;

    const new_fid = allocFid(s) orelse return error.ServerBusy;
    switch (r) {
        .root => s.fids[new_fid] = .{ .used = true, .kind = .root },
        .dev => |i| s.fids[new_fid] = .{ .used = true, .kind = .dev_dir, .dev_idx = i },
        .leaf => |l| s.fids[new_fid] = .{ .used = true, .kind = .leaf, .dev_idx = l.dev_idx, .leaf = l.leaf },
    }
    return .{ .bound = new_fid };
}

fn onOpen(s: *State, fid: u32, _: p9.Mode) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    s.fids[fid].opened = true;
}

fn onRead(s: *State, fid: u32, offset: u64, out: []u8) fs.HandlerError!usize {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    return switch (s.fids[fid].kind) {
        .root => listRoot(offset, out),
        .dev_dir => listDevDir(offset, out),
        .leaf => readLeaf(s.fids[fid].dev_idx, s.fids[fid].leaf, offset, out),
    };
}

fn listRoot(offset: u64, out: []u8) fs.HandlerError!usize {
    var listing: [MAX_DEVICES * (BDF_LEN + 1)]u8 = undefined;
    var w: usize = 0;
    var i: u16 = 0;
    while (i < device_count) : (i += 1) {
        var bdf: [BDF_LEN]u8 = undefined;
        writeBdf(&bdf, &devices[i]);
        @memcpy(listing[w..][0..BDF_LEN], &bdf);
        w += BDF_LEN;
        listing[w] = '\n';
        w += 1;
    }
    if (offset >= w) return 0;
    const start: usize = @intCast(offset);
    const n = @min(w - start, out.len);
    @memcpy(out[0..n], listing[start..][0..n]);
    return n;
}

fn listDevDir(offset: u64, out: []u8) fs.HandlerError!usize {
    var listing: [256]u8 = undefined;
    var w: usize = 0;
    for (LEAF_NAMES) |leaf| {
        @memcpy(listing[w..][0..leaf.len], leaf);
        w += leaf.len;
        listing[w] = '\n';
        w += 1;
    }
    if (offset >= w) return 0;
    const start: usize = @intCast(offset);
    const n = @min(w - start, out.len);
    @memcpy(out[0..n], listing[start..][0..n]);
    return n;
}

fn readLeaf(dev_idx: u16, leaf: u8, offset: u64, out: []u8) fs.HandlerError!usize {
    var buf: [INFO_BUF_MAX]u8 = undefined;
    const view: []const u8 = switch (leaf) {
        0 => std.fmt.bufPrint(&buf, "{x:0>4}\n", .{devices[dev_idx].vendor}) catch return error.BadOp,
        1 => std.fmt.bufPrint(&buf, "{x:0>4}\n", .{devices[dev_idx].device_id}) catch return error.BadOp,
        2 => std.fmt.bufPrint(&buf, "{x:0>2}{x:0>2}{x:0>2}\n", .{ devices[dev_idx].class, devices[dev_idx].subclass, devices[dev_idx].prog_if }) catch return error.BadOp,
        3 => std.fmt.bufPrint(&buf, "{x:0>2}\n", .{devices[dev_idx].revision}) catch return error.BadOp,
        4 => infoText(&buf, &devices[dev_idx]),
        5 => {
            if (offset >= CONFIG_SIZE) return 0;
            const start: usize = @intCast(offset);
            const n = @min(CONFIG_SIZE - start, out.len);
            @memcpy(out[0..n], devices[dev_idx].config[start..][0..n]);
            return n;
        },
        LEAF_BAR0_INDEX...LEAF_BAR0_INDEX + NUM_BARS - 1 => barText(&buf, &devices[dev_idx].bars[leaf - LEAF_BAR0_INDEX]),
        LEAF_IRQ_INDEX => irqText(&buf, &devices[dev_idx]),
        else => return error.BadOp,
    };
    if (offset >= view.len) return 0;
    const start: usize = @intCast(offset);
    const n = @min(view.len - start, out.len);
    @memcpy(out[0..n], view[start..][0..n]);
    return n;
}

fn barText(buf: *[INFO_BUF_MAX]u8, b: *const Bar) []const u8 {
    if (b.kind == 0) return buf[0..0];
    return std.fmt.bufPrint(buf, "phys=0x{x} size=0x{x}\n", .{ b.phys, b.size }) catch buf[0..0];
}

// The GIC INTID a legacy-INTx interrupt from this device lands on. aarch64
// qemu-virt only: its PCIe interrupt-map routes the 4 INTx pins to GIC SPI 3..6
// (INTID 35..38), level-triggered, swizzled by device slot:
//   INTID = 32 + 3 + ((slot + pin - 1) mod 4)
// Verified against the machine DTB interrupt-map (mask 0x1800,0,0,7). Other
// arches (IOAPIC/MSI, PLIC) report "none" for now so their drivers keep polling.
fn irqText(buf: *[INFO_BUF_MAX]u8, e: *const Device) []const u8 {
    const pin = e.config[0x3D]; // 0 = no INTx, 1 = INTA .. 4 = INTD
    if (pin == 0 or pin > 4 or @import("builtin").cpu.arch != .aarch64) {
        return std.fmt.bufPrint(buf, "none\n", .{}) catch buf[0..0];
    }
    const intid: u32 = 35 + ((@as(u32, e.dev) + pin - 1) % 4);
    return std.fmt.bufPrint(buf, "{d}\n", .{intid}) catch buf[0..0];
}

fn infoText(buf: *[INFO_BUF_MAX]u8, e: *const Device) []const u8 {
    return std.fmt.bufPrint(buf, "vendor={x:0>4} device={x:0>4} class={x:0>2}{x:0>2}{x:0>2} rev={x:0>2}\n", .{
        e.vendor, e.device_id, e.class, e.subclass, e.prog_if, e.revision,
    }) catch buf[0..0];
}

fn onWrite(_: *State, _: u32, _: u64, _: []const u8) fs.HandlerError!u32 {
    return error.BadOp;
}

fn onClose(s: *State, fid: u32) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    if (fid != 0) s.fids[fid] = .{};
}

fn onStatus(s: *State, fid: u32) fs.HandlerError!p9.StatusReply {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    return switch (s.fids[fid].kind) {
        .root, .dev_dir => .{ .kind = .dir, .size = 0 },
        .leaf => .{ .kind = .file, .size = if (s.fids[fid].leaf == 5) CONFIG_SIZE else 0 },
    };
}
