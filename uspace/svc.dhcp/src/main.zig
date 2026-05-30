const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const fs = ferrite.fs;

const DHCP_CLIENT_PORT: u16 = 68;
const DHCP_SERVER_PORT: u16 = 67;
const DHCP_MAGIC = [_]u8{ 0x63, 0x82, 0x53, 0x63 };

const OP_REQUEST: u8 = 1;
const HTYPE_ETH: u8 = 1;
const HLEN_ETH: u8 = 6;

const MSG_DISCOVER: u8 = 1;
const MSG_OFFER: u8 = 2;
const MSG_REQUEST: u8 = 3;
const MSG_ACK: u8 = 5;
const MSG_NAK: u8 = 6;

const OPT_SUBNET: u8 = 1;
const OPT_ROUTER: u8 = 3;
const OPT_DNS: u8 = 6;
const OPT_REQ_IP: u8 = 50;
const OPT_LEASE: u8 = 51;
const OPT_MSG_TYPE: u8 = 53;
const OPT_SERVER_ID: u8 = 54;
const OPT_PARAM_REQ: u8 = 55;
const OPT_END: u8 = 0xFF;

const Lease = struct {
    yiaddr: [4]u8 = .{ 0, 0, 0, 0 },
    server: [4]u8 = .{ 0, 0, 0, 0 },
    subnet_prefix: u8 = 24,
    router: [4]u8 = .{ 0, 0, 0, 0 },
    has_router: bool = false,
    dns: [4]u8 = .{ 0, 0, 0, 0 },
    has_dns: bool = false,
    lease_secs: u32 = 0,
};

pub fn main() void {
    if (!waitForNet()) {
        ferrite.console.print("[svc.dhcp] /sys/net never appeared, exiting\n", .{}) catch {};
        return;
    }

    var mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };
    if (!readOurMac(&mac)) {
        ferrite.console.print("[svc.dhcp] could not read eth0 MAC\n", .{}) catch {};
        return;
    }

    var sock_buf: [16]u8 = undefined;
    const sock_n = openUdpClone(&sock_buf) orelse {
        ferrite.console.print("[svc.dhcp] udp clone failed\n", .{}) catch {};
        return;
    };

    if (!ctl(sock_n, "bind 0.0.0.0!68")) {
        ferrite.console.print("[svc.dhcp] bind 68 failed\n", .{}) catch {};
        return;
    }
    if (!ctl(sock_n, "connect 255.255.255.255!67")) {
        ferrite.console.print("[svc.dhcp] connect bcast failed\n", .{}) catch {};
        return;
    }

    const xid: u32 = 0xFE7710BE;

    var discover: [600]u8 = undefined;
    const d_len = buildDiscover(&discover, mac, xid);
    if (!writeData(sock_n, discover[0..d_len])) {
        ferrite.console.print("[svc.dhcp] discover send failed\n", .{}) catch {};
        return;
    }
    ferrite.console.print("[svc.dhcp] DISCOVER sent\n", .{}) catch {};

    var resp_buf: [1500]u8 = undefined;
    var lease = Lease{};
    if (!recvWithType(sock_n, &resp_buf, MSG_OFFER, &lease, xid)) {
        ferrite.console.print("[svc.dhcp] no OFFER\n", .{}) catch {};
        return;
    }
    ferrite.console.print("[svc.dhcp] OFFER {d}.{d}.{d}.{d} from {d}.{d}.{d}.{d}\n", .{
        lease.yiaddr[0], lease.yiaddr[1], lease.yiaddr[2], lease.yiaddr[3],
        lease.server[0], lease.server[1], lease.server[2], lease.server[3],
    }) catch {};

    var request: [600]u8 = undefined;
    const r_len = buildRequest(&request, mac, xid, lease.yiaddr, lease.server);
    if (!writeData(sock_n, request[0..r_len])) {
        ferrite.console.print("[svc.dhcp] request send failed\n", .{}) catch {};
        return;
    }

    if (!recvWithType(sock_n, &resp_buf, MSG_ACK, &lease, xid)) {
        ferrite.console.print("[svc.dhcp] no ACK\n", .{}) catch {};
        return;
    }
    ferrite.console.print("[svc.dhcp] ACK\n", .{}) catch {};

    applyLease(&lease);
}

