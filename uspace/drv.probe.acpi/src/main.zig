const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const p9 = ferrite.p9;
const fs = ferrite.fs;

const AUTHORITY = "com.midstall.ferrite.probe@v0";
const ACPI_BUF_BYTES: usize = 64 * 1024;
const MAX_DEVICES = 64;
const MAX_COMPATS_PER_DEV = 2;
const COMPAT_STR_MAX = 32;

const SDT_HEADER = 36;

const Device = struct {
    compats: [MAX_COMPATS_PER_DEV][COMPAT_STR_MAX]u8 = @splat(@splat(0)),
    compat_lens: [MAX_COMPATS_PER_DEV]u8 = @splat(0),
    n_compats: u8 = 0,
    info: p9.ProbeDeviceReply = .{ .phys = 0, .size = 0, .irq = 0, .has_irq = 0 },
};

var devices: [MAX_DEVICES]Device = @splat(.{});
var device_count: u32 = 0;

var acpi_buf: [ACPI_BUF_BYTES]u8 = undefined;

pub fn main() void {
    const total = ferrite.acpiSize();
    if (total <= 0) {
        ferrite.console.print("[drv.probe.acpi] no ACPI tables. Exiting\n", .{}) catch {};
        return;
    }

    const want: usize = @min(@as(usize, @intCast(total)), acpi_buf.len);
    if (!readAll(&acpi_buf, want)) {
        ferrite.console.print("[drv.probe.acpi] acpi read failed. Exiting\n", .{}) catch {};
        return;
    }

    parseAll(acpi_buf[0..want]);

    if (device_count == 0) {
        ferrite.console.print("[drv.probe.acpi] no probe-able devices found. Exiting\n", .{}) catch {};
        return;
    }

    const ch = ferrite.channelCreate(0);
    if (ch < 0) return;
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);

    fs.register(AUTHORITY, svc_send) catch |e| {
        ferrite.console.print("[drv.probe.acpi] register failed: {t}\n", .{e}) catch {};
        return;
    };

    serveLoop(svc_recv);
}

fn readAll(dst: []u8, want: usize) bool {
    var got: usize = 0;
    while (got < want) {
        const n = ferrite.acpiRead(got, dst[got..want]);
        if (n <= 0) return false;
        got += @intCast(n);
    }
    return true;
}

// Kernel packs tables as [sig:4][len:u32 LE][bytes:len].
fn parseAll(buf: []const u8) void {
    var off: usize = 0;
    while (off + 8 <= buf.len) {
        const sig = buf[off..][0..4].*;
        const rec_len: usize = @intCast(readLe32(buf[off + 4 ..][0..4]));
        if (off + 8 + rec_len > buf.len) return;
        const body = buf[off + 8 ..][0..rec_len];

        if (std.mem.eql(u8, &sig, "APIC")) {
            parseMadt(body);
        } else if (std.mem.eql(u8, &sig, "MCFG")) {
            parseMcfg(body);
        } else if (std.mem.eql(u8, &sig, "SPCR")) {
            parseSpcr(body);
        } else if (std.mem.eql(u8, &sig, "GTDT")) {
            parseGtdt(body);
        }

        off += 8 + rec_len;
    }
}

fn parseMadt(body: []const u8) void {
    if (body.len < 44) return;
    var p: usize = 44;
    var gic_version: u8 = 0;
    var gicd_phys: u64 = 0;
    var gicr_phys: u64 = 0;
    var gicr_size: u64 = 0;

    while (p + 2 <= body.len) {
        const ic_type = body[p];
        const ic_len = body[p + 1];
        if (ic_len < 2 or p + ic_len > body.len) return;
        const ic = body[p..][0..ic_len];

        switch (ic_type) {
            // GICC
            0x0B => if (ic.len >= 80) {
                gic_version = ic[78];
            },
            // GICD
            0x0C => if (ic.len >= 24) {
                gicd_phys = readLe64(ic[8..16]);
                const v = ic[20];
                if (v != 0) gic_version = v;
            },
            // GICR
            0x0E => if (ic.len >= 16) {
                gicr_phys = readLe64(ic[4..12]);
                gicr_size = @as(u64, readLe32(ic[12..16]));
            },
            else => {},
        }
        p += ic_len;
    }

    if (gicd_phys != 0) {
        var d = pushDevice() orelse return;
        const compat = switch (gic_version) {
            2 => "arm,gic-v2",
            3, 4 => "arm,gic-v3",
            else => "arm,gic-v3",
        };
        addCompat(d, compat);
        d.info.phys = gicd_phys;
        // 64 KiB covers both GICv2 (4 KiB) and GICv3 (64 KiB) distributors.
        d.info.size = 0x1_0000;
    }
    if (gicr_phys != 0) {
        var d = pushDevice() orelse return;
        addCompat(d, "arm,gic-v3-redist");
        d.info.phys = gicr_phys;
        d.info.size = gicr_size;
    }
}

