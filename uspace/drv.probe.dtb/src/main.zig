const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const p9 = ferrite.p9;
const fs = ferrite.fs;
const syscall = ferrite.syscall;

const AUTHORITY = "com.midstall.ferrite.probe@v0";
const DTB_BUF_BYTES: usize = 64 * 1024;
const MAX_DEVICES = 64;
const MAX_COMPATS_PER_DEV = 4;
const COMPAT_STR_MAX = 64;

const FDT_MAGIC: u32 = 0xD00DFEED;
const FDT_BEGIN_NODE: u32 = 1;
const FDT_END_NODE: u32 = 2;
const FDT_PROP: u32 = 3;
const FDT_NOP: u32 = 4;
const FDT_END: u32 = 9;

const Device = struct {
    compats: [MAX_COMPATS_PER_DEV][COMPAT_STR_MAX]u8 = @splat(@splat(0)),
    compat_lens: [MAX_COMPATS_PER_DEV]u8 = @splat(0),
    n_compats: u8 = 0,
    info: p9.ProbeDeviceReply = .{ .phys = 0, .size = 0, .irq = 0, .has_irq = 0 },
    have_reg: bool = false,
};

var devices: [MAX_DEVICES]Device = @splat(.{});
var device_count: u32 = 0;

var dtb_buf: [DTB_BUF_BYTES]u8 = undefined;

pub fn main() void {
    const total = ferrite.dtbSize();
    if (total <= 0) {
        ferrite.console.print("[drv.probe.dtb] no DTB. Exiting\n", .{}) catch {};
        return;
    }

    const want: usize = @min(@as(usize, @intCast(total)), dtb_buf.len);
    if (!readAll(&dtb_buf, want)) {
        ferrite.console.print("[drv.probe.dtb] dtb read failed. Exiting\n", .{}) catch {};
        return;
    }

    if (!scanDtb(dtb_buf[0..want])) {
        ferrite.console.print("[drv.probe.dtb] DTB parse failed. Exiting\n", .{}) catch {};
        return;
    }

    const ch = ferrite.channelCreate(0);
    if (ch < 0) return;
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);

    fs.register(AUTHORITY, svc_send) catch |e| {
        ferrite.console.print("[drv.probe.dtb] register failed: {t}\n", .{e}) catch {};
        return;
    };

    serveLoop(svc_recv);
}

fn readAll(dst: []u8, want: usize) bool {
    var got: usize = 0;
    while (got < want) {
        const n = ferrite.dtbRead(got, dst[got..want]);
        if (n <= 0) return false;
        got += @intCast(n);
    }
    return true;
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

fn scanDtb(buf: []const u8) bool {
    if (buf.len < 40) return false;
    if (readBe32(buf[0..4]) != FDT_MAGIC) return false;
    const off_dt_struct: usize = @intCast(readBe32(buf[8..12]));
    const off_dt_strings: usize = @intCast(readBe32(buf[12..16]));
    if (off_dt_struct >= buf.len or off_dt_strings >= buf.len) return false;

    var depth: u32 = 0;
    var cursor: usize = off_dt_struct;
    var cur_dev: ?*Device = null;

    while (cursor + 4 <= buf.len) {
        const token = readBe32(buf[cursor..][0..4]);
        cursor += 4;
        switch (token) {
            FDT_BEGIN_NODE => {
                depth += 1;
                var name_end = cursor;
                while (name_end < buf.len and buf[name_end] != 0) : (name_end += 1) {}
                if (name_end >= buf.len) return false;
                cursor = alignUp(name_end + 1, 4);

                // Only direct children of root are devices.
                if (depth == 2 and device_count < MAX_DEVICES) {
                    cur_dev = &devices[device_count];
                    cur_dev.?.* = .{};
                } else {
                    cur_dev = null;
                }
            },
            FDT_END_NODE => {
                if (depth == 2 and cur_dev != null) {
                    if (cur_dev.?.have_reg and cur_dev.?.n_compats > 0) {
                        device_count += 1;
                    }
                }
                cur_dev = null;
                if (depth > 0) depth -= 1;
            },
            FDT_PROP => {
                if (cursor + 8 > buf.len) return false;
                const prop_len: usize = @intCast(readBe32(buf[cursor..][0..4]));
                const nameoff: usize = @intCast(readBe32(buf[cursor + 4 ..][0..4]));
                cursor += 8;
                if (cursor + prop_len > buf.len) return false;
                const data = buf[cursor..][0..prop_len];
                cursor = alignUp(cursor + prop_len, 4);

                if (cur_dev) |d| {
                    const name = cstrAt(buf, off_dt_strings + nameoff);
                    if (std.mem.eql(u8, name, "compatible")) {
                        absorbCompats(d, data);
                    } else if (std.mem.eql(u8, name, "reg") and data.len >= 16) {
                        d.info.phys = readBe64(data[0..8]);
                        d.info.size = readBe64(data[8..16]);
                        d.have_reg = true;
                    } else if (std.mem.eql(u8, name, "interrupts") and data.len >= 12) {
                        // GIC SPI uses type=0, PPI uses type=1.
                        const itype = readBe32(data[0..4]);
                        const inum = readBe32(data[4..8]);
                        d.info.irq = if (itype == 0) inum + 32 else inum + 16;
                        d.info.has_irq = 1;
                    }
                }
            },
            FDT_NOP => continue,
            FDT_END => return true,
            else => return false,
        }
    }
    return true;
}

fn absorbCompats(d: *Device, data: []const u8) void {
    var pos: usize = 0;
    while (pos < data.len and d.n_compats < MAX_COMPATS_PER_DEV) {
        var end = pos;
        while (end < data.len and data[end] != 0) : (end += 1) {}
        if (end > pos) {
            const s = data[pos..end];
            const copy = @min(s.len, COMPAT_STR_MAX);
            @memcpy(d.compats[d.n_compats][0..copy], s[0..copy]);
            d.compat_lens[d.n_compats] = @intCast(copy);
            d.n_compats += 1;
        }
        pos = end + 1;
    }
}

fn cstrAt(buf: []const u8, off: usize) []const u8 {
    if (off >= buf.len) return "";
    var end = off;
    while (end < buf.len and buf[end] != 0) : (end += 1) {}
    return buf[off..end];
}

inline fn alignUp(x: usize, a: usize) usize {
    return (x + a - 1) & ~(a - 1);
}

fn readBe32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

fn readBe64(b: []const u8) u64 {
    return std.mem.readInt(u64, b[0..8], .big);
}