fn waitForNet() bool {
    // Wall-clock bounded, NOT a fixed yield count. Under TCG (x86_64) svc.net's
    // NIC enumeration + ARP warmup takes many seconds -- far past the old 64x16
    // yield budget -- and yield-spinning to wait longer is counterproductive: it
    // starves QEMU's TCG main loop (the userspace-polling rule), stalling the very
    // bring-up we're waiting on. nanosleep between tries lets QEMU + svc.net make
    // progress; clockMono() (real via RDTSC on x86_64) bounds the total wait. On
    // KVM/aarch64 this returns on the first try, so the long ceiling is free.
    const deadline = ferrite.clockMono() + 60_000_000_000; // 60 s
    while (true) {
        var uri_buf: [128]u8 = undefined;
        if (fs.resolvePath("/sys/net/eth0/mac", &uri_buf)) |uri| {
            if (fs.open(uri, .{ .mode = .read })) |f| {
                f.close();
                return true;
            } else |_| {}
        } else |_| {}
        if (ferrite.clockMono() >= deadline) return false;
        ferrite.nanosleep(50_000_000); // 50 ms
    }
}

fn readOurMac(out: *[6]u8) bool {
    var uri_buf: [128]u8 = undefined;
    const uri = fs.resolvePath("/sys/net/eth0/mac", &uri_buf) catch return false;
    var f = fs.open(uri, .{ .mode = .read }) catch return false;
    defer f.close();
    var text: [32]u8 = undefined;
    var got: usize = 0;
    while (got < text.len) {
        const n = f.read(got, text[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    return parseMac(text[0..got], out);
}

fn parseMac(s: []const u8, out: *[6]u8) bool {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, s, " \t\r\n"), ':');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= 6) return false;
        if (part.len == 0 or part.len > 2) return false;
        const v = std.fmt.parseInt(u8, part, 16) catch return false;
        out[i] = v;
        i += 1;
    }
    return i == 6;
}

