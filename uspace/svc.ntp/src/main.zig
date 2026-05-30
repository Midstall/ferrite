// svc.ntp: long-running SNTP client. Polls a server on a fixed interval
// and pushes the wall-clock to /sys/time/utc. Equivalent to one-shot
// `ntpdate` looped under a sleep, but as a service so init can fire-and-
// forget it. argv[1] overrides the server (default time.cloudflare.com).

const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

const NTP_PORT: u16 = 123;
const NTP_PACKET_LEN: usize = 48;
const NTP_TO_UNIX: u64 = 2_208_988_800;
const DEFAULT_SERVER = "162.159.200.1"; // time.cloudflare.com (one A record)

const REFRESH_INTERVAL_NS: u64 = 3600 * std.time.ns_per_s; // 1 hour
// Pre-sync backoff is short so the first successful poll lands within a
// second or two of DHCP completing. Once we've synced once the steady-
// state retry can be longer.
const PRESYNC_RETRY_NS: u64 = 1 * std.time.ns_per_s;
const POSTSYNC_RETRY_NS: u64 = 30 * std.time.ns_per_s;

pub fn main() void {
    const argv = ferrite.argv;
    const server: []const u8 = if (argv.len >= 2) std.mem.span(argv[1]) else DEFAULT_SERVER;

    var synced_once = false;
    while (true) {
        if (queryOnce(server)) {
            if (!synced_once) {
                ferrite.console.print("[svc.ntp] synced\n", .{}) catch {};
                synced_once = true;
            }
            ferrite.nanosleep(REFRESH_INTERVAL_NS);
        } else {
            ferrite.nanosleep(if (synced_once) POSTSYNC_RETRY_NS else PRESYNC_RETRY_NS);
        }
    }
}

/// One SNTP query + UTC push. Returns true on success.
fn queryOnce(server: []const u8) bool {
    var sock_buf: [16]u8 = undefined;
    const sock_n = openUdpClone(&sock_buf) orelse return false;

    if (!connectSocket(sock_n, server, NTP_PORT)) return false;

    var query: [NTP_PACKET_LEN]u8 = @splat(0);
    query[0] = 0x23; // LI=0, VN=4, Mode=3 (client)

    if (!writeData(sock_n, &query)) return false;

    var reply: [NTP_PACKET_LEN]u8 = undefined;
    const got = readData(sock_n, &reply) orelse return false;
    if (got < NTP_PACKET_LEN) return false;

    const tx_secs_ntp: u64 = std.mem.readInt(u32, reply[40..44], .big);
    if (tx_secs_ntp < NTP_TO_UNIX) return false;
    const unix: u64 = tx_secs_ntp - NTP_TO_UNIX;
    return pushUtc(unix);
}

fn pushUtc(unix_secs: u64) bool {
    var uri_buf: [128]u8 = undefined;
    const uri = ferrite.fs.resolvePath("/sys/time/utc", &uri_buf) catch return false;
    var f = ferrite.fs.open(uri, .{ .mode = .write }) catch return false;
    defer f.close();
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{unix_secs}) catch return false;
    _ = f.writeAll(text) catch return false;
    return true;
}

// --- UDP glue (identical to ntpdate; kept inline so this builds standalone).

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
