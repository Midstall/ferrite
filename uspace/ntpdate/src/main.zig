// ntpdate [server]: SNTP query that pushes wall-clock to /sys/time/utc.

const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

const NTP_PORT: u16 = 123;
const NTP_PACKET_LEN: usize = 48;
const NTP_TO_UNIX: u64 = 2_208_988_800; // seconds between 1900-01-01 and 1970-01-01
const DEFAULT_SERVER = "162.159.200.1"; // time.cloudflare.com (one A record)

pub fn main() void {
    const argv = ferrite.argv;
    const server: []const u8 = if (argv.len >= 2) std.mem.span(argv[1]) else DEFAULT_SERVER;

    var sock_buf: [16]u8 = undefined;
    const sock_n = openUdpClone(&sock_buf) orelse {
        ferrite.console.print("ntpdate: open clone failed\n", .{}) catch {};
        return;
    };

    if (!connectSocket(sock_n, server, NTP_PORT)) {
        ferrite.console.print("ntpdate: connect failed\n", .{}) catch {};
        return;
    }

    var query: [NTP_PACKET_LEN]u8 = @splat(0);
    query[0] = 0x23; // LI=0, VN=4, Mode=3 (client)

    if (!writeData(sock_n, &query)) {
        ferrite.console.print("ntpdate: write failed\n", .{}) catch {};
        return;
    }

    var reply: [NTP_PACKET_LEN]u8 = undefined;
    const got = readData(sock_n, &reply) orelse {
        ferrite.console.print("ntpdate: no reply\n", .{}) catch {};
        return;
    };
    if (got < NTP_PACKET_LEN) {
        ferrite.console.print("ntpdate: short reply ({d} bytes)\n", .{got}) catch {};
        return;
    }

    // SNTP transmit timestamp: offset 40, BE seconds + fraction.
    const tx_secs_ntp: u64 = std.mem.readInt(u32, reply[40..44], .big);
    const tx_frac: u64 = std.mem.readInt(u32, reply[44..48], .big);
    if (tx_secs_ntp < NTP_TO_UNIX) {
        ferrite.console.print("ntpdate: bad timestamp\n", .{}) catch {};
        return;
    }
    const unix: u64 = tx_secs_ntp - NTP_TO_UNIX;
    const ms: u64 = (tx_frac * 1000) >> 32;
    printUtc(unix, ms);
    pushUtc(unix);
}

fn pushUtc(unix_secs: u64) void {
    var uri_buf: [128]u8 = undefined;
    const uri = ferrite.fs.resolvePath("/sys/time/utc", &uri_buf) catch return;
    var f = ferrite.fs.open(uri, .{ .mode = .write }) catch return;
    defer f.close();
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{unix_secs}) catch return;
    _ = f.writeAll(text) catch {};
}

fn printUtc(unix_secs: u64, ms: u64) void {
    const date = civilFromDays(unix_secs / 86_400);
    const sod = unix_secs % 86_400;
    const h: u32 = @intCast(sod / 3600);
    const m: u32 = @intCast((sod % 3600) / 60);
    const s: u32 = @intCast(sod % 60);
    ferrite.console.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} UTC\n", .{
        date.year, date.month, date.day, h, m, s, ms,
    }) catch {};
}

const Civil = struct { year: u32, month: u32, day: u32 };

/// Howard Hinnant's days_from_civil inverse; input is Unix-epoch days.
fn civilFromDays(unix_days: u64) Civil {
    const z: i64 = @intCast(unix_days);
    // Shift to 0000-03-01 so leap days fall at year end.
    const era_anchor: i64 = z + 719_468;
    const era: i64 = if (era_anchor >= 0) @divFloor(era_anchor, 146_097) else @divFloor(era_anchor - 146_096, 146_097);
    const doe: u64 = @intCast(era_anchor - era * 146_097);
    const yoe: u64 = (doe -% (doe / 1460) +% (doe / 36_524) -% (doe / 146_096)) / 365;
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const d: u64 = doy - (153 * mp + 2) / 5 + 1;
    const m: u64 = if (mp < 10) mp + 3 else mp - 9;
    const year: i64 = if (m <= 2) y + 1 else y;
    return .{
        .year = @intCast(year),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

// UDP glue.

fn openUdpClone(out: []u8) ?[]const u8 {
    var uri_buf: [128]u8 = undefined;
    const uri = ferrite.fs.resolvePath("/sys/net/udp/clone", &uri_buf) catch return null;
    var f = ferrite.fs.open(uri, .{ .mode = .rdwr }) catch return null;
    defer f.close();
    var got: usize = 0;
    while (got < out.len) {
        const n = f.read(got, out[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    const view = std.mem.trim(u8, out[0..got], " \t\r\n");
    if (view.len == 0) return null;
    if (view.ptr != out.ptr) @memmove(out[0..view.len], view);
    return out[0..view.len];
}

fn connectSocket(sock_n: []const u8, host: []const u8, port: u16) bool {
    var path: [128]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/sys/net/udp/{s}/ctl", .{sock_n}) catch return false;
    var uri_buf: [128]u8 = undefined;
    const uri = ferrite.fs.resolvePath(p, &uri_buf) catch return false;
    var f = ferrite.fs.open(uri, .{ .mode = .write }) catch return false;
    defer f.close();
    var cmd: [128]u8 = undefined;
    const c = std.fmt.bufPrint(&cmd, "connect {s}!{d}", .{ host, port }) catch return false;
    _ = f.writeAll(c) catch return false;
    return true;
}

fn writeData(sock_n: []const u8, data: []const u8) bool {
    var path: [128]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/sys/net/udp/{s}/data", .{sock_n}) catch return false;
    var uri_buf: [128]u8 = undefined;
    const uri = ferrite.fs.resolvePath(p, &uri_buf) catch return false;
    var f = ferrite.fs.open(uri, .{ .mode = .write }) catch return false;
    defer f.close();
    _ = f.writeAll(data) catch return false;
    return true;
}

fn readData(sock_n: []const u8, out: []u8) ?usize {
    var path: [128]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/sys/net/udp/{s}/data", .{sock_n}) catch return null;
    var uri_buf: [128]u8 = undefined;
    const uri = ferrite.fs.resolvePath(p, &uri_buf) catch return null;
    var f = ferrite.fs.open(uri, .{ .mode = .read }) catch return null;
    defer f.close();
    const n = f.read(0, out) catch return null;
    if (n == 0) return null;
    return n;
}