fn openUdpClone(out: []u8) ?[]const u8 {
    var uri_buf: [128]u8 = undefined;
    const uri = fs.resolvePath("/sys/net/udp/clone", &uri_buf) catch return null;
    var f = fs.open(uri, .{ .mode = .rdwr }) catch return null;
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

fn ctl(sock_n: []const u8, cmd: []const u8) bool {
    var path: [128]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/sys/net/udp/{s}/ctl", .{sock_n}) catch return false;
    var uri_buf: [128]u8 = undefined;
    const uri = fs.resolvePath(p, &uri_buf) catch return false;
    var f = fs.open(uri, .{ .mode = .write }) catch return false;
    defer f.close();
    _ = f.writeAll(cmd) catch return false;
    return true;
}

fn writeData(sock_n: []const u8, data: []const u8) bool {
    var path: [128]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/sys/net/udp/{s}/data", .{sock_n}) catch return false;
    var uri_buf: [128]u8 = undefined;
    const uri = fs.resolvePath(p, &uri_buf) catch return false;
    var f = fs.open(uri, .{ .mode = .write }) catch return false;
    defer f.close();
    _ = f.writeAll(data) catch return false;
    return true;
}

fn readData(sock_n: []const u8, out: []u8) ?usize {
    var path: [128]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/sys/net/udp/{s}/data", .{sock_n}) catch return null;
    var uri_buf: [128]u8 = undefined;
    const uri = fs.resolvePath(p, &uri_buf) catch return null;
    var f = fs.open(uri, .{ .mode = .read }) catch return null;
    defer f.close();
    const n = f.read(0, out) catch return null;
    if (n == 0) return null;
    return n;
}

fn recvWithType(sock_n: []const u8, buf: []u8, want_type: u8, lease: *Lease, xid: u32) bool {
    // Wall-clock bounded with nanosleep, NOT a fixed yield-spin budget. The old
    // 16x8-yield count was both unpredictable and counterproductive under TCG:
    // yield-spinning starves QEMU's TCG main loop (the userspace-polling rule),
    // delaying the very OFFER/ACK we're polling for -> intermittent "no OFFER".
    // nanosleep lets svc.net + QEMU make progress; clockMono() bounds the wait.
    const deadline = ferrite.clockMono() + 10_000_000_000; // 10 s
    while (true) {
        if (readData(sock_n, buf)) |n| {
            if (parseDhcp(buf[0..n], lease, xid)) |got_type| {
                if (got_type == want_type) return true;
                if (got_type == MSG_NAK) return false;
            }
        }
        if (ferrite.clockMono() >= deadline) return false;
        ferrite.nanosleep(20_000_000); // 20 ms
    }
}

fn buildDiscover(out: []u8, mac: [6]u8, xid: u32) usize {
    return buildPacket(out, mac, xid, MSG_DISCOVER, null, null);
}

fn buildRequest(out: []u8, mac: [6]u8, xid: u32, req_ip: [4]u8, server: [4]u8) usize {
    return buildPacket(out, mac, xid, MSG_REQUEST, req_ip, server);
}

fn buildPacket(out: []u8, mac: [6]u8, xid: u32, msg_type: u8, req_ip: ?[4]u8, server: ?[4]u8) usize {
    @memset(out[0..240], 0);
    out[0] = OP_REQUEST;
    out[1] = HTYPE_ETH;
    out[2] = HLEN_ETH;
    out[3] = 0;
    out[4] = @intCast((xid >> 24) & 0xff);
    out[5] = @intCast((xid >> 16) & 0xff);
    out[6] = @intCast((xid >> 8) & 0xff);
    out[7] = @intCast(xid & 0xff);
    out[10] = 0x80; // broadcast bit so server replies via L2 broadcast
    out[11] = 0;
    @memcpy(out[28..34], &mac);
    @memcpy(out[236..240], &DHCP_MAGIC);

    var w: usize = 240;
    w += writeOpt1(out[w..], OPT_MSG_TYPE, &[_]u8{msg_type});
    w += writeOpt1(out[w..], OPT_PARAM_REQ, &[_]u8{ OPT_SUBNET, OPT_ROUTER, OPT_DNS, OPT_LEASE });
    if (req_ip) |ip| w += writeOpt1(out[w..], OPT_REQ_IP, &ip);
    if (server) |s| w += writeOpt1(out[w..], OPT_SERVER_ID, &s);
    out[w] = OPT_END;
    w += 1;
    // Pad to BOOTP min (300 bytes).
    while (w < 300) : (w += 1) out[w] = 0;
    return w;
}

fn writeOpt1(out: []u8, tag: u8, val: []const u8) usize {
    if (out.len < 2 + val.len) return 0;
    out[0] = tag;
    out[1] = @intCast(val.len);
    @memcpy(out[2..][0..val.len], val);
    return 2 + val.len;
}

fn parseDhcp(pkt: []const u8, lease: *Lease, xid: u32) ?u8 {
    if (pkt.len < 244) return null;
    if (pkt[0] != 2) return null;
    const pkt_xid = (@as(u32, pkt[4]) << 24) | (@as(u32, pkt[5]) << 16) | (@as(u32, pkt[6]) << 8) | pkt[7];
    if (pkt_xid != xid) return null;
    if (!std.mem.eql(u8, pkt[236..240], &DHCP_MAGIC)) return null;

    @memcpy(&lease.yiaddr, pkt[16..20]);

    var msg_type: u8 = 0;
    var off: usize = 240;
    while (off + 1 < pkt.len) {
        const tag = pkt[off];
        if (tag == OPT_END) break;
        if (tag == 0) {
            off += 1;
            continue;
        }
        off += 1;
        if (off >= pkt.len) break;
        const len: usize = pkt[off];
        off += 1;
        if (off + len > pkt.len) break;
        const data = pkt[off .. off + len];
        switch (tag) {
            OPT_MSG_TYPE => if (len >= 1) {
                msg_type = data[0];
            },
            OPT_SUBNET => if (len == 4) {
                lease.subnet_prefix = prefixFromMask(data[0..4].*);
            },
            OPT_ROUTER => if (len >= 4) {
                @memcpy(&lease.router, data[0..4]);
                lease.has_router = true;
            },
            OPT_DNS => if (len >= 4) {
                @memcpy(&lease.dns, data[0..4]);
                lease.has_dns = true;
            },
            OPT_SERVER_ID => if (len == 4) {
                @memcpy(&lease.server, data[0..4]);
            },
            OPT_LEASE => if (len == 4) {
                lease.lease_secs = (@as(u32, data[0]) << 24) | (@as(u32, data[1]) << 16) | (@as(u32, data[2]) << 8) | data[3];
            },
            else => {},
        }
        off += len;
    }
    if (msg_type == 0) return null;
    return msg_type;
}

fn prefixFromMask(mask: [4]u8) u8 {
    var count: u8 = 0;
    for (mask) |b| count += @popCount(b);
    return count;
}

fn applyLease(lease: *const Lease) void {
    var addr_buf: [64]u8 = undefined;
    const addr_text = std.fmt.bufPrint(&addr_buf, "{d}.{d}.{d}.{d}/{d}", .{
        lease.yiaddr[0], lease.yiaddr[1], lease.yiaddr[2], lease.yiaddr[3], lease.subnet_prefix,
    }) catch return;
    writeText("/sys/net/eth0/addr", addr_text) catch |e| {
        ferrite.console.print("[svc.dhcp] write addr failed: {t}\n", .{e}) catch {};
        return;
    };

    if (lease.has_router) {
        var gw_buf: [32]u8 = undefined;
        const gw_text = std.fmt.bufPrint(&gw_buf, "{d}.{d}.{d}.{d}", .{
            lease.router[0], lease.router[1], lease.router[2], lease.router[3],
        }) catch return;
        writeText("/sys/net/eth0/gw", gw_text) catch |e| {
            ferrite.console.print("[svc.dhcp] write gw failed: {t}\n", .{e}) catch {};
        };
    }

    if (lease.has_dns) {
        ensureDir("/run/dhcp") catch {};
        var ns_buf: [128]u8 = undefined;
        const ns_text = std.fmt.bufPrint(&ns_buf, "nameserver {d}.{d}.{d}.{d}\n", .{
            lease.dns[0], lease.dns[1], lease.dns[2], lease.dns[3],
        }) catch return;
        ensureFile("/run/dhcp/resolv.conf") catch {};
        writeText("/run/dhcp/resolv.conf", ns_text) catch |e| {
            ferrite.console.print("[svc.dhcp] write resolv.conf failed: {t}\n", .{e}) catch {};
        };
    }

    ferrite.console.print("[svc.dhcp] lease applied: {d}.{d}.{d}.{d}/{d} gw={d}.{d}.{d}.{d} dns={d}.{d}.{d}.{d} lease={d}s\n", .{
        lease.yiaddr[0], lease.yiaddr[1], lease.yiaddr[2], lease.yiaddr[3],  lease.subnet_prefix,
        lease.router[0], lease.router[1], lease.router[2], lease.router[3],  lease.dns[0],
        lease.dns[1],    lease.dns[2],    lease.dns[3],    lease.lease_secs,
    }) catch {};
}

fn ensureDir(path: []const u8) !void {
    fs.create(path, .dir) catch |e| switch (e) {
        error.BadOp, error.NotFound => {},
        else => return e,
    };
}

fn ensureFile(path: []const u8) !void {
    fs.create(path, .file) catch |e| switch (e) {
        error.BadOp, error.NotFound => {},
        else => return e,
    };
}

fn writeText(path: []const u8, text: []const u8) !void {
    var uri_buf: [128]u8 = undefined;
    const uri = try fs.resolvePath(path, &uri_buf);
    var f = try fs.open(uri, .{ .mode = .write });
    defer f.close();
    _ = try f.writeAll(text);
}
