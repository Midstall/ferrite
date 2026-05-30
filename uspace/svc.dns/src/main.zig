const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const p9 = ferrite.p9;
const fs = ferrite.fs;

const URI_PREFIX = "com.midstall.ferrite.dns@v0";
const MOUNT_PREFIX = "/sys/dns";

const MAX_FIDS = 16;
const NAME_MAX = 255;
const ANSWER_MAX = 512;

const DNS_HDR_LEN: usize = 12;
const QTYPE_A: u16 = 1;
const QTYPE_AAAA: u16 = 28;
const QCLASS_IN: u16 = 1;
const FLAG_RD: u16 = 0x0100;

const Kind = enum { root, query };

const Fid = struct {
    used: bool = false,
    opened: bool = false,
    kind: Kind = .root,
    qtype: u16 = QTYPE_A,
    name_len: u16 = 0,
    name: [NAME_MAX]u8 = @splat(0),
    answer_len: u16 = 0,
    answer: [ANSWER_MAX]u8 = @splat(0),
    resolved: bool = false,
};

const State = struct {
    fids: [MAX_FIDS]Fid = @splat(.{}),
};

var state: State = .{};

pub fn main() void {
    const ch = ferrite.channelCreate(0);
    if (ch < 0) return;
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);

    fs.register(URI_PREFIX, svc_send) catch |e| {
        ferrite.console.print("[svc.dns] register failed: {t}\n", .{e}) catch {};
        return;
    };
    fs.mount(MOUNT_PREFIX, URI_PREFIX) catch |e| switch (e) {
        error.Permission => {},
        else => {
            ferrite.console.print("[svc.dns] mount({s}) failed: {t}\n", .{ MOUNT_PREFIX, e }) catch {};
            return;
        },
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

fn onWalk(s: *State, fid: u32, path: []const u8) fs.HandlerError!fs.WalkResult {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;

    var trimmed = path;
    while (trimmed.len > 0 and trimmed[0] == '/') trimmed = trimmed[1..];

    var qtype: u16 = QTYPE_A;
    var name: []const u8 = trimmed;

    if (std.mem.endsWith(u8, name, ".6")) {
        qtype = QTYPE_AAAA;
        name = name[0 .. name.len - 2];
    }

    if (name.len == 0) {
        var i: u32 = 1;
        while (i < MAX_FIDS) : (i += 1) {
            if (!s.fids[i].used) {
                s.fids[i] = .{ .used = true, .kind = .root };
                return .{ .bound = i };
            }
        }
        return error.ServerBusy;
    }

    if (name.len > NAME_MAX) return error.NotFound;

    var i: u32 = 1;
    while (i < MAX_FIDS) : (i += 1) {
        if (!s.fids[i].used) {
            s.fids[i] = .{
                .used = true,
                .kind = .query,
                .qtype = qtype,
                .name_len = @intCast(name.len),
            };
            @memcpy(s.fids[i].name[0..name.len], name);
            return .{ .bound = i };
        }
    }
    return error.ServerBusy;
}

fn onOpen(s: *State, fid: u32, _: p9.Mode) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    s.fids[fid].opened = true;
    s.fids[fid].resolved = false;
    s.fids[fid].answer_len = 0;
}

fn onRead(s: *State, fid: u32, offset: u64, out: []u8) fs.HandlerError!usize {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    const f = &s.fids[fid];
    if (f.kind == .root) {
        const listing = "use: walk /sys/dns/<host>[.6] then read\n";
        if (offset >= listing.len) return 0;
        const start: usize = @intCast(offset);
        const n = @min(listing.len - start, out.len);
        @memcpy(out[0..n], listing[start..][0..n]);
        return n;
    }

    if (!f.resolved) {
        resolveQuery(f);
        f.resolved = true;
    }

    if (offset >= f.answer_len) return 0;
    const start: usize = @intCast(offset);
    const n = @min(@as(usize, f.answer_len) - start, out.len);
    @memcpy(out[0..n], f.answer[start..][0..n]);
    return n;
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
        .root => .{ .kind = .dir, .size = 0 },
        .query => .{ .kind = .file, .size = 0 },
    };
}

fn resolveQuery(f: *Fid) void {
    var ns_buf: [64]u8 = undefined;
    const ns = pickNameserver(&ns_buf) orelse {
        const msg = "no nameserver configured\n";
        @memcpy(f.answer[0..msg.len], msg);
        f.answer_len = msg.len;
        return;
    };

    var sock_buf: [16]u8 = undefined;
    const sock_n = openUdpClone(&sock_buf) orelse {
        const msg = "udp clone failed\n";
        @memcpy(f.answer[0..msg.len], msg);
        f.answer_len = msg.len;
        return;
    };

    if (!connectSocket(sock_n, ns, 53)) {
        const msg = "connect failed\n";
        @memcpy(f.answer[0..msg.len], msg);
        f.answer_len = msg.len;
        return;
    }

    var query: [512]u8 = undefined;
    const q_len = buildQuery(&query, f.name[0..f.name_len], f.qtype) orelse {
        const msg = "name too long\n";
        @memcpy(f.answer[0..msg.len], msg);
        f.answer_len = msg.len;
        return;
    };

    if (!writeData(sock_n, query[0..q_len])) {
        const msg = "write failed\n";
        @memcpy(f.answer[0..msg.len], msg);
        f.answer_len = msg.len;
        return;
    }

    var resp: [1500]u8 = undefined;
    const got = readData(sock_n, &resp) orelse {
        const msg = "timeout\n";
        @memcpy(f.answer[0..msg.len], msg);
        f.answer_len = msg.len;
        return;
    };

    formatAnswers(f, resp[0..got]);
}

