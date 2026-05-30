// nslookup <hostname> [A|AAAA]: UDP query to /etc/resolv.conf's first NS.

const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

const DNS_HDR_LEN: usize = 12;
const QTYPE_A: u16 = 1;
const QTYPE_AAAA: u16 = 28;
const QCLASS_IN: u16 = 1;
const FLAG_RD: u16 = 0x0100;

pub fn main() void {
    const argv = ferrite.argv;
    if (argv.len < 2) {
        ferrite.console.print("usage: nslookup <hostname> [A|AAAA]\n", .{}) catch {};
        return;
    }
    const name = std.mem.span(argv[1]);
    const qtype: u16 = if (argv.len >= 3 and std.mem.eql(u8, std.mem.span(argv[2]), "AAAA")) QTYPE_AAAA else QTYPE_A;

    var ns_buf: [128]u8 = undefined;
    const ns = firstNameserver(&ns_buf) orelse {
        ferrite.console.print("nslookup: no nameserver in /etc/resolv.conf\n", .{}) catch {};
        return;
    };
    ferrite.console.print("server: {s}\n", .{ns}) catch {};

    var sock_buf: [16]u8 = undefined;
    const sock_n = openUdpClone(&sock_buf) orelse {
        ferrite.console.print("nslookup: failed to open UDP socket\n", .{}) catch {};
        return;
    };
    defer closeSocket(sock_n);

    if (!connectSocket(sock_n, ns, 53)) {
        ferrite.console.print("nslookup: connect failed\n", .{}) catch {};
        return;
    }

    var query: [512]u8 = undefined;
    const q_len = buildQuery(&query, name, qtype) orelse {
        ferrite.console.print("nslookup: name too long\n", .{}) catch {};
        return;
    };

    if (!writeData(sock_n, query[0..q_len])) {
        ferrite.console.print("nslookup: write failed (ARP/NDP unresolved or send error)\n", .{}) catch {};
        return;
    }

    var resp: [1500]u8 = undefined;
    const got = readData(sock_n, &resp) orelse {
        ferrite.console.print("nslookup: no reply (timeout)\n", .{}) catch {};
        return;
    };

    parseAndPrint(resp[0..got], qtype);
}

fn firstNameserver(out: []u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    const n = ferrite.readInitrdFile("etc/resolv.conf", &buf);
    if (n == 0) return null;
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |raw| {
        const line = stripComment(raw);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var tok = std.mem.tokenizeAny(u8, trimmed, " \t");
        const kw = tok.next() orelse continue;
        if (!std.mem.eql(u8, kw, "nameserver")) continue;
        const ip = tok.next() orelse continue;
        if (ip.len > out.len) return null;
        @memcpy(out[0..ip.len], ip);
        return out[0..ip.len];
    }
    return null;
}

fn stripComment(line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, '#')) |i| return line[0..i];
    return line;
}

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

fn closeSocket(_: []const u8) void {
    // svc.net cleans up on clone-fid drop.
}

fn connectSocket(sock_n: []const u8, ns: []const u8, port: u16) bool {
    var path: [128]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/sys/net/udp/{s}/ctl", .{sock_n}) catch return false;
    var uri_buf: [128]u8 = undefined;
    const uri = ferrite.fs.resolvePath(p, &uri_buf) catch return false;
    var f = ferrite.fs.open(uri, .{ .mode = .write }) catch return false;
    defer f.close();
    var cmd: [128]u8 = undefined;
    const c = std.fmt.bufPrint(&cmd, "connect {s}!{d}", .{ ns, port }) catch return false;
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

fn buildQuery(out: []u8, name: []const u8, qtype: u16) ?usize {
    if (out.len < DNS_HDR_LEN) return null;
    // Header: id=0x1234, flags=RD, qdcount=1.
    out[0] = 0x12;
    out[1] = 0x34;
    out[2] = @intCast((FLAG_RD >> 8) & 0xff);
    out[3] = @intCast(FLAG_RD & 0xff);
    out[4] = 0;
    out[5] = 1;
    out[6] = 0;
    out[7] = 0;
    out[8] = 0;
    out[9] = 0;
    out[10] = 0;
    out[11] = 0;

    var w: usize = DNS_HDR_LEN;
    // Name: <len><label>...<0>.
    var rest = name;
    while (rest.len > 0) {
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
        const label = rest[0..dot];
        if (label.len > 63 or label.len == 0) return null;
        if (w + 1 + label.len > out.len) return null;
        out[w] = @intCast(label.len);
        w += 1;
        @memcpy(out[w..][0..label.len], label);
        w += label.len;
        rest = if (dot == rest.len) "" else rest[dot + 1 ..];
    }
    if (w + 5 > out.len) return null;
    out[w] = 0;
    w += 1;
    out[w] = @intCast((qtype >> 8) & 0xff);
    out[w + 1] = @intCast(qtype & 0xff);
    out[w + 2] = @intCast((QCLASS_IN >> 8) & 0xff);
    out[w + 3] = @intCast(QCLASS_IN & 0xff);
    w += 4;
    return w;
}

fn parseAndPrint(resp: []const u8, qtype: u16) void {
    if (resp.len < DNS_HDR_LEN) {
        ferrite.console.print("nslookup: short response\n", .{}) catch {};
        return;
    }
    const rcode = resp[3] & 0x0F;
    if (rcode != 0) {
        ferrite.console.print("nslookup: rcode={d}\n", .{rcode}) catch {};
        return;
    }
    const qdcount = (@as(u16, resp[4]) << 8) | resp[5];
    const ancount = (@as(u16, resp[6]) << 8) | resp[7];

    var off: usize = DNS_HDR_LEN;
    var i: u16 = 0;
    while (i < qdcount) : (i += 1) {
        off = skipName(resp, off) orelse return;
        off += 4;
    }

    var printed: u32 = 0;
    i = 0;
    while (i < ancount and off + 10 <= resp.len) : (i += 1) {
        off = skipName(resp, off) orelse return;
        if (off + 10 > resp.len) return;
        const atype = (@as(u16, resp[off]) << 8) | resp[off + 1];
        const rdlen: usize = (@as(usize, resp[off + 8]) << 8) | resp[off + 9];
        off += 10;
        if (off + rdlen > resp.len) return;

        if (atype == qtype) {
            if (atype == QTYPE_A and rdlen == 4) {
                const a = resp[off .. off + 4];
                ferrite.console.print("{d}.{d}.{d}.{d}\n", .{ a[0], a[1], a[2], a[3] }) catch {};
                printed += 1;
            } else if (atype == QTYPE_AAAA and rdlen == 16) {
                var bytes: [16]u8 = undefined;
                @memcpy(&bytes, resp[off .. off + 16]);
                const u: std.Io.net.Ip6Address.Unresolved = .{ .bytes = bytes, .interface_name = null };
                ferrite.console.print("{f}\n", .{&u}) catch {};
                printed += 1;
            }
        }
        off += rdlen;
    }

    if (printed == 0) {
        ferrite.console.print("nslookup: no answers\n", .{}) catch {};
    }
}

fn skipName(buf: []const u8, start: usize) ?usize {
    var off = start;
    while (off < buf.len) {
        const b = buf[off];
        if (b == 0) return off + 1;
        if ((b & 0xC0) == 0xC0) {
            // DNS compression pointer (2 bytes).
            if (off + 1 >= buf.len) return null;
            return off + 2;
        }
        if (b > 63) return null;
        off += 1 + b;
    }
    return null;
}