fn parseMcfg(body: []const u8) void {
    if (body.len < 44) return;
    var p: usize = 44;
    while (p + 16 <= body.len) {
        const base = readLe64(body[p..][0..8]);
        const start_bus = body[p + 10];
        const end_bus = body[p + 11];
        const bus_count: u64 = @as(u64, end_bus) - @as(u64, start_bus) + 1;

        var d = pushDevice() orelse return;
        addCompat(d, "pci-host-ecam-generic");
        d.info.phys = base;
        d.info.size = bus_count * 0x10_0000;

        p += 16;
    }
}

fn parseSpcr(body: []const u8) void {
    if (body.len < 58) return;
    const iface = body[36];
    const gas_addr = readLe64(body[44..52]);
    const irq_type = body[52];
    const gsi = readLe32(body[54..58]);
    if (gas_addr == 0) return;

    var d = pushDevice() orelse return;
    const compat: []const u8 = switch (iface) {
        0x03, 0x0E => "arm,pl011",
        0x12 => "ns16550",
        else => "arm,pl011",
    };
    addCompat(d, compat);
    d.info.phys = gas_addr;
    d.info.size = 0x1000;
    if (irq_type != 0 and gsi != 0) {
        d.info.irq = gsi;
        d.info.has_irq = 1;
    }
}

// armv8 timer uses system regs; emit a record so services find it by compat.
fn parseGtdt(body: []const u8) void {
    if (body.len < 64) return;
    var d = pushDevice() orelse return;
    addCompat(d, "arm,armv8-timer");
    d.info.phys = 0;
    d.info.size = 0;
    const ns_el1 = readLe32(body[48..52]);
    if (ns_el1 != 0) {
        d.info.irq = ns_el1;
        d.info.has_irq = 1;
    }
}

fn pushDevice() ?*Device {
    if (device_count >= MAX_DEVICES) return null;
    const d = &devices[device_count];
    d.* = .{};
    device_count += 1;
    return d;
}

fn addCompat(d: *Device, s: []const u8) void {
    if (d.n_compats >= MAX_COMPATS_PER_DEV) return;
    const n = @min(s.len, COMPAT_STR_MAX);
    @memcpy(d.compats[d.n_compats][0..n], s[0..n]);
    d.compat_lens[d.n_compats] = @intCast(n);
    d.n_compats += 1;
}

fn serveLoop(svc_recv: u32) void {
    var req_buf: [p9.MAX_MSG]u8 = undefined;
    var resp_buf: [p9.MAX_MSG]u8 = undefined;

    while (true) {
        var reply_cap: u32 = 0;
        const n = ferrite.recv(svc_recv, &req_buf, &reply_cap);
        if (n < 0) return;
        if (reply_cap == 0) continue;
        defer _ = ferrite.capRelease(reply_cap);

        const decoded = p9.decodeRequest(req_buf[0..@intCast(n)]) catch {
            const elen = p9.encodeErrReply(&resp_buf, 0, .bad_op) catch continue;
            _ = ferrite.send(reply_cap, resp_buf[0..elen], 0);
            continue;
        };
        const tag = decoded.hdr.tag;

        switch (decoded.req) {
            .probe_device => |m| {
                if (lookupDevice(m.compat, m.index)) |info| {
                    const rlen = p9.encodeProbeDeviceReply(&resp_buf, tag, info) catch continue;
                    _ = ferrite.send(reply_cap, resp_buf[0..rlen], 0);
                } else {
                    const elen = p9.encodeErrReply(&resp_buf, tag, .not_found) catch continue;
                    _ = ferrite.send(reply_cap, resp_buf[0..elen], 0);
                }
            },
            else => {
                const elen = p9.encodeErrReply(&resp_buf, tag, .bad_op) catch continue;
                _ = ferrite.send(reply_cap, resp_buf[0..elen], 0);
            },
        }
    }
}

fn lookupDevice(compat: []const u8, index: u32) ?p9.ProbeDeviceReply {
    var found: u32 = 0;
    var i: u32 = 0;
    while (i < device_count) : (i += 1) {
        const d = &devices[i];
        var j: u8 = 0;
        while (j < d.n_compats) : (j += 1) {
            const c = d.compats[j][0..d.compat_lens[j]];
            if (std.mem.eql(u8, c, compat)) {
                if (found == index) return d.info;
                found += 1;
                break;
            }
        }
    }
    return null;
}

fn readLe32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}

fn readLe64(b: []const u8) u64 {
    return std.mem.readInt(u64, b[0..8], .little);
}