fn pickNameserver(out: []u8) ?[]const u8 {
    if (readNameserverFromFs("/run/dhcp/resolv.conf", out)) |ns| return ns;
    if (readNameserverFromInitrd("etc/resolv.conf", out)) |ns| return ns;
    return null;
}

fn readNameserverFromInitrd(path: []const u8, out: []u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    const n = ferrite.readInitrdFile(path, &buf);
    if (n == 0) return null;
    return parseNameserver(buf[0..n], out);
}

fn readNameserverFromFs(path: []const u8, out: []u8) ?[]const u8 {
    var uri_buf: [128]u8 = undefined;
    const uri = fs.resolvePath(path, &uri_buf) catch return null;
    var fh = fs.open(uri, .{ .mode = .read }) catch return null;
    defer fh.close();
    var buf: [256]u8 = undefined;
    var got: usize = 0;
    while (got < buf.len) {
        const n = fh.read(got, buf[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    if (got == 0) return null;
    return parseNameserver(buf[0..got], out);
}

fn parseNameserver(content: []const u8, out: []u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, content, '\n');
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
    const uri = fs.resolvePath("/sys/net/udp/clone", &uri_buf) catch return null;
    var fh = fs.open(uri, .{ .mode = .rdwr }) catch return null;
    defer fh.close();
    var got: usize = 0;
    while (got < out.len) {
        const n = fh.read(got, out[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    const view = std.mem.trim(u8, out[0..got], " \t\r\n");
    if (view.len == 0) return null;
    if (view.ptr != out.ptr) @memmove(out[0..view.len], view);
    return out[0..view.len];
}

fn connectSocket(sock_n: []const u8, ns: []const u8, port: u16) bool {
    var path: [128]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/sys/net/udp/{s}/ctl", .{sock_n}) catch return false;
    var uri_buf: [128]u8 = undefined;
    const uri = fs.resolvePath(p, &uri_buf) catch return false;
    var fh = fs.open(uri, .{ .mode = .write }) catch return false;
    defer fh.close();
    var cmd: [128]u8 = undefined;
    const c = std.fmt.bufPrint(&cmd, "connect {s}!{d}", .{ ns, port }) catch return false;
    _ = fh.writeAll(c) catch return false;
    return true;
}

fn writeData(sock_n: []const u8, data: []const u8) bool {
    var path: [128]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/sys/net/udp/{s}/data", .{sock_n}) catch return false;
    var uri_buf: [128]u8 = undefined;
    const uri = fs.resolvePath(p, &uri_buf) catch return false;
    var fh = fs.open(uri, .{ .mode = .write }) catch return false;
    defer fh.close();
    _ = fh.writeAll(data) catch return false;
    return true;
}

fn readData(sock_n: []const u8, out: []u8) ?usize {
    var path: [128]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/sys/net/udp/{s}/data", .{sock_n}) catch return null;
    var uri_buf: [128]u8 = undefined;
    const uri = fs.resolvePath(p, &uri_buf) catch return null;
    var fh = fs.open(uri, .{ .mode = .read }) catch return null;
    defer fh.close();
    const n = fh.read(0, out) catch return null;
    if (n == 0) return null;
    return n;
}

fn buildQuery(out: []u8, name: []const u8, qtype: u16) ?usize {
    if (out.len < DNS_HDR_LEN) return null;
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

fn formatAnswers(f: *Fid, resp: []const u8) void {
    if (resp.len < DNS_HDR_LEN) {
        const msg = "short response\n";
        @memcpy(f.answer[0..msg.len], msg);
        f.answer_len = msg.len;
        return;
    }
    const rcode = resp[3] & 0x0F;
    if (rcode != 0) {
        const buf = std.fmt.bufPrint(f.answer[0..], "rcode={d}\n", .{rcode}) catch return;
        f.answer_len = @intCast(buf.len);
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

    var w: usize = 0;
    i = 0;
    while (i < ancount and off + 10 <= resp.len) : (i += 1) {
        off = skipName(resp, off) orelse return;
        if (off + 10 > resp.len) return;
        const atype = (@as(u16, resp[off]) << 8) | resp[off + 1];
        const rdlen: usize = (@as(usize, resp[off + 8]) << 8) | resp[off + 9];
        off += 10;
        if (off + rdlen > resp.len) return;

        if (atype == f.qtype) {
            if (atype == QTYPE_A and rdlen == 4) {
                const a = resp[off .. off + 4];
                const line = std.fmt.bufPrint(f.answer[w..], "{d}.{d}.{d}.{d}\n", .{ a[0], a[1], a[2], a[3] }) catch break;
                w += line.len;
            } else if (atype == QTYPE_AAAA and rdlen == 16) {
                var bytes: [16]u8 = undefined;
                @memcpy(&bytes, resp[off .. off + 16]);
                const u: std.Io.net.Ip6Address.Unresolved = .{ .bytes = bytes, .interface_name = null };
                const line = std.fmt.bufPrint(f.answer[w..], "{f}\n", .{&u}) catch break;
                w += line.len;
            }
        }
        off += rdlen;
    }

    f.answer_len = @intCast(w);
}

fn skipName(buf: []const u8, start: usize) ?usize {
    var off = start;
    while (off < buf.len) {
        const b = buf[off];
        if (b == 0) return off + 1;
        if ((b & 0xC0) == 0xC0) {
            if (off + 1 >= buf.len) return null;
            return off + 2;
        }
        if (b > 63) return null;
        off += 1 + b;
    }
    return null;
}
