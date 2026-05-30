const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const p9 = ferrite.p9;
const fs = ferrite.fs;

const URI_PREFIX = "com.midstall.ferrite.net@v0";
const MOUNT_PREFIX = "/sys/net";
const CONFIG_PATH = "etc/net.conf";

// ---- Ethernet / IP / ICMP / ARP wire formats -------------------------------

const ETH_TYPE_IPV4: u16 = 0x0800;
const ETH_TYPE_ARP: u16 = 0x0806;
const ETH_TYPE_IPV6: u16 = 0x86DD;

const IP_PROTO_ICMP: u8 = 1;
const IP_PROTO_TCP: u8 = 6;
const IP_PROTO_UDP: u8 = 17;
const IP_PROTO_ICMPV6: u8 = 58;

const ICMP_ECHO_REQ: u8 = 8;
const ICMP_ECHO_REPLY: u8 = 0;

const ICMPV6_RS: u8 = 133;
const ICMPV6_RA: u8 = 134;
const ICMPV6_NS: u8 = 135;
const ICMPV6_NA: u8 = 136;
const ICMPV6_ECHO_REQ: u8 = 128;
const ICMPV6_ECHO_REPLY: u8 = 129;

const NDP_OPT_SRC_LLA: u8 = 1;
const NDP_OPT_TGT_LLA: u8 = 2;

const NA_FLAG_SOLICITED: u32 = 0x40_00_00_00;
const NA_FLAG_OVERRIDE: u32 = 0x20_00_00_00;

const ARP_HW_ETHERNET: u16 = 1;
const ARP_OP_REQUEST: u16 = 1;
const ARP_OP_REPLY: u16 = 2;

const ETH_HDR_LEN = 14;
const IPV4_HDR_LEN = 20;
const IPV6_HDR_LEN = 40;
const ICMP_HDR_LEN = 8;
const ARP_PKT_LEN = 28;

const BROADCAST_MAC: [6]u8 = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
const ZERO_MAC: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };

const Ipv4 = [4]u8;
const Ipv6 = [16]u8;
const Mac = [6]u8;
const ZERO_IPV6: Ipv6 = @splat(0);
const ZERO_IPV4: Ipv4 = @splat(0);
const BROADCAST_IPV4: Ipv4 = @splat(0xff);

// ---- Configuration ---------------------------------------------------------

var our_mac: Mac = @splat(0);
var our_ip: Ipv4 = @splat(0);
var our_prefix: u8 = 24;
var our_gw: Ipv4 = @splat(0);
var our_ip6: Ipv6 = @splat(0);
var our_prefix6: u8 = 64;
var our_gw6: Ipv6 = @splat(0);

// ---- ARP cache -------------------------------------------------------------

const ARP_TTL_TICKS: u32 = 60_000; // ~60s at ~1ms tick

const ArpEntry = struct {
    ip: Ipv4 = @splat(0),
    mac: Mac = @splat(0),
    valid: bool = false,
    seen_at: u64 = 0,
};

const ARP_SLOTS = 16;
var arp_cache: [ARP_SLOTS]ArpEntry = @splat(.{});

fn arpLookup(ip: Ipv4) ?Mac {
    for (&arp_cache) |*e| {
        if (e.valid and std.mem.eql(u8, &e.ip, &ip)) return e.mac;
    }
    return null;
}

fn arpInsert(ip: Ipv4, mac: Mac) void {
    var oldest: usize = 0;
    var oldest_ts: u64 = std.math.maxInt(u64);
    for (&arp_cache, 0..) |*e, i| {
        if (e.valid and std.mem.eql(u8, &e.ip, &ip)) {
            e.mac = mac;
            e.seen_at = nowTicks();
            return;
        }
        if (!e.valid) {
            e.* = .{ .ip = ip, .mac = mac, .valid = true, .seen_at = nowTicks() };
            return;
        }
        if (e.seen_at < oldest_ts) {
            oldest_ts = e.seen_at;
            oldest = i;
        }
    }
    arp_cache[oldest] = .{ .ip = ip, .mac = mac, .valid = true, .seen_at = nowTicks() };
}

var fake_ticks: u64 = 0;

fn nowTicks() u64 {
    fake_ticks +%= 1;
    return fake_ticks;
}

// ---- NDP cache -------------------------------------------------------------

const NdpEntry = struct {
    ip: Ipv6 = @splat(0),
    mac: Mac = @splat(0),
    valid: bool = false,
    seen_at: u64 = 0,
};

const NDP_SLOTS = 16;
var ndp_cache: [NDP_SLOTS]NdpEntry = @splat(.{});

fn ndpLookup(ip: Ipv6) ?Mac {
    for (&ndp_cache) |*e| {
        if (e.valid and std.mem.eql(u8, &e.ip, &ip)) return e.mac;
    }
    return null;
}

fn ndpInsert(ip: Ipv6, mac: Mac) void {
    var oldest: usize = 0;
    var oldest_ts: u64 = std.math.maxInt(u64);
    for (&ndp_cache, 0..) |*e, i| {
        if (e.valid and std.mem.eql(u8, &e.ip, &ip)) {
            e.mac = mac;
            e.seen_at = nowTicks();
            return;
        }
        if (!e.valid) {
            e.* = .{ .ip = ip, .mac = mac, .valid = true, .seen_at = nowTicks() };
            return;
        }
        if (e.seen_at < oldest_ts) {
            oldest_ts = e.seen_at;
            oldest = i;
        }
    }
    ndp_cache[oldest] = .{ .ip = ip, .mac = mac, .valid = true, .seen_at = nowTicks() };
}

// ---- ICMP echo pending state ----------------------------------------------

// One in-flight echo per family. RX matches by (id, seq) and writes the reply
// summary; the fs read handler yields until done flips.
const Ping4State = struct {
    in_flight: bool = false,
    id: u16 = 0,
    seq: u16 = 0,
    target: Ipv4 = @splat(0),
    reply_text: [128]u8 = @splat(0),
    reply_len: u16 = 0,
    done: u32 = 0, // 0 = waiting, 1 = reply, 2 = timeout
};

const Ping6State = struct {
    in_flight: bool = false,
    id: u16 = 0,
    seq: u16 = 0,
    target: Ipv6 = @splat(0),
    reply_text: [128]u8 = @splat(0),
    reply_len: u16 = 0,
    done: u32 = 0,
};

var ping_state: Ping4State = .{};
var ping6_state: Ping6State = .{};

// ---- UDP sockets -----------------------------------------------------------

const UDP_HDR_LEN: usize = 8;
const UDP_MAX_SOCKETS = 8;
const UDP_RECV_RING_BYTES = 4096;
const UDP_DGRAM_MAX = 1400;

const UdpFamily = enum { ipv4, ipv6 };

const UdpAddr = struct {
    family: UdpFamily = .ipv4,
    v4: Ipv4 = @splat(0),
    v6: Ipv6 = @splat(0),
    port: u16 = 0,
};

const UdpSocket = struct {
    used: bool = false,
    opened: bool = false,
    family: UdpFamily = .ipv4,
    local_port: u16 = 0,
    has_remote: bool = false,
    remote: UdpAddr = .{},
    // Entry layout: 2-byte BE length, then payload. No wrap; tail-pads instead.
    recv_buf: [UDP_RECV_RING_BYTES]u8 = undefined,
    recv_w: usize = 0,
    recv_r: usize = 0,
};

var udp_sockets: [UDP_MAX_SOCKETS]UdpSocket = @splat(.{});
var next_ephemeral_port: u16 = 32768;

// ---- TCP sockets -----------------------------------------------------------

const TCP_HDR_MIN: usize = 20;
const TCP_MAX_SOCKETS: usize = 8;
const TCP_SEND_BUF: usize = 8192;
const TCP_RECV_BUF: usize = 8192;
const TCP_DEFAULT_MSS: u16 = 1400;

const TCP_FIN: u8 = 0x01;
const TCP_SYN: u8 = 0x02;
const TCP_RST: u8 = 0x04;
const TCP_PSH: u8 = 0x08;
const TCP_ACK: u8 = 0x10;

const TcpState = enum(u8) {
    closed,
    listen,
    syn_sent,
    syn_received,
    established,
    fin_wait_1,
    fin_wait_2,
    close_wait,
    closing,
    last_ack,
    time_wait,
};

const TCP_ACCEPT_BACKLOG: usize = 8;
const NO_PARENT: u8 = 0xff;

const TcpSocket = struct {
    used: bool = false,
    state: TcpState = .closed,
    family: UdpFamily = .ipv4,
    local_port: u16 = 0,
    remote: UdpAddr = .{},
    has_remote: bool = false,

    snd_nxt: u32 = 0,
    snd_una: u32 = 0,
    snd_wnd: u32 = 65535,
    rcv_nxt: u32 = 0,
    mss: u16 = TCP_DEFAULT_MSS,

    send_buf: [TCP_SEND_BUF]u8 = undefined,
    send_buf_w: usize = 0,
    send_buf_acked: usize = 0,

    recv_buf: [TCP_RECV_BUF]u8 = undefined,
    recv_r: usize = 0,
    recv_w: usize = 0,

    last_tx_seq: u32 = 0,
    last_tx_len: u32 = 0,

    is_listener: bool = false,
    accept_queue: [TCP_ACCEPT_BACKLOG]u8 = @splat(0),
    accept_head: u8 = 0,
    accept_count: u8 = 0,
    parent_listener: u8 = NO_PARENT,

    // Blocking-accept: cap stashed by onReadAsync, claimed by Xchg from either
    // side. Exactly one thread wins and sends the reply. 0 = no pending reader.
    pending_reply_cap: u32 = 0,
    pending_tag: u8 = 0,
};

var tcp_sockets: [TCP_MAX_SOCKETS]TcpSocket = @splat(.{});

fn tcpAlloc(family: UdpFamily) ?u8 {
    for (&tcp_sockets, 0..) |*s, i| {
        if (!s.used) {
            s.* = .{
                .used = true,
                .family = family,
                .local_port = nextEphemeralPort(),
            };
            return @intCast(i);
        }
    }
    return null;
}

fn udpAlloc(family: UdpFamily) ?u8 {
    for (&udp_sockets, 0..) |*s, i| {
        if (!s.used) {
            s.* = .{
                .used = true,
                .family = family,
                .local_port = nextEphemeralPort(),
            };
            return @intCast(i);
        }
    }
    return null;
}

fn udpRelease(idx: u8) void {
    if (idx >= UDP_MAX_SOCKETS) return;
    udp_sockets[idx] = .{};
}

fn nextEphemeralPort() u16 {
    const p = next_ephemeral_port;
    next_ephemeral_port +%= 1;
    if (next_ephemeral_port < 32768) next_ephemeral_port = 32768;
    return p;
}

fn udpPushIncoming(s: *UdpSocket, payload: []const u8) void {
    if (payload.len > UDP_DGRAM_MAX) return;
    const need: usize = 2 + payload.len;

    while (true) {
        const used: usize = (s.recv_w + s.recv_buf.len - s.recv_r) % s.recv_buf.len;
        if (s.recv_buf.len - used > need) break;
        if (s.recv_r == s.recv_w) return;
        const hdr_lo: u16 = s.recv_buf[s.recv_r];
        const hdr_hi: u16 = s.recv_buf[(s.recv_r + 1) % s.recv_buf.len];
        const drop_len: usize = (hdr_lo << 8) | hdr_hi;
        s.recv_r = (s.recv_r + 2 + drop_len) % s.recv_buf.len;
    }

    // 0xFFFF len = "skip to ring start" sentinel; entries can't straddle.
    const contiguous_space = s.recv_buf.len - s.recv_w;
    if (contiguous_space < need) {
        if (contiguous_space >= 2) {
            s.recv_buf[s.recv_w] = 0xFF;
            s.recv_buf[s.recv_w + 1] = 0xFF;
        }
        s.recv_w = 0;
    }

    s.recv_buf[s.recv_w] = @intCast((payload.len >> 8) & 0xff);
    s.recv_buf[s.recv_w + 1] = @intCast(payload.len & 0xff);
    @memcpy(s.recv_buf[s.recv_w + 2 .. s.recv_w + 2 + payload.len], payload);
    s.recv_w += need;
}

/// Pop one datagram into out; returns 0 if empty, otherwise bytes copied.
fn udpPopOutgoing(s: *UdpSocket, out: []u8) usize {
    while (true) {
        if (s.recv_r == s.recv_w) return 0;
        const hi: u16 = s.recv_buf[s.recv_r];
        const lo: u16 = s.recv_buf[s.recv_r + 1];
        const len: usize = (hi << 8) | lo;
        if (len == 0xFFFF) {
            s.recv_r = 0;
            continue;
        }
        const start = s.recv_r + 2;
        const want = @min(len, out.len);
        @memcpy(out[0..want], s.recv_buf[start .. start + want]);
        s.recv_r += 2 + len;
        return want;
    }
}

// ---- I/O handles -----------------------------------------------------------

var eth0: ferrite.fs.File = undefined;

// ---- Big endian helpers ----------------------------------------------------

inline fn rdBe16(b: *const [2]u8) u16 {
    return (@as(u16, b[0]) << 8) | @as(u16, b[1]);
}
inline fn wrBe16(b: *[2]u8, v: u16) void {
    b[0] = @intCast((v >> 8) & 0xff);
    b[1] = @intCast(v & 0xff);
}

inline fn wrBe32(b: *[4]u8, v: u32) void {
    b[0] = @intCast((v >> 24) & 0xff);
    b[1] = @intCast((v >> 16) & 0xff);
    b[2] = @intCast((v >> 8) & 0xff);
    b[3] = @intCast(v & 0xff);
}

fn inetChecksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        sum += (@as(u32, bytes[i]) << 8) | @as(u32, bytes[i + 1]);
    }
    if (i < bytes.len) sum += @as(u32, bytes[i]) << 8;
    while ((sum >> 16) != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

/// IPv6 pseudo-header checksum (src + dst + upper-layer len + next-header).
fn ipv6Checksum(src: Ipv6, dst: Ipv6, next_header: u8, payload: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < src.len) : (i += 2) sum += (@as(u32, src[i]) << 8) | src[i + 1];
    i = 0;
    while (i + 1 < dst.len) : (i += 2) sum += (@as(u32, dst[i]) << 8) | dst[i + 1];
    const upper: u32 = @intCast(payload.len);
    sum += (upper >> 16) & 0xFFFF;
    sum += upper & 0xFFFF;
    sum += next_header;
    i = 0;
    while (i + 1 < payload.len) : (i += 2) sum += (@as(u32, payload[i]) << 8) | payload[i + 1];
    if (i < payload.len) sum += @as(u32, payload[i]) << 8;
    while ((sum >> 16) != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

/// ff02::1:ffXX:XXXX where XX:XXXX is the low 24 bits of the unicast.
fn solicitedNodeMulticast(addr: Ipv6) Ipv6 {
    var out: Ipv6 = @splat(0);
    out[0] = 0xff;
    out[1] = 0x02;
    out[11] = 0x01;
    out[12] = 0xff;
    out[13] = addr[13];
    out[14] = addr[14];
    out[15] = addr[15];
    return out;
}

/// Ethernet multicast MAC for an IPv6 multicast: 33:33 || low-32 of address.
fn ipv6McastMac(addr: Ipv6) Mac {
    return .{ 0x33, 0x33, addr[12], addr[13], addr[14], addr[15] };
}

fn isMulticast6(addr: Ipv6) bool {
    return addr[0] == 0xff;
}

inline fn isOurIp6(addr: Ipv6) bool {
    return std.mem.eql(u8, &addr, &our_ip6);
}

fn isForUs6(dst: Ipv6) bool {
    if (isOurIp6(dst)) return true;
    if (!isMulticast6(dst)) return false;
    const sn = solicitedNodeMulticast(our_ip6);
    if (std.mem.eql(u8, &dst, &sn)) return true;
    var all_nodes: Ipv6 = @splat(0);
    all_nodes[0] = 0xff;
    all_nodes[1] = 0x02;
    all_nodes[15] = 0x01;
    return std.mem.eql(u8, &dst, &all_nodes);
}

fn sameSubnet6(a: Ipv6, b: Ipv6, prefix: u8) bool {
    if (prefix == 0) return true;
    var bits: u32 = prefix;
    var i: usize = 0;
    while (bits >= 8 and i < 16) : (i += 1) {
        if (a[i] != b[i]) return false;
        bits -= 8;
    }
    if (bits > 0 and i < 16) {
        const mask: u8 = @intCast(@as(u16, 0xFF) << @intCast(8 - bits) & 0xFF);
        if ((a[i] & mask) != (b[i] & mask)) return false;
    }
    return true;
}

// ---- TX helpers ------------------------------------------------------------

/// Set true to log every TX/RX packet header. Off by default - this
/// flood drowns interactive console input (login, sh).
const trace_packets = false;

// Builders use local stack buffers, not a shared global: writeAll's IPC
// yields, and the RX thread can re-enter sendFrame (e.g. NDP advert reply)
// during that yield.
fn sendFrame(buf: []const u8) void {
    if (trace_packets and buf.len >= 14) {
        const t = (@as(u16, buf[12]) << 8) | buf[13];
        ferrite.console.print("[tx] type=0x{x:0>4} len={d} dst={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}\n", .{
            t, buf.len, buf[0], buf[1], buf[2], buf[3], buf[4], buf[5],
        }) catch {};
        if (t == ETH_TYPE_IPV4 and buf.len >= 14 + 20) {
            const ip = buf[14..];
            ferrite.console.print("    v4 src={d}.{d}.{d}.{d} dst={d}.{d}.{d}.{d} proto={d}\n", .{
                ip[12], ip[13], ip[14], ip[15], ip[16], ip[17], ip[18], ip[19], ip[9],
            }) catch {};
        }
    }
    _ = eth0.writeAll(buf) catch {};
}

fn sendArpRequest(target_ip: Ipv4) void {
    var buf: [ETH_HDR_LEN + ARP_PKT_LEN]u8 = undefined;
    const f = buf[0..];
    @memcpy(f[0..6], &BROADCAST_MAC);
    @memcpy(f[6..12], &our_mac);
    wrBe16(f[12..14], ETH_TYPE_ARP);

    const a = f[ETH_HDR_LEN..];
    wrBe16(a[0..2], ARP_HW_ETHERNET);
    wrBe16(a[2..4], ETH_TYPE_IPV4);
    a[4] = 6;
    a[5] = 4;
    wrBe16(a[6..8], ARP_OP_REQUEST);
    @memcpy(a[8..14], &our_mac);
    @memcpy(a[14..18], &our_ip);
    @memcpy(a[18..24], &ZERO_MAC);
    @memcpy(a[24..28], &target_ip);

    sendFrame(f);
}

fn sendArpReply(target_mac: Mac, target_ip: Ipv4) void {
    var buf: [ETH_HDR_LEN + ARP_PKT_LEN]u8 = undefined;
    const f = buf[0..];
    @memcpy(f[0..6], &target_mac);
    @memcpy(f[6..12], &our_mac);
    wrBe16(f[12..14], ETH_TYPE_ARP);

    const a = f[ETH_HDR_LEN..];
    wrBe16(a[0..2], ARP_HW_ETHERNET);
    wrBe16(a[2..4], ETH_TYPE_IPV4);
    a[4] = 6;
    a[5] = 4;
    wrBe16(a[6..8], ARP_OP_REPLY);
    @memcpy(a[8..14], &our_mac);
    @memcpy(a[14..18], &our_ip);
    @memcpy(a[18..24], &target_mac);
    @memcpy(a[24..28], &target_ip);

    sendFrame(f);
}

/// Direct if same subnet; otherwise via gateway. 255.255.255.255 = L2 broadcast.
fn resolveNextHop(dst: Ipv4) ?Mac {
    if (std.mem.eql(u8, &dst, &BROADCAST_IPV4)) return BROADCAST_MAC;
    const dst_hop = if (sameSubnet(dst, our_ip, our_prefix)) dst else our_gw;
    if (arpLookup(dst_hop)) |m| return m;
    sendArpRequest(dst_hop);
    return null;
}

fn sameSubnet(a: Ipv4, b: Ipv4, prefix: u8) bool {
    const a32 = ipToU32(a);
    const b32 = ipToU32(b);
    if (prefix == 0) return true;
    if (prefix >= 32) return std.mem.eql(u8, &a, &b);
    const mask = @as(u32, 0xFFFF_FFFF) << @intCast(32 - prefix);
    return (a32 & mask) == (b32 & mask);
}

inline fn ipToU32(ip: Ipv4) u32 {
    return (@as(u32, ip[0]) << 24) | (@as(u32, ip[1]) << 16) | (@as(u32, ip[2]) << 8) | @as(u32, ip[3]);
}

const MAX_FRAME: usize = 1600;

fn sendIpv4(dst: Ipv4, proto: u8, payload: []const u8) bool {
    return sendIpv4Raw(our_ip, dst, proto, payload);
}

fn sendIpv4Raw(src: Ipv4, dst: Ipv4, proto: u8, payload: []const u8) bool {
    const next_hop_mac = resolveNextHop(dst) orelse return false;

    const total = ETH_HDR_LEN + IPV4_HDR_LEN + payload.len;
    if (total > MAX_FRAME) return false;
    var buf: [MAX_FRAME]u8 = undefined;
    const f = buf[0..total];

    @memcpy(f[0..6], &next_hop_mac);
    @memcpy(f[6..12], &our_mac);
    wrBe16(f[12..14], ETH_TYPE_IPV4);

    const ip = f[ETH_HDR_LEN..];
    ip[0] = 0x45;
    ip[1] = 0;
    wrBe16(ip[2..4], @intCast(IPV4_HDR_LEN + payload.len));
    wrBe16(ip[4..6], 0);
    wrBe16(ip[6..8], 0x4000);
    ip[8] = 64;
    ip[9] = proto;
    wrBe16(ip[10..12], 0);
    @memcpy(ip[12..16], &src);
    @memcpy(ip[16..20], &dst);
    const csum = inetChecksum(ip[0..IPV4_HDR_LEN]);
    wrBe16(ip[10..12], csum);

    @memcpy(ip[IPV4_HDR_LEN..][0..payload.len], payload);

    sendFrame(f);
    return true;
}

// ---- RX dispatch -----------------------------------------------------------

fn handleArp(frame: []const u8) void {
    if (frame.len < ETH_HDR_LEN + ARP_PKT_LEN) return;
    const a = frame[ETH_HDR_LEN..][0..ARP_PKT_LEN];
    const htype = rdBe16(a[0..2]);
    const ptype = rdBe16(a[2..4]);
    if (htype != ARP_HW_ETHERNET or ptype != ETH_TYPE_IPV4) return;
    if (a[4] != 6 or a[5] != 4) return;

    const op = rdBe16(a[6..8]);
    var sender_mac: Mac = undefined;
    @memcpy(&sender_mac, a[8..14]);
    var sender_ip: Ipv4 = undefined;
    @memcpy(&sender_ip, a[14..18]);
    var target_ip: Ipv4 = undefined;
    @memcpy(&target_ip, a[24..28]);

    arpInsert(sender_ip, sender_mac);

    if (op == ARP_OP_REQUEST and std.mem.eql(u8, &target_ip, &our_ip)) {
        sendArpReply(sender_mac, sender_ip);
    }
}

fn handleIpv4(frame: []const u8) void {
    if (frame.len < ETH_HDR_LEN + IPV4_HDR_LEN) return;
    const ip = frame[ETH_HDR_LEN..];
    const ver_ihl = ip[0];
    if ((ver_ihl >> 4) != 4) return;
    const ihl: usize = @as(usize, ver_ihl & 0x0F) * 4;
    if (ihl < IPV4_HDR_LEN) return;
    if (frame.len < ETH_HDR_LEN + ihl) return;
    const total: usize = @intCast(rdBe16(ip[2..4]));
    if (total < ihl or ETH_HDR_LEN + total > frame.len) return;

    var dst: Ipv4 = undefined;
    @memcpy(&dst, ip[16..20]);
    const is_broadcast = std.mem.eql(u8, &dst, &BROADCAST_IPV4);
    if (!is_broadcast and !std.mem.eql(u8, &dst, &our_ip)) return;

    // Passive ARP learning.
    var src_addr: Ipv4 = undefined;
    @memcpy(&src_addr, ip[12..16]);
    if (!std.mem.eql(u8, &src_addr, &our_ip) and !std.mem.eql(u8, &src_addr, &ZERO_IPV4)) {
        var src_mac: Mac = undefined;
        @memcpy(&src_mac, frame[6..12]);
        arpInsert(src_addr, src_mac);
    }

    const proto = ip[9];
    const payload = frame[ETH_HDR_LEN + ihl .. ETH_HDR_LEN + total];

    switch (proto) {
        IP_PROTO_ICMP => handleIcmp(ip[12..16], payload),
        IP_PROTO_UDP => {
            if (payload.len < UDP_HDR_LEN) return;
            const src_port = rdBe16(payload[0..2]);
            const dst_port = rdBe16(payload[2..4]);
            const ulen = rdBe16(payload[4..6]);
            if (ulen < UDP_HDR_LEN or ulen > payload.len) return;
            const data = payload[UDP_HDR_LEN..ulen];
            var src_ip: Ipv4 = undefined;
            @memcpy(&src_ip, ip[12..16]);
            deliverUdp4(src_ip, src_port, dst_port, data);
        },
        IP_PROTO_TCP => {
            var src_ip: Ipv4 = undefined;
            @memcpy(&src_ip, ip[12..16]);
            deliverTcp(payload, .ipv4, src_ip, @splat(0));
        },
        else => {},
    }
}

fn handleIpv6(frame: []const u8) void {
    if (frame.len < ETH_HDR_LEN + IPV6_HDR_LEN) return;
    const ip = frame[ETH_HDR_LEN..];
    if ((ip[0] >> 4) != 6) return;
    const payload_len: usize = rdBe16(ip[4..6]);
    if (ETH_HDR_LEN + IPV6_HDR_LEN + payload_len > frame.len) return;

    var dst: Ipv6 = undefined;
    @memcpy(&dst, ip[24..40]);
    if (!isForUs6(dst)) return;

    var src: Ipv6 = undefined;
    @memcpy(&src, ip[8..24]);

    // Passive neighbor learning. Skip multicast/unspecified sources.
    if (src[0] != 0xff and !std.mem.eql(u8, &src, &ZERO_IPV6)) {
        var src_mac: Mac = undefined;
        @memcpy(&src_mac, frame[6..12]);
        ndpInsert(src, src_mac);
    }

    const next = ip[6];
    const payload = frame[ETH_HDR_LEN + IPV6_HDR_LEN .. ETH_HDR_LEN + IPV6_HDR_LEN + payload_len];

    switch (next) {
        IP_PROTO_ICMPV6 => handleIcmp6(src, payload),
        IP_PROTO_UDP => {
            if (payload.len < UDP_HDR_LEN) return;
            const src_port = rdBe16(payload[0..2]);
            const dst_port = rdBe16(payload[2..4]);
            const ulen = rdBe16(payload[4..6]);
            if (ulen < UDP_HDR_LEN or ulen > payload.len) return;
            const data = payload[UDP_HDR_LEN..ulen];
            deliverUdp6(src, src_port, dst_port, data);
        },
        IP_PROTO_TCP => deliverTcp(payload, .ipv6, @splat(0), src),
        else => {},
    }
}

fn handleIcmp6(src: Ipv6, payload: []const u8) void {
    if (payload.len < 4) return;
    switch (payload[0]) {
        ICMPV6_NS => handleNeighborSolicit(src, payload),
        ICMPV6_NA => handleNeighborAdvert(payload),
        ICMPV6_ECHO_REQ => sendEchoReply6(src, payload),
        ICMPV6_ECHO_REPLY => {
            if (payload.len < 8) return;
            const id = rdBe16(payload[4..6]);
            const seq = rdBe16(payload[6..8]);
            if (@atomicLoad(u32, &ping6_state.done, .acquire) == 0 and
                ping6_state.in_flight and
                ping6_state.id == id and
                ping6_state.seq == seq and
                std.mem.eql(u8, &src, &ping6_state.target))
            {
                const text = formatPingReply6(&ping6_state.reply_text, src, seq, payload.len);
                ping6_state.reply_len = @intCast(text.len);
                @atomicStore(u32, &ping6_state.done, 1, .release);
            }
        },
        else => {},
    }
}

fn handleNeighborSolicit(src: Ipv6, payload: []const u8) void {
    if (payload.len < 24) return;
    var target: Ipv6 = undefined;
    @memcpy(&target, payload[8..24]);

    var off: usize = 24;
    while (off + 2 <= payload.len) {
        const opt_type = payload[off];
        const opt_len_units = payload[off + 1];
        if (opt_len_units == 0) return;
        const opt_len: usize = @as(usize, opt_len_units) * 8;
        if (off + opt_len > payload.len) return;
        if (opt_type == NDP_OPT_SRC_LLA and opt_len >= 8) {
            var src_mac: Mac = undefined;
            @memcpy(&src_mac, payload[off + 2 ..][0..6]);
            ndpInsert(src, src_mac);
        }
        off += opt_len;
    }

    if (isOurIp6(target)) {
        if (ndpLookup(src)) |m| sendNdpAdvert(m, src);
    }
}

fn handleNeighborAdvert(payload: []const u8) void {
    if (payload.len < 24) return;
    var target: Ipv6 = undefined;
    @memcpy(&target, payload[8..24]);
    var off: usize = 24;
    while (off + 2 <= payload.len) {
        const opt_type = payload[off];
        const opt_len_units = payload[off + 1];
        if (opt_len_units == 0) return;
        const opt_len: usize = @as(usize, opt_len_units) * 8;
        if (off + opt_len > payload.len) return;
        if (opt_type == NDP_OPT_TGT_LLA and opt_len >= 8) {
            var mac: Mac = undefined;
            @memcpy(&mac, payload[off + 2 ..][0..6]);
            ndpInsert(target, mac);
        }
        off += opt_len;
    }
}

fn formatPingReply6(buf: *[128]u8, src: Ipv6, seq: u16, bytes: usize) []const u8 {
    var tmp: [64]u8 = undefined;
    const addr_str = formatIpv6Into(&tmp, src);
    return std.fmt.bufPrint(buf, "{s} seq={d} ({d} bytes)\n", .{ addr_str, seq, bytes }) catch buf[0..0];
}

fn handleIcmp(src_ip_bytes: *const [4]u8, payload: []const u8) void {
    if (payload.len < ICMP_HDR_LEN) return;
    const typ = payload[0];
    var src: Ipv4 = undefined;
    @memcpy(&src, src_ip_bytes);

    if (typ == ICMP_ECHO_REQ) {
        sendEchoReply(src, payload);
        return;
    }
    if (typ == ICMP_ECHO_REPLY) {
        const id = rdBe16(payload[4..6]);
        const seq = rdBe16(payload[6..8]);
        if (@atomicLoad(u32, &ping_state.done, .acquire) == 0 and
            ping_state.in_flight and
            ping_state.id == id and
            ping_state.seq == seq and
            std.mem.eql(u8, &src, &ping_state.target))
        {
            const text = std.fmt.bufPrint(&ping_state.reply_text, "{d}.{d}.{d}.{d} seq={d} ({d} bytes)\n", .{ src[0], src[1], src[2], src[3], seq, payload.len }) catch return;
            ping_state.reply_len = @intCast(text.len);
            @atomicStore(u32, &ping_state.done, 1, .release);
        }
    }
}

fn sendEchoReply(dst: Ipv4, request_payload: []const u8) void {
    var scratch: [1500]u8 = undefined;
    if (request_payload.len > scratch.len) return;
    @memcpy(scratch[0..request_payload.len], request_payload);
    scratch[0] = ICMP_ECHO_REPLY;
    scratch[2] = 0;
    scratch[3] = 0;
    const csum = inetChecksum(scratch[0..request_payload.len]);
    wrBe16(scratch[2..4], csum);
    _ = sendIpv4(dst, IP_PROTO_ICMP, scratch[0..request_payload.len]);
}

fn sendEchoRequest(dst: Ipv4, id: u16, seq: u16) bool {
    var pkt: [ICMP_HDR_LEN + 32]u8 = undefined;
    pkt[0] = ICMP_ECHO_REQ;
    pkt[1] = 0;
    wrBe16(pkt[2..4], 0);
    wrBe16(pkt[4..6], id);
    wrBe16(pkt[6..8], seq);
    var i: usize = 8;
    while (i < pkt.len) : (i += 1) pkt[i] = @intCast(i & 0xFF);
    const csum = inetChecksum(&pkt);
    wrBe16(pkt[2..4], csum);
    return sendIpv4(dst, IP_PROTO_ICMP, &pkt);
}

// ---- IPv6 TX ---------------------------------------------------------------

/// NDP requires hop_limit=255 (RFC 4861); 64 for normal data.
fn sendIpv6Raw(src: Ipv6, dst: Ipv6, dst_mac: Mac, next_header: u8, hop_limit: u8, payload: []const u8) bool {
    const total = ETH_HDR_LEN + IPV6_HDR_LEN + payload.len;
    if (total > MAX_FRAME) return false;
    var buf: [MAX_FRAME]u8 = undefined;
    const f = buf[0..total];

    @memcpy(f[0..6], &dst_mac);
    @memcpy(f[6..12], &our_mac);
    wrBe16(f[12..14], ETH_TYPE_IPV6);

    const ip = f[ETH_HDR_LEN..];
    ip[0] = 0x60;
    ip[1] = 0;
    ip[2] = 0;
    ip[3] = 0;
    wrBe16(ip[4..6], @intCast(payload.len));
    ip[6] = next_header;
    ip[7] = hop_limit;
    @memcpy(ip[8..24], &src);
    @memcpy(ip[24..40], &dst);
    @memcpy(ip[40..][0..payload.len], payload);

    sendFrame(f);
    return true;
}

fn sendIpv6(dst: Ipv6, next_header: u8, payload: []const u8) bool {
    if (isMulticast6(dst)) {
        return sendIpv6Raw(our_ip6, dst, ipv6McastMac(dst), next_header, 64, payload);
    }
    const next_hop = if (sameSubnet6(dst, our_ip6, our_prefix6)) dst else our_gw6;
    if (ndpLookup(next_hop)) |m| {
        return sendIpv6Raw(our_ip6, dst, m, next_header, 64, payload);
    }
    sendNdpSolicit(next_hop);
    return false;
}

fn sendNdpSolicit(target: Ipv6) void {
    const sn = solicitedNodeMulticast(target);
    var pkt: [24 + 8]u8 = undefined;
    pkt[0] = ICMPV6_NS;
    pkt[1] = 0;
    wrBe16(pkt[2..4], 0);
    wrBe32(pkt[4..8], 0);
    @memcpy(pkt[8..24], &target);
    pkt[24] = NDP_OPT_SRC_LLA;
    pkt[25] = 1;
    @memcpy(pkt[26..32], &our_mac);

    const csum = ipv6Checksum(our_ip6, sn, IP_PROTO_ICMPV6, &pkt);
    wrBe16(pkt[2..4], csum);

    _ = sendIpv6Raw(our_ip6, sn, ipv6McastMac(sn), IP_PROTO_ICMPV6, 255, &pkt);
}

fn sendNdpAdvert(target_mac: Mac, target_ip: Ipv6) void {
    var pkt: [24 + 8]u8 = undefined;
    pkt[0] = ICMPV6_NA;
    pkt[1] = 0;
    wrBe16(pkt[2..4], 0);
    wrBe32(pkt[4..8], NA_FLAG_SOLICITED | NA_FLAG_OVERRIDE);
    @memcpy(pkt[8..24], &our_ip6);
    pkt[24] = NDP_OPT_TGT_LLA;
    pkt[25] = 1;
    @memcpy(pkt[26..32], &our_mac);

    const csum = ipv6Checksum(our_ip6, target_ip, IP_PROTO_ICMPV6, &pkt);
    wrBe16(pkt[2..4], csum);

    _ = sendIpv6Raw(our_ip6, target_ip, target_mac, IP_PROTO_ICMPV6, 255, &pkt);
}

fn sendEchoReply6(src: Ipv6, request: []const u8) void {
    var scratch: [1500]u8 = undefined;
    if (request.len > scratch.len) return;
    @memcpy(scratch[0..request.len], request);
    scratch[0] = ICMPV6_ECHO_REPLY;
    scratch[2] = 0;
    scratch[3] = 0;
    const csum = ipv6Checksum(our_ip6, src, IP_PROTO_ICMPV6, scratch[0..request.len]);
    wrBe16(scratch[2..4], csum);
    _ = sendIpv6(src, IP_PROTO_ICMPV6, scratch[0..request.len]);
}

fn sendEchoRequest6(dst: Ipv6, id: u16, seq: u16) bool {
    var pkt: [8 + 32]u8 = undefined;
    pkt[0] = ICMPV6_ECHO_REQ;
    pkt[1] = 0;
    wrBe16(pkt[2..4], 0);
    wrBe16(pkt[4..6], id);
    wrBe16(pkt[6..8], seq);
    var i: usize = 8;
    while (i < pkt.len) : (i += 1) pkt[i] = @intCast(i & 0xFF);
    const csum = ipv6Checksum(our_ip6, dst, IP_PROTO_ICMPV6, &pkt);
    wrBe16(pkt[2..4], csum);
    return sendIpv6(dst, IP_PROTO_ICMPV6, &pkt);
}

// ---- UDP TX/RX -------------------------------------------------------------

fn udpChecksum4(src: Ipv4, dst: Ipv4, udp_pkt: []const u8) u16 {
    var sum: u32 = 0;
    sum += (@as(u32, src[0]) << 8) | src[1];
    sum += (@as(u32, src[2]) << 8) | src[3];
    sum += (@as(u32, dst[0]) << 8) | dst[1];
    sum += (@as(u32, dst[2]) << 8) | dst[3];
    sum += @as(u32, IP_PROTO_UDP);
    sum += @as(u32, @intCast(udp_pkt.len));
    var i: usize = 0;
    while (i + 1 < udp_pkt.len) : (i += 2) sum += (@as(u32, udp_pkt[i]) << 8) | udp_pkt[i + 1];
    if (i < udp_pkt.len) sum += @as(u32, udp_pkt[i]) << 8;
    while ((sum >> 16) != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    var c: u16 = @truncate(~sum);
    if (c == 0) c = 0xFFFF; // 0 means "no checksum" in IPv4 UDP.
    return c;
}

fn udpSend4(socket_idx: u8, payload: []const u8) bool {
    if (socket_idx >= UDP_MAX_SOCKETS) return false;
    const s = &udp_sockets[socket_idx];
    if (!s.used or !s.has_remote or s.family != .ipv4) return false;

    // 0.0.0.0 source for limited broadcast, since DHCP sends before we have an addr.
    const src_ip: Ipv4 = if (std.mem.eql(u8, &s.remote.v4, &BROADCAST_IPV4)) ZERO_IPV4 else our_ip;

    var pkt_buf: [UDP_DGRAM_MAX + UDP_HDR_LEN]u8 = undefined;
    if (UDP_HDR_LEN + payload.len > pkt_buf.len) return false;
    const pkt = pkt_buf[0 .. UDP_HDR_LEN + payload.len];
    wrBe16(pkt[0..2], s.local_port);
    wrBe16(pkt[2..4], s.remote.port);
    wrBe16(pkt[4..6], @intCast(pkt.len));
    wrBe16(pkt[6..8], 0);
    @memcpy(pkt[UDP_HDR_LEN..], payload);
    const csum = udpChecksum4(src_ip, s.remote.v4, pkt);
    wrBe16(pkt[6..8], csum);
    return sendIpv4Raw(src_ip, s.remote.v4, IP_PROTO_UDP, pkt);
}

fn udpSend6(socket_idx: u8, payload: []const u8) bool {
    if (socket_idx >= UDP_MAX_SOCKETS) return false;
    const s = &udp_sockets[socket_idx];
    if (!s.used or !s.has_remote or s.family != .ipv6) return false;

    var pkt_buf: [UDP_DGRAM_MAX + UDP_HDR_LEN]u8 = undefined;
    if (UDP_HDR_LEN + payload.len > pkt_buf.len) return false;
    const pkt = pkt_buf[0 .. UDP_HDR_LEN + payload.len];
    wrBe16(pkt[0..2], s.local_port);
    wrBe16(pkt[2..4], s.remote.port);
    wrBe16(pkt[4..6], @intCast(pkt.len));
    wrBe16(pkt[6..8], 0);
    @memcpy(pkt[UDP_HDR_LEN..], payload);
    const csum = ipv6Checksum(our_ip6, s.remote.v6, IP_PROTO_UDP, pkt);
    wrBe16(pkt[6..8], if (csum == 0) 0xFFFF else csum);
    return sendIpv6(s.remote.v6, IP_PROTO_UDP, pkt);
}

// ---- TCP TX/RX -------------------------------------------------------------

fn tcpChecksum4(src: Ipv4, dst: Ipv4, segment: []const u8) u16 {
    var sum: u32 = 0;
    sum += (@as(u32, src[0]) << 8) | src[1];
    sum += (@as(u32, src[2]) << 8) | src[3];
    sum += (@as(u32, dst[0]) << 8) | dst[1];
    sum += (@as(u32, dst[2]) << 8) | dst[3];
    sum += @as(u32, IP_PROTO_TCP);
    sum += @as(u32, @intCast(segment.len));
    var i: usize = 0;
    while (i + 1 < segment.len) : (i += 2) sum += (@as(u32, segment[i]) << 8) | segment[i + 1];
    if (i < segment.len) sum += @as(u32, segment[i]) << 8;
    while ((sum >> 16) != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

fn buildTcpHeader(buf: []u8, src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, win: u16, mss_opt: bool) usize {
    const hdr_len: usize = if (mss_opt) 24 else 20;
    @memset(buf[0..hdr_len], 0);
    wrBe16(buf[0..2], src_port);
    wrBe16(buf[2..4], dst_port);
    wrBe32(buf[4..8], seq);
    wrBe32(buf[8..12], ack);
    buf[12] = @intCast((hdr_len / 4) << 4);
    buf[13] = flags;
    wrBe16(buf[14..16], win);
    if (mss_opt) {
        buf[20] = 2;
        buf[21] = 4;
        wrBe16(buf[22..24], TCP_DEFAULT_MSS);
    }
    return hdr_len;
}

fn sendTcpSegment(sock: *TcpSocket, flags: u8, payload: []const u8) bool {
    var pkt_buf: [TCP_DEFAULT_MSS + 28]u8 = undefined;
    const mss_opt = (flags & TCP_SYN) != 0;
    const hdr_len: usize = if (mss_opt) 24 else 20;
    if (hdr_len + payload.len > pkt_buf.len) return false;
    _ = buildTcpHeader(pkt_buf[0..hdr_len], sock.local_port, sock.remote.port, sock.snd_nxt, sock.rcv_nxt, flags, 65535, mss_opt);
    @memcpy(pkt_buf[hdr_len..][0..payload.len], payload);
    const seg = pkt_buf[0 .. hdr_len + payload.len];

    switch (sock.family) {
        .ipv4 => {
            const csum = tcpChecksum4(our_ip, sock.remote.v4, seg);
            wrBe16(pkt_buf[16..18], csum);
            return sendIpv4(sock.remote.v4, IP_PROTO_TCP, seg);
        },
        .ipv6 => {
            const csum = ipv6Checksum(our_ip6, sock.remote.v6, IP_PROTO_TCP, seg);
            wrBe16(pkt_buf[16..18], csum);
            return sendIpv6(sock.remote.v6, IP_PROTO_TCP, seg);
        },
    }
}

fn deliverTcp(seg: []const u8, src_family: UdpFamily, src_v4: Ipv4, src_v6: Ipv6) void {
    if (seg.len < TCP_HDR_MIN) return;
    const src_port = rdBe16(seg[0..2]);
    const dst_port = rdBe16(seg[2..4]);
    const seq = readBe32(seg[4..8]);
    const ack = readBe32(seg[8..12]);
    const data_off: usize = @as(usize, (seg[12] >> 4)) * 4;
    if (data_off < TCP_HDR_MIN or data_off > seg.len) return;
    const flags = seg[13];
    const payload = seg[data_off..];

    var sock: ?*TcpSocket = null;
    for (&tcp_sockets) |*s| {
        if (!s.used) continue;
        if (s.family != src_family) continue;
        if (s.local_port != dst_port) continue;
        if (!s.has_remote) continue;
        if (s.remote.port != src_port) continue;
        const addr_ok = switch (src_family) {
            .ipv4 => std.mem.eql(u8, &s.remote.v4, &src_v4),
            .ipv6 => std.mem.eql(u8, &s.remote.v6, &src_v6),
        };
        if (!addr_ok) continue;
        sock = s;
        break;
    }
    const s = sock orelse blk: {
        if ((flags & TCP_SYN) != 0 and (flags & TCP_ACK) == 0) {
            if (acceptIncomingSyn(src_family, src_v4, src_v6, src_port, dst_port, seq)) |child| {
                break :blk child;
            }
        }
        if ((flags & TCP_RST) == 0) sendReset(src_family, src_v4, src_v6, src_port, dst_port, seq, ack, flags);
        return;
    };

    tcpInput(s, seq, ack, flags, payload);
}

fn acceptIncomingSyn(
    family: UdpFamily,
    src_v4: Ipv4,
    src_v6: Ipv6,
    src_port: u16,
    dst_port: u16,
    peer_seq: u32,
) ?*TcpSocket {
    var listener_idx: ?u8 = null;
    for (&tcp_sockets, 0..) |*s, i| {
        if (!s.used or !s.is_listener) continue;
        if (s.local_port != dst_port) continue;
        if (s.family != family) continue;
        listener_idx = @intCast(i);
        break;
    }
    const li = listener_idx orelse return null;
    const listener = &tcp_sockets[li];
    if (listener.accept_count >= TCP_ACCEPT_BACKLOG) return null;

    const child_idx = tcpAlloc(family) orelse return null;
    const child = &tcp_sockets[child_idx];
    child.local_port = dst_port;
    child.remote = switch (family) {
        .ipv4 => .{ .family = .ipv4, .v4 = src_v4, .port = src_port },
        .ipv6 => .{ .family = .ipv6, .v6 = src_v6, .port = src_port },
    };
    child.has_remote = true;
    child.rcv_nxt = peer_seq +% 1;
    child.snd_nxt = 0;
    child.snd_una = 0;
    child.state = .syn_received;
    child.parent_listener = li;

    _ = sendTcpSegment(child, TCP_SYN | TCP_ACK, &.{});
    child.snd_nxt = 1; // SYN consumes one sequence number.
    return child;
}

fn sendReset(family: UdpFamily, v4: Ipv4, v6: Ipv6, src_port: u16, dst_port: u16, peer_seq: u32, peer_ack: u32, peer_flags: u8) void {
    var pkt_buf: [28]u8 = undefined;
    const hdr_len: usize = 20;
    var seq: u32 = 0;
    var ack: u32 = 0;
    var flags: u8 = TCP_RST;
    if ((peer_flags & TCP_ACK) != 0) {
        seq = peer_ack;
    } else {
        ack = peer_seq +% segLen(peer_flags, 0);
        flags |= TCP_ACK;
    }
    _ = buildTcpHeader(pkt_buf[0..hdr_len], dst_port, src_port, seq, ack, flags, 0, false);
    const seg = pkt_buf[0..hdr_len];

    switch (family) {
        .ipv4 => {
            const csum = tcpChecksum4(our_ip, v4, seg);
            wrBe16(pkt_buf[16..18], csum);
            _ = sendIpv4(v4, IP_PROTO_TCP, seg);
        },
        .ipv6 => {
            const csum = ipv6Checksum(our_ip6, v6, IP_PROTO_TCP, seg);
            wrBe16(pkt_buf[16..18], csum);
            _ = sendIpv6(v6, IP_PROTO_TCP, seg);
        },
    }
}

inline fn segLen(flags: u8, payload_len: usize) u32 {
    var n: u32 = @intCast(payload_len);
    if ((flags & TCP_SYN) != 0) n += 1;
    if ((flags & TCP_FIN) != 0) n += 1;
    return n;
}

inline fn readBe32(b: *const [4]u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | @as(u32, b[3]);
}

fn tcpInput(s: *TcpSocket, seq: u32, ack: u32, flags: u8, payload: []const u8) void {
    if ((flags & TCP_RST) != 0) {
        s.state = .closed;
        return;
    }

    switch (s.state) {
        .syn_received => {
            if ((flags & TCP_ACK) != 0 and ack == s.snd_nxt) {
                s.snd_una = ack;
                s.state = .established;
                if (s.parent_listener != NO_PARENT and s.parent_listener < TCP_MAX_SOCKETS) {
                    const lp = &tcp_sockets[s.parent_listener];
                    if (lp.used and lp.is_listener and lp.accept_count < TCP_ACCEPT_BACKLOG) {
                        const slot = (lp.accept_head + lp.accept_count) % TCP_ACCEPT_BACKLOG;
                        var self_idx: u8 = 0;
                        for (&tcp_sockets, 0..) |*ts, i| {
                            if (ts == s) {
                                self_idx = @intCast(i);
                                break;
                            }
                        }
                        lp.accept_queue[slot] = self_idx;
                        lp.accept_count += 1;
                        wakeBlockedAcceptor(lp);
                    }
                }
                if (payload.len > 0) {
                    appendRecv(s, payload);
                    s.rcv_nxt = s.rcv_nxt +% @as(u32, @intCast(payload.len));
                    _ = sendTcpSegment(s, TCP_ACK, &.{});
                }
            }
        },
        .syn_sent => {
            if ((flags & (TCP_SYN | TCP_ACK)) == (TCP_SYN | TCP_ACK)) {
                if (ack != s.snd_nxt) return;
                s.snd_una = ack;
                s.rcv_nxt = seq +% 1;
                s.state = .established;
                _ = sendTcpSegment(s, TCP_ACK, &.{});
            } else if ((flags & TCP_SYN) != 0) {
                // Simultaneous open is not supported.
                s.state = .closed;
            }
        },
        .established, .fin_wait_1, .fin_wait_2, .close_wait => {
            if (seq != s.rcv_nxt) {
                _ = sendTcpSegment(s, TCP_ACK, &.{});
                return;
            }
            if ((flags & TCP_ACK) != 0) {
                if (cmpSeq(ack, s.snd_una) >= 0 and cmpSeq(ack, s.snd_nxt) <= 0) {
                    s.snd_una = ack;
                    s.send_buf_acked = ackedTotal(s);
                }
                if (s.state == .fin_wait_1 and ack == s.snd_nxt) s.state = .fin_wait_2;
            }
            if (payload.len > 0 and (s.state == .established or s.state == .fin_wait_1 or s.state == .fin_wait_2)) {
                appendRecv(s, payload);
                s.rcv_nxt = s.rcv_nxt +% @as(u32, @intCast(payload.len));
                _ = sendTcpSegment(s, TCP_ACK, &.{});
            }
            if ((flags & TCP_FIN) != 0) {
                s.rcv_nxt +%= 1;
                _ = sendTcpSegment(s, TCP_ACK, &.{});
                s.state = switch (s.state) {
                    .established => .close_wait,
                    .fin_wait_1 => .closing,
                    .fin_wait_2 => .time_wait,
                    else => s.state,
                };
            }
        },
        .last_ack => {
            if ((flags & TCP_ACK) != 0 and ack == s.snd_nxt) {
                s.state = .closed;
            }
        },
        else => {},
    }
}

fn cmpSeq(a: u32, b: u32) i32 {
    const diff: i32 = @bitCast(a -% b);
    if (diff > 0) return 1;
    if (diff < 0) return -1;
    return 0;
}

fn ackedTotal(s: *const TcpSocket) usize {
    // ISN is 0 (not randomized), so snd_una directly counts acked bytes.
    return s.snd_una;
}

fn appendRecv(s: *TcpSocket, data: []const u8) void {
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        const next = (s.recv_w + 1) % s.recv_buf.len;
        if (next == s.recv_r) break;
        s.recv_buf[s.recv_w] = data[i];
        s.recv_w = next;
    }
}

fn deliverUdp4(src_ip: Ipv4, src_port: u16, dst_port: u16, payload: []const u8) void {
    for (&udp_sockets) |*s| {
        if (!s.used or s.family != .ipv4 or s.local_port != dst_port) continue;
        if (s.has_remote) {
            if (s.remote.port != src_port) continue;
            // 255.255.255.255 = wildcard so DHCP clients accept any unicast reply.
            const wildcard = std.mem.eql(u8, &s.remote.v4, &BROADCAST_IPV4);
            if (!wildcard and !std.mem.eql(u8, &s.remote.v4, &src_ip)) continue;
        }
        udpPushIncoming(s, payload);
        return;
    }
}

fn deliverUdp6(src_ip: Ipv6, src_port: u16, dst_port: u16, payload: []const u8) void {
    for (&udp_sockets) |*s| {
        if (!s.used or s.family != .ipv6 or s.local_port != dst_port) continue;
        if (s.has_remote and
            (s.remote.port != src_port or !std.mem.eql(u8, &s.remote.v6, &src_ip))) continue;
        udpPushIncoming(s, payload);
        return;
    }
}

// ---- RX thread -------------------------------------------------------------

// Match main-thread stack: each fs handler can park 32+ KB for p9 req/resp.
const RX_STACK_PAGES: usize = 256;
var rx_frame_buf: [2048]u8 = undefined;

fn rxThread() callconv(.c) noreturn {
    while (true) {
        // /dev/eth0 is async; this read blocks until a frame arrives.
        const n = eth0.read(0, &rx_frame_buf) catch {
            ferrite.nanosleep(10_000_000);
            continue;
        };
        if (n == 0) continue;
        if (n < ETH_HDR_LEN) continue;
        const f = rx_frame_buf[0..n];
        const eth_type = rdBe16(f[12..14]);
        if (trace_packets) {
            ferrite.console.print("[rx] type=0x{x:0>4} len={d} src={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}\n", .{
                eth_type, n, f[6], f[7], f[8], f[9], f[10], f[11],
            }) catch {};
        }
        switch (eth_type) {
            ETH_TYPE_ARP => handleArp(f),
            ETH_TYPE_IPV4 => handleIpv4(f),
            ETH_TYPE_IPV6 => handleIpv6(f),
            else => {},
        }
    }
}

fn startRxThread() bool {
    var stack_va: usize = 0;
    if (ferrite.allocPages(RX_STACK_PAGES, &stack_va) != 0) return false;
    const stack_top = stack_va + RX_STACK_PAGES * ferrite.pageSize() - 16;
    const h = ferrite.threadSpawn(@intFromPtr(&rxThread), stack_top);
    return h >= 0;
}

// ARP/NDP warmup + DNS pre-resolution. Runs on its own thread so it does NOT
// gate fs.register/mount: under TCG these round-trips are slow, and doing them
// before registration delayed /sys/net past svc.dhcp's deadline. Seeding the
// gateway MAC + serving /sys/net happen first (in main); this just primes the
// caches concurrently with fs.serve. sendFrame is re-entrant-safe (see its note).
const WARMUP_STACK_PAGES: usize = 16;

fn warmupThread() callconv(.c) noreturn {
    var pre: u32 = 0;
    while (pre < 4) : (pre += 1) {
        sendArpRequest(our_gw);
        if (!std.mem.eql(u8, &our_ip6, &ZERO_IPV6)) sendNdpSolicit(our_gw6);
        var y: u32 = 0;
        while (y < 32) : (y += 1) ferrite.yield();
    }
    preResolveDns();
    // No per-thread exit syscall; park (matches rxThread's forever-loop model).
    while (true) ferrite.nanosleep(1_000_000_000);
}

fn startWarmupThread() bool {
    var stack_va: usize = 0;
    if (ferrite.allocPages(WARMUP_STACK_PAGES, &stack_va) != 0) return false;
    const stack_top = stack_va + WARMUP_STACK_PAGES * ferrite.pageSize() - 16;
    const h = ferrite.threadSpawn(@intFromPtr(&warmupThread), stack_top);
    return h >= 0;
}

// ---- Config parsing --------------------------------------------------------

fn loadConfig() bool {
    var buf: [512]u8 = undefined;
    const n = ferrite.readInitrdFile(CONFIG_PATH, &buf);
    if (n == 0) {
        ferrite.console.print("[svc.net] {s} missing\n", .{CONFIG_PATH}) catch {};
        return false;
    }
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |raw| {
        const line = stripComment(raw);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var tok = std.mem.tokenizeAny(u8, trimmed, " \t");
        const iface = tok.next() orelse continue;
        if (!std.mem.eql(u8, iface, "eth0")) continue;
        const family = tok.next() orelse continue;
        const addr_pre = tok.next() orelse continue;
        const slash = std.mem.indexOfScalar(u8, addr_pre, '/') orelse continue;
        const prefix = std.fmt.parseInt(u8, addr_pre[slash + 1 ..], 10) catch continue;
        if (std.mem.eql(u8, family, "inet")) {
            const ip = parseIpv4(addr_pre[0..slash]) orelse continue;
            our_ip = ip;
            our_prefix = prefix;
            const gw_kw = tok.next() orelse continue;
            if (!std.mem.eql(u8, gw_kw, "gw")) continue;
            const gw_str = tok.next() orelse continue;
            our_gw = parseIpv4(gw_str) orelse continue;
        } else if (std.mem.eql(u8, family, "inet6")) {
            const ip = parseIpv6(addr_pre[0..slash]) orelse continue;
            our_ip6 = ip;
            our_prefix6 = prefix;
            const gw_kw = tok.next() orelse continue;
            if (!std.mem.eql(u8, gw_kw, "gw")) continue;
            const gw_str = tok.next() orelse continue;
            our_gw6 = parseIpv6(gw_str) orelse continue;
        }
    }
    return ipToU32(our_ip) != 0;
}

fn stripComment(line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, '#')) |i| return line[0..i];
    return line;
}

fn parseIpv4(s: []const u8) ?Ipv4 {
    var out: Ipv4 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= 4) return null;
        out[i] = std.fmt.parseInt(u8, part, 10) catch return null;
        i += 1;
    }
    if (i != 4) return null;
    return out;
}

fn parseIpv6(s: []const u8) ?Ipv6 {
    const a = std.Io.net.Ip6Address.parse(s, 0) catch return null;
    return a.bytes;
}

fn formatIpv6Into(buf: []u8, addr: Ipv6) []const u8 {
    const u: std.Io.net.Ip6Address.Unresolved = .{ .bytes = addr, .interface_name = null };
    return std.fmt.bufPrint(buf, "{f}", .{&u}) catch buf[0..0];
}

// ---- /net fs surface -------------------------------------------------------

const FidKind = enum { root, eth0, leaf, udp_root, udp_sock, udp_leaf, tcp_root, tcp_sock, tcp_leaf };
const Leaf = enum {
    mac,
    addr,
    gw,
    neigh,
    addr6,
    gw6,
    neigh6,
    icmp4,
    icmp6,
    udp_clone,
    udp_ctl,
    udp_data,
    udp_local,
    udp_remote,
    tcp_clone,
    tcp_ctl,
    tcp_data,
    tcp_local,
    tcp_remote,
    tcp_status,
    tcp_accept,
};

const Fid = struct {
    used: bool = false,
    opened: bool = false,
    kind: FidKind = .root,
    leaf: Leaf = .mac,
    sock_idx: u8 = 0,
    clone_returned: bool = false,
};

const MAX_FIDS = 16;
const State = struct {
    fids: [MAX_FIDS]Fid = @splat(.{}),
};
var state: State = .{};

const Resolved = union(enum) {
    root,
    eth0,
    leaf: Leaf,
    udp_root,
    udp_clone,
    udp_sock: u8,
    udp_leaf: struct { sock_idx: u8, leaf: Leaf },
    tcp_root,
    tcp_clone,
    tcp_sock: u8,
    tcp_leaf: struct { sock_idx: u8, leaf: Leaf },
};

fn resolvePath(path: []const u8) ?Resolved {
    var p = path;
    while (p.len > 0 and p[0] == '/') p = p[1..];
    while (p.len > 0 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    if (p.len == 0) return .root;
    if (std.mem.eql(u8, p, "icmp4")) return .{ .leaf = .icmp4 };
    if (std.mem.eql(u8, p, "icmp6")) return .{ .leaf = .icmp6 };
    if (std.mem.eql(u8, p, "eth0")) return .eth0;
    if (std.mem.startsWith(u8, p, "eth0/")) {
        const sub = p["eth0/".len..];
        if (std.mem.eql(u8, sub, "mac")) return .{ .leaf = .mac };
        if (std.mem.eql(u8, sub, "addr")) return .{ .leaf = .addr };
        if (std.mem.eql(u8, sub, "gw")) return .{ .leaf = .gw };
        if (std.mem.eql(u8, sub, "neigh")) return .{ .leaf = .neigh };
        if (std.mem.eql(u8, sub, "addr6")) return .{ .leaf = .addr6 };
        if (std.mem.eql(u8, sub, "gw6")) return .{ .leaf = .gw6 };
        if (std.mem.eql(u8, sub, "neigh6")) return .{ .leaf = .neigh6 };
    }
    if (std.mem.eql(u8, p, "udp")) return .udp_root;
    if (std.mem.eql(u8, p, "udp/clone")) return .udp_clone;
    if (std.mem.startsWith(u8, p, "udp/")) {
        const tail = p["udp/".len..];
        const slash = std.mem.indexOfScalar(u8, tail, '/');
        const num_s = if (slash) |i| tail[0..i] else tail;
        const sub = if (slash) |i| tail[i + 1 ..] else "";
        const idx = std.fmt.parseInt(u8, num_s, 10) catch return null;
        if (idx >= UDP_MAX_SOCKETS or !udp_sockets[idx].used) return null;
        if (sub.len == 0) return .{ .udp_sock = idx };
        if (std.mem.eql(u8, sub, "ctl")) return .{ .udp_leaf = .{ .sock_idx = idx, .leaf = .udp_ctl } };
        if (std.mem.eql(u8, sub, "data")) return .{ .udp_leaf = .{ .sock_idx = idx, .leaf = .udp_data } };
        if (std.mem.eql(u8, sub, "local")) return .{ .udp_leaf = .{ .sock_idx = idx, .leaf = .udp_local } };
        if (std.mem.eql(u8, sub, "remote")) return .{ .udp_leaf = .{ .sock_idx = idx, .leaf = .udp_remote } };
    }
    if (std.mem.eql(u8, p, "tcp")) return .tcp_root;
    if (std.mem.eql(u8, p, "tcp/clone")) return .tcp_clone;
    if (std.mem.startsWith(u8, p, "tcp/")) {
        const tail = p["tcp/".len..];
        const slash = std.mem.indexOfScalar(u8, tail, '/');
        const num_s = if (slash) |i| tail[0..i] else tail;
        const sub = if (slash) |i| tail[i + 1 ..] else "";
        const idx = std.fmt.parseInt(u8, num_s, 10) catch return null;
        if (idx >= TCP_MAX_SOCKETS or !tcp_sockets[idx].used) return null;
        if (sub.len == 0) return .{ .tcp_sock = idx };
        if (std.mem.eql(u8, sub, "ctl")) return .{ .tcp_leaf = .{ .sock_idx = idx, .leaf = .tcp_ctl } };
        if (std.mem.eql(u8, sub, "data")) return .{ .tcp_leaf = .{ .sock_idx = idx, .leaf = .tcp_data } };
        if (std.mem.eql(u8, sub, "local")) return .{ .tcp_leaf = .{ .sock_idx = idx, .leaf = .tcp_local } };
        if (std.mem.eql(u8, sub, "remote")) return .{ .tcp_leaf = .{ .sock_idx = idx, .leaf = .tcp_remote } };
        if (std.mem.eql(u8, sub, "status")) return .{ .tcp_leaf = .{ .sock_idx = idx, .leaf = .tcp_status } };
        if (std.mem.eql(u8, sub, "accept")) return .{ .tcp_leaf = .{ .sock_idx = idx, .leaf = .tcp_accept } };
    }
    return null;
}

fn onWalk(s: *State, fid: u32, path: []const u8) fs.HandlerError!fs.WalkResult {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    var buf: [64]u8 = undefined;
    var n: usize = 0;

    switch (s.fids[fid].kind) {
        .root => {},
        .eth0 => {
            const base = "eth0";
            @memcpy(buf[0..base.len], base);
            n = base.len;
        },
        .udp_root => {
            const base = "udp";
            @memcpy(buf[0..base.len], base);
            n = base.len;
        },
        .udp_sock => {
            const piece = std.fmt.bufPrint(&buf, "udp/{d}", .{s.fids[fid].sock_idx}) catch return error.NotFound;
            n = piece.len;
        },
        .tcp_root => {
            const base = "tcp";
            @memcpy(buf[0..base.len], base);
            n = base.len;
        },
        .tcp_sock => {
            const piece = std.fmt.bufPrint(&buf, "tcp/{d}", .{s.fids[fid].sock_idx}) catch return error.NotFound;
            n = piece.len;
        },
        else => {},
    }

    if (path.len > 0) {
        if (n > 0) {
            if (n + 1 > buf.len) return error.NotFound;
            buf[n] = '/';
            n += 1;
        }
        if (n + path.len > buf.len) return error.NotFound;
        @memcpy(buf[n..][0..path.len], path);
        n += path.len;
    }

    const resolved = resolvePath(buf[0..n]) orelse return error.NotFound;

    var sock_for_clone: u8 = 0;
    switch (resolved) {
        .udp_clone => sock_for_clone = udpAlloc(.ipv4) orelse return error.ServerBusy,
        .tcp_clone => sock_for_clone = tcpAlloc(.ipv4) orelse return error.ServerBusy,
        else => {},
    }

    var i: u32 = 1;
    while (i < MAX_FIDS) : (i += 1) {
        if (!s.fids[i].used) {
            s.fids[i] = .{ .used = true };
            switch (resolved) {
                .root => s.fids[i].kind = .root,
                .eth0 => s.fids[i].kind = .eth0,
                .leaf => |l| {
                    s.fids[i].kind = .leaf;
                    s.fids[i].leaf = l;
                },
                .udp_root => s.fids[i].kind = .udp_root,
                .udp_clone => {
                    s.fids[i].kind = .udp_leaf;
                    s.fids[i].leaf = .udp_clone;
                    s.fids[i].sock_idx = sock_for_clone;
                },
                .udp_sock => |idx| {
                    s.fids[i].kind = .udp_sock;
                    s.fids[i].sock_idx = idx;
                },
                .udp_leaf => |spec| {
                    s.fids[i].kind = .udp_leaf;
                    s.fids[i].leaf = spec.leaf;
                    s.fids[i].sock_idx = spec.sock_idx;
                },
                .tcp_root => s.fids[i].kind = .tcp_root,
                .tcp_clone => {
                    s.fids[i].kind = .tcp_leaf;
                    s.fids[i].leaf = .tcp_clone;
                    s.fids[i].sock_idx = sock_for_clone;
                },
                .tcp_sock => |idx| {
                    s.fids[i].kind = .tcp_sock;
                    s.fids[i].sock_idx = idx;
                },
                .tcp_leaf => |spec| {
                    s.fids[i].kind = .tcp_leaf;
                    s.fids[i].leaf = spec.leaf;
                    s.fids[i].sock_idx = spec.sock_idx;
                },
            }
            return .{ .bound = i };
        }
    }
    return error.ServerBusy;
}

fn onOpen(s: *State, fid: u32, _: p9.Mode) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    s.fids[fid].opened = true;

    if (s.fids[fid].kind == .leaf) switch (s.fids[fid].leaf) {
        .icmp4 => {
            ping_state.in_flight = false;
            @atomicStore(u32, &ping_state.done, 0, .release);
        },
        .icmp6 => {
            ping6_state.in_flight = false;
            @atomicStore(u32, &ping6_state.done, 0, .release);
        },
        else => {},
    };
}

// Single static buf: onReadAsync runs on fs.serve and the slice is consumed
// by encode-and-send before this returns.
var accept_reply_buf: [16]u8 = undefined;

fn dequeueAcceptText(sock: *TcpSocket, dst: []u8) []const u8 {
    if (sock.accept_count == 0) return dst[0..0];
    const idx = sock.accept_queue[sock.accept_head];
    sock.accept_head = @intCast((sock.accept_head + 1) % TCP_ACCEPT_BACKLOG);
    sock.accept_count -= 1;
    return std.fmt.bufPrint(dst, "{d}\n", .{idx}) catch dst[0..0];
}

/// Blocking-accept path; everything else returns .fall_through.
fn onReadAsync(s: *State, pending: fs.PendingRead) fs.HandlerError!fs.ReadOutcome {
    if (pending.fid >= MAX_FIDS) return error.BadFid;
    const f = &s.fids[pending.fid];
    if (!f.used or !f.opened) return error.BadFid;
    if (f.kind != .tcp_leaf or f.leaf != .tcp_accept) return .fall_through;
    if (pending.offset != 0) return .{ .immediate = "" };
    if (f.sock_idx >= TCP_MAX_SOCKETS) return error.BadFid;
    const sock = &tcp_sockets[f.sock_idx];
    if (!sock.used or !sock.is_listener) return error.BadOp;

    if (sock.accept_count > 0) {
        const text = dequeueAcceptText(sock, &accept_reply_buf);
        return .{ .immediate = text };
    }

    // One blocking reader per listener.
    if (@atomicLoad(u32, &sock.pending_reply_cap, .acquire) != 0) {
        return .{ .immediate = "" };
    }

    // Stash, then re-check to close the SYN-arrived-just-now race with rxThread.
    sock.pending_tag = pending.tag;
    @atomicStore(u32, &sock.pending_reply_cap, pending.reply_cap, .release);

    if (sock.accept_count > 0) {
        const claimed = @atomicRmw(u32, &sock.pending_reply_cap, .Xchg, @as(u32, 0), .acquire);
        if (claimed != 0) {
            const text = dequeueAcceptText(sock, &accept_reply_buf);
            const p = fs.PendingRead{
                .reply_cap = claimed,
                .tag = sock.pending_tag,
                .fid = pending.fid,
                .offset = 0,
                .want = 0,
            };
            p.respondRead(text);
        }
    }
    return .deferred;
}

/// rxThread wake; races onReadAsync's stash via Xchg. Exactly one wins.
fn wakeBlockedAcceptor(listener: *TcpSocket) void {
    const cap = @atomicRmw(u32, &listener.pending_reply_cap, .Xchg, @as(u32, 0), .acquire);
    if (cap == 0) return;
    var buf: [16]u8 = undefined;
    const text = dequeueAcceptText(listener, &buf);
    const p = fs.PendingRead{
        .reply_cap = cap,
        .tag = listener.pending_tag,
        .fid = 0,
        .offset = 0,
        .want = 0,
    };
    p.respondRead(text);
}

fn onRead(s: *State, fid: u32, offset: u64, out: []u8) fs.HandlerError!usize {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    switch (s.fids[fid].kind) {
        .root => return listRoot(offset, out),
        .eth0 => return listEth0(offset, out),
        .udp_root => return listUdpRoot(offset, out),
        .udp_sock => return listUdpSockDir(offset, out),
        .tcp_root => return listTcpRoot(offset, out),
        .tcp_sock => return listTcpSockDir(offset, out),
        .leaf => return switch (s.fids[fid].leaf) {
            .mac => readText(offset, out, formatMac()),
            .addr => readText(offset, out, formatAddr()),
            .gw => readText(offset, out, formatGw()),
            .neigh => readText(offset, out, formatNeigh()),
            .addr6 => readText(offset, out, formatAddr6()),
            .gw6 => readText(offset, out, formatGw6()),
            .neigh6 => readText(offset, out, formatNeigh6()),
            .icmp4 => readPingReply(offset, out),
            .icmp6 => readPing6Reply(offset, out),
            else => return error.BadOp,
        },
        .udp_leaf => return readUdpLeaf(&s.fids[fid], offset, out),
        .tcp_leaf => return readTcpLeaf(&s.fids[fid], offset, out),
    }
}

fn listRoot(offset: u64, out: []u8) fs.HandlerError!usize {
    const text = "eth0\nicmp4\nicmp6\nudp\ntcp\n";
    return readText(offset, out, text);
}

fn listEth0(offset: u64, out: []u8) fs.HandlerError!usize {
    const text = "mac\naddr\ngw\nneigh\naddr6\ngw6\nneigh6\n";
    return readText(offset, out, text);
}

fn listUdpRoot(offset: u64, out: []u8) fs.HandlerError!usize {
    var buf: [256]u8 = undefined;
    var w: usize = 0;
    const hdr = "clone\n";
    @memcpy(buf[w..][0..hdr.len], hdr);
    w += hdr.len;
    for (&udp_sockets, 0..) |*sock, idx| {
        if (!sock.used) continue;
        const line = std.fmt.bufPrint(buf[w..], "{d}\n", .{idx}) catch break;
        w += line.len;
    }
    return readText(offset, out, buf[0..w]);
}

fn listUdpSockDir(offset: u64, out: []u8) fs.HandlerError!usize {
    const text = "ctl\ndata\nlocal\nremote\n";
    return readText(offset, out, text);
}

fn listTcpRoot(offset: u64, out: []u8) fs.HandlerError!usize {
    var buf: [256]u8 = undefined;
    var w: usize = 0;
    const hdr = "clone\n";
    @memcpy(buf[w..][0..hdr.len], hdr);
    w += hdr.len;
    for (&tcp_sockets, 0..) |*sock, idx| {
        if (!sock.used) continue;
        const line = std.fmt.bufPrint(buf[w..], "{d}\n", .{idx}) catch break;
        w += line.len;
    }
    return readText(offset, out, buf[0..w]);
}

fn listTcpSockDir(offset: u64, out: []u8) fs.HandlerError!usize {
    const text = "ctl\ndata\nlocal\nremote\nstatus\n";
    return readText(offset, out, text);
}

var text_buf: [512]u8 = undefined;

fn formatMac() []const u8 {
    return std.fmt.bufPrint(&text_buf, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}\n", .{
        our_mac[0], our_mac[1], our_mac[2], our_mac[3], our_mac[4], our_mac[5],
    }) catch return text_buf[0..0];
}

fn formatAddr() []const u8 {
    return std.fmt.bufPrint(&text_buf, "{d}.{d}.{d}.{d}/{d}\n", .{ our_ip[0], our_ip[1], our_ip[2], our_ip[3], our_prefix }) catch return text_buf[0..0];
}

fn formatGw() []const u8 {
    return std.fmt.bufPrint(&text_buf, "{d}.{d}.{d}.{d}\n", .{ our_gw[0], our_gw[1], our_gw[2], our_gw[3] }) catch return text_buf[0..0];
}

fn formatNeigh() []const u8 {
    var w: usize = 0;
    for (&arp_cache) |*e| {
        if (!e.valid) continue;
        const line = std.fmt.bufPrint(text_buf[w..], "{d}.{d}.{d}.{d} {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}\n", .{
            e.ip[0], e.ip[1], e.ip[2], e.ip[3], e.mac[0], e.mac[1], e.mac[2], e.mac[3], e.mac[4], e.mac[5],
        }) catch break;
        w += line.len;
    }
    return text_buf[0..w];
}

fn formatAddr6() []const u8 {
    var tmp: [64]u8 = undefined;
    const a = formatIpv6Into(&tmp, our_ip6);
    return std.fmt.bufPrint(&text_buf, "{s}/{d}\n", .{ a, our_prefix6 }) catch text_buf[0..0];
}

fn formatGw6() []const u8 {
    var tmp: [64]u8 = undefined;
    const a = formatIpv6Into(&tmp, our_gw6);
    return std.fmt.bufPrint(&text_buf, "{s}\n", .{a}) catch text_buf[0..0];
}

fn formatNeigh6() []const u8 {
    var w: usize = 0;
    var tmp: [64]u8 = undefined;
    for (&ndp_cache) |*e| {
        if (!e.valid) continue;
        const addr_s = formatIpv6Into(&tmp, e.ip);
        const line = std.fmt.bufPrint(text_buf[w..], "{s} {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}\n", .{
            addr_s, e.mac[0], e.mac[1], e.mac[2], e.mac[3], e.mac[4], e.mac[5],
        }) catch break;
        w += line.len;
    }
    return text_buf[0..w];
}

fn readUdpLeaf(f: *Fid, offset: u64, out: []u8) fs.HandlerError!usize {
    if (f.sock_idx >= UDP_MAX_SOCKETS) return error.BadFid;
    const sock = &udp_sockets[f.sock_idx];
    if (!sock.used) return error.BadFid;
    switch (f.leaf) {
        .udp_clone => {
            if (f.clone_returned) return 0;
            var buf: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}\n", .{f.sock_idx}) catch return error.BadOp;
            if (offset >= text.len) return 0;
            const start: usize = @intCast(offset);
            const n = @min(text.len - start, out.len);
            @memcpy(out[0..n], text[start..][0..n]);
            if (offset + n >= text.len) f.clone_returned = true;
            return n;
        },
        .udp_data => {
            // One read = one datagram. 3s timeout, then caller retries.
            const deadline = ferrite.clockMono() + 3 * std.time.ns_per_s;
            while (sock.recv_r == sock.recv_w) {
                if (ferrite.clockMono() > deadline) return 0;
                ferrite.yield();
            }
            return udpPopOutgoing(sock, out);
        },
        .udp_ctl => return readText(offset, out, formatUdpCtl(sock)),
        .udp_local => return readText(offset, out, formatUdpLocal(sock)),
        .udp_remote => return readText(offset, out, formatUdpRemote(sock)),
        else => return error.BadOp,
    }
}

fn readTcpLeaf(f: *Fid, offset: u64, out: []u8) fs.HandlerError!usize {
    if (f.sock_idx >= TCP_MAX_SOCKETS) return error.BadFid;
    const sock = &tcp_sockets[f.sock_idx];
    if (!sock.used) return error.BadFid;
    switch (f.leaf) {
        .tcp_clone => {
            if (f.clone_returned) return 0;
            var buf: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}\n", .{f.sock_idx}) catch return error.BadOp;
            if (offset >= text.len) return 0;
            const start: usize = @intCast(offset);
            const n = @min(text.len - start, out.len);
            @memcpy(out[0..n], text[start..][0..n]);
            if (offset + n >= text.len) f.clone_returned = true;
            return n;
        },
        .tcp_data => {
            const deadline = ferrite.clockMono() + 5 * std.time.ns_per_s;
            while (sock.recv_r == sock.recv_w) {
                if (sock.state == .closed or sock.state == .close_wait or sock.state == .time_wait or sock.state == .last_ack) {
                    return 0;
                }
                if (ferrite.clockMono() > deadline) return 0;
                ferrite.yield();
            }
            var n: usize = 0;
            while (n < out.len and sock.recv_r != sock.recv_w) : (n += 1) {
                out[n] = sock.recv_buf[sock.recv_r];
                sock.recv_r = (sock.recv_r + 1) % sock.recv_buf.len;
            }
            return n;
        },
        .tcp_ctl, .tcp_local, .tcp_remote, .tcp_status => return readText(offset, out, formatTcpLeaf(sock, f.leaf)),
        .tcp_accept => {
            // Non-blocking. "{idx}\n" on offset 0 if queued; else 0.
            // Caller closes+reopens to fetch the next connection.
            if (!sock.is_listener) return error.BadOp;
            if (offset != 0) return 0;
            if (sock.accept_count == 0) return 0;
            const idx = sock.accept_queue[sock.accept_head];
            sock.accept_head = @intCast((sock.accept_head + 1) % TCP_ACCEPT_BACKLOG);
            sock.accept_count -= 1;
            return readText(0, out, std.fmt.bufPrint(&tcp_text_buf, "{d}\n", .{idx}) catch tcp_text_buf[0..0]);
        },
        else => return error.BadOp,
    }
}

var tcp_text_buf: [256]u8 = undefined;

fn formatTcpLeaf(sock: *const TcpSocket, leaf: Leaf) []const u8 {
    return switch (leaf) {
        .tcp_status => std.fmt.bufPrint(&tcp_text_buf, "{s}\n", .{@tagName(sock.state)}) catch tcp_text_buf[0..0],
        .tcp_local => formatTcpEndpoint(&tcp_text_buf, sock.family, true, sock),
        .tcp_remote => if (sock.has_remote) formatTcpEndpoint(&tcp_text_buf, sock.family, false, sock) else tcp_text_buf[0..0],
        .tcp_ctl => std.fmt.bufPrint(&tcp_text_buf, "state={s} snd_nxt={d} snd_una={d} rcv_nxt={d}\n", .{
            @tagName(sock.state), sock.snd_nxt, sock.snd_una, sock.rcv_nxt,
        }) catch tcp_text_buf[0..0],
        else => tcp_text_buf[0..0],
    };
}

fn formatTcpEndpoint(buf: []u8, family: UdpFamily, local: bool, sock: *const TcpSocket) []const u8 {
    if (family == .ipv6) {
        var tmp: [64]u8 = undefined;
        const addr = if (local) our_ip6 else sock.remote.v6;
        const port: u16 = if (local) sock.local_port else sock.remote.port;
        const a = formatIpv6Into(&tmp, addr);
        return std.fmt.bufPrint(buf, "[{s}]!{d}\n", .{ a, port }) catch buf[0..0];
    }
    const addr: Ipv4 = if (local) our_ip else sock.remote.v4;
    const port: u16 = if (local) sock.local_port else sock.remote.port;
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}!{d}\n", .{ addr[0], addr[1], addr[2], addr[3], port }) catch buf[0..0];
}

var udp_text_buf: [256]u8 = undefined;

fn formatUdpCtl(sock: *const UdpSocket) []const u8 {
    const fam = @tagName(sock.family);
    return std.fmt.bufPrint(&udp_text_buf, "family={s} local_port={d} connected={d}\n", .{
        fam, sock.local_port, @intFromBool(sock.has_remote),
    }) catch udp_text_buf[0..0];
}

fn formatUdpLocal(sock: *const UdpSocket) []const u8 {
    if (sock.family == .ipv6) {
        var tmp: [64]u8 = undefined;
        const a = formatIpv6Into(&tmp, our_ip6);
        return std.fmt.bufPrint(&udp_text_buf, "[{s}]!{d}\n", .{ a, sock.local_port }) catch udp_text_buf[0..0];
    }
    return std.fmt.bufPrint(&udp_text_buf, "{d}.{d}.{d}.{d}!{d}\n", .{ our_ip[0], our_ip[1], our_ip[2], our_ip[3], sock.local_port }) catch udp_text_buf[0..0];
}

fn formatUdpRemote(sock: *const UdpSocket) []const u8 {
    if (!sock.has_remote) return udp_text_buf[0..0];
    switch (sock.family) {
        .ipv4 => {
            const a = sock.remote.v4;
            return std.fmt.bufPrint(&udp_text_buf, "{d}.{d}.{d}.{d}!{d}\n", .{ a[0], a[1], a[2], a[3], sock.remote.port }) catch udp_text_buf[0..0];
        },
        .ipv6 => {
            var tmp: [64]u8 = undefined;
            const a = formatIpv6Into(&tmp, sock.remote.v6);
            return std.fmt.bufPrint(&udp_text_buf, "[{s}]!{d}\n", .{ a, sock.remote.port }) catch udp_text_buf[0..0];
        },
    }
}

fn readText(offset: u64, out: []u8, view: []const u8) fs.HandlerError!usize {
    if (offset >= view.len) return 0;
    const start: usize = @intCast(offset);
    const n = @min(view.len - start, out.len);
    @memcpy(out[0..n], view[start..][0..n]);
    return n;
}

fn readPingReply(offset: u64, out: []u8) fs.HandlerError!usize {
    if (!ping_state.in_flight) return 0;

    // Yield-count fallback for arches where the boot-mono clock doesn't tick
    // soon enough (x86_64 sees boot_mono_ns=0 until the local-APIC timer is
    // armed; ping would then read past `deadline` only after the clock
    // started advancing, making the 3-s wall-clock budget effectively
    // unbounded). 30 000 yields is well under a second on QEMU even at
    // single-IPS but bounds the worst case.
    const deadline = ferrite.clockMono() + 3 * std.time.ns_per_s;
    var spins: u32 = 0;
    while (@atomicLoad(u32, &ping_state.done, .acquire) == 0) {
        if (ferrite.clockMono() > deadline or spins > 30_000) {
            const text = std.fmt.bufPrint(&ping_state.reply_text, "timeout\n", .{}) catch return 0;
            ping_state.reply_len = @intCast(text.len);
            @atomicStore(u32, &ping_state.done, 2, .release);
            break;
        }
        spins += 1;
        ferrite.yield();
    }

    const view = ping_state.reply_text[0..ping_state.reply_len];
    if (offset >= view.len) return 0;
    const start: usize = @intCast(offset);
    const n = @min(view.len - start, out.len);
    @memcpy(out[0..n], view[start..][0..n]);

    if (offset + n >= view.len) {
        ping_state.in_flight = false;
        @atomicStore(u32, &ping_state.done, 0, .release);
    }
    return n;
}

fn readPing6Reply(offset: u64, out: []u8) fs.HandlerError!usize {
    if (!ping6_state.in_flight) return 0;

    // Yield-count fallback for arches where clockMono doesn't tick early;
    // see the matching note in readPingReply.
    const deadline = ferrite.clockMono() + 3 * std.time.ns_per_s;
    var spins: u32 = 0;
    while (@atomicLoad(u32, &ping6_state.done, .acquire) == 0) {
        if (ferrite.clockMono() > deadline or spins > 30_000) {
            const text = std.fmt.bufPrint(&ping6_state.reply_text, "timeout\n", .{}) catch return 0;
            ping6_state.reply_len = @intCast(text.len);
            @atomicStore(u32, &ping6_state.done, 2, .release);
            break;
        }
        spins += 1;
        ferrite.yield();
    }

    const view = ping6_state.reply_text[0..ping6_state.reply_len];
    if (offset >= view.len) return 0;
    const start: usize = @intCast(offset);
    const n = @min(view.len - start, out.len);
    @memcpy(out[0..n], view[start..][0..n]);

    if (offset + n >= view.len) {
        ping6_state.in_flight = false;
        @atomicStore(u32, &ping6_state.done, 0, .release);
    }
    return n;
}

fn onWrite(s: *State, fid: u32, _: u64, data: []const u8) fs.HandlerError!u32 {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    if (s.fids[fid].kind == .udp_leaf) return writeUdpLeaf(&s.fids[fid], data);
    if (s.fids[fid].kind == .tcp_leaf) return writeTcpLeaf(&s.fids[fid], data);
    if (s.fids[fid].kind != .leaf) return error.BadOp;

    const view = std.mem.trim(u8, data, " \t\r\n");
    if (view.len == 0) return error.BadOp;
    var tok = std.mem.tokenizeAny(u8, view, " \t");
    const addr_str = tok.next() orelse return error.BadOp;

    switch (s.fids[fid].leaf) {
        .icmp4 => {
            const target = parseIpv4(addr_str) orelse return error.BadOp;
            ping_state.target = target;
            ping_state.id = 0xBEEF;
            ping_state.seq +%= 1;
            ping_state.in_flight = true;
            @atomicStore(u32, &ping_state.done, 0, .release);
            spinUntilSent(target);
            return @intCast(data.len);
        },
        .icmp6 => {
            const target = parseIpv6(addr_str) orelse return error.BadOp;
            ping6_state.target = target;
            ping6_state.id = 0xBEE6;
            ping6_state.seq +%= 1;
            ping6_state.in_flight = true;
            @atomicStore(u32, &ping6_state.done, 0, .release);
            spinUntilSent6(target);
            return @intCast(data.len);
        },
        .addr => {
            const slash = std.mem.indexOfScalar(u8, addr_str, '/') orelse return error.BadOp;
            const ip = parseIpv4(addr_str[0..slash]) orelse return error.BadOp;
            const prefix = std.fmt.parseInt(u8, addr_str[slash + 1 ..], 10) catch return error.BadOp;
            our_ip = ip;
            our_prefix = prefix;
            return @intCast(data.len);
        },
        .gw => {
            const ip = parseIpv4(addr_str) orelse return error.BadOp;
            our_gw = ip;
            return @intCast(data.len);
        },
        else => return error.BadOp,
    }
}

/// Yield until the echo lands on the wire; ARP/NDP may need a few yields.
fn spinUntilSent(target: Ipv4) void {
    const deadline = ferrite.clockMono() + 2 * std.time.ns_per_s;
    var spins: u32 = 0;
    while (true) {
        if (sendEchoRequest(target, ping_state.id, ping_state.seq)) return;
        if (ferrite.clockMono() > deadline or spins > 20_000) return;
        spins += 1;
        ferrite.yield();
    }
}

fn spinUntilSent6(target: Ipv6) void {
    const deadline = ferrite.clockMono() + 2 * std.time.ns_per_s;
    var spins: u32 = 0;
    while (true) {
        if (sendEchoRequest6(target, ping6_state.id, ping6_state.seq)) return;
        if (ferrite.clockMono() > deadline or spins > 20_000) return;
        spins += 1;
        ferrite.yield();
    }
}

fn writeUdpLeaf(f: *Fid, data: []const u8) fs.HandlerError!u32 {
    if (f.sock_idx >= UDP_MAX_SOCKETS) return error.BadFid;
    const sock = &udp_sockets[f.sock_idx];
    if (!sock.used) return error.BadFid;

    switch (f.leaf) {
        .udp_ctl => {
            const view = std.mem.trim(u8, data, " \t\r\n");
            if (view.len == 0) return error.BadOp;
            var tok = std.mem.tokenizeAny(u8, view, " \t");
            const cmd = tok.next() orelse return error.BadOp;
            const arg = tok.next() orelse return error.BadOp;
            if (std.mem.eql(u8, cmd, "connect")) {
                applyConnect(sock, arg) catch return error.BadOp;
                return @intCast(data.len);
            }
            if (std.mem.eql(u8, cmd, "bind")) {
                applyBind(sock, arg) catch return error.BadOp;
                return @intCast(data.len);
            }
            return error.BadOp;
        },
        .udp_data => {
            if (!sock.has_remote) return error.BadOp;
            const deadline = ferrite.clockMono() + 2 * std.time.ns_per_s;
            while (true) {
                const ok = switch (sock.family) {
                    .ipv4 => udpSend4(f.sock_idx, data),
                    .ipv6 => udpSend6(f.sock_idx, data),
                };
                if (ok) return @intCast(data.len);
                if (ferrite.clockMono() > deadline) return error.BadOp;
                ferrite.yield();
            }
        },
        else => return error.BadOp,
    }
}

/// "addr!port" for IPv4 or "[addr]!port" for IPv6.
fn parseEndpoint(text: []const u8, out: *UdpAddr) !void {
    var rest = text;
    if (rest.len == 0) return error.BadOp;
    if (rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return error.BadOp;
        const addr_s = rest[1..close];
        const after = rest[close + 1 ..];
        if (after.len == 0 or after[0] != '!') return error.BadOp;
        const port_s = after[1..];
        const a = parseIpv6(addr_s) orelse return error.BadOp;
        const p = std.fmt.parseInt(u16, port_s, 10) catch return error.BadOp;
        out.* = .{ .family = .ipv6, .v6 = a, .port = p };
        return;
    }
    const bang = std.mem.indexOfScalar(u8, rest, '!') orelse return error.BadOp;
    const addr_s = rest[0..bang];
    const port_s = rest[bang + 1 ..];
    const p = std.fmt.parseInt(u16, port_s, 10) catch return error.BadOp;
    if (std.mem.indexOfScalar(u8, addr_s, ':') != null) {
        const a = parseIpv6(addr_s) orelse return error.BadOp;
        out.* = .{ .family = .ipv6, .v6 = a, .port = p };
    } else {
        const a = parseIpv4(addr_s) orelse return error.BadOp;
        out.* = .{ .family = .ipv4, .v4 = a, .port = p };
    }
}

fn applyConnect(sock: *UdpSocket, arg: []const u8) !void {
    var ep: UdpAddr = .{};
    try parseEndpoint(arg, &ep);
    sock.family = ep.family;
    sock.remote = ep;
    sock.has_remote = true;
}

fn writeTcpLeaf(f: *Fid, data: []const u8) fs.HandlerError!u32 {
    if (f.sock_idx >= TCP_MAX_SOCKETS) return error.BadFid;
    const sock = &tcp_sockets[f.sock_idx];
    if (!sock.used) return error.BadFid;

    switch (f.leaf) {
        .tcp_ctl => {
            const view = std.mem.trim(u8, data, " \t\r\n");
            if (view.len == 0) return error.BadOp;
            var tok = std.mem.tokenizeAny(u8, view, " \t");
            const cmd = tok.next() orelse return error.BadOp;
            if (std.mem.eql(u8, cmd, "connect")) {
                const arg = tok.next() orelse return error.BadOp;
                applyTcpConnect(sock, arg) catch return error.BadOp;
                return @intCast(data.len);
            }
            if (std.mem.eql(u8, cmd, "bind")) {
                const arg = tok.next() orelse return error.BadOp;
                applyTcpBind(sock, arg) catch return error.BadOp;
                return @intCast(data.len);
            }
            if (std.mem.eql(u8, cmd, "listen")) {
                applyTcpListen(sock) catch return error.BadOp;
                return @intCast(data.len);
            }
            if (std.mem.eql(u8, cmd, "hangup")) {
                applyTcpHangup(sock);
                return @intCast(data.len);
            }
            if (std.mem.eql(u8, cmd, "release")) {
                // Drop socket; other fids referencing it get BadFid next access.
                if (sock.state != .closed) applyTcpHangup(sock);
                // Unblock any thread parked in tcp_accept so it doesn't strand.
                const cap = @atomicRmw(u32, &sock.pending_reply_cap, .Xchg, @as(u32, 0), .acquire);
                if (cap != 0) {
                    const p = fs.PendingRead{
                        .reply_cap = cap,
                        .tag = sock.pending_tag,
                        .fid = 0,
                        .offset = 0,
                        .want = 0,
                    };
                    p.respondErr(.bad_op);
                }
                sock.* = .{};
                return @intCast(data.len);
            }
            return error.BadOp;
        },
        .tcp_data => {
            if (sock.state != .established and sock.state != .close_wait) return error.BadOp;
            return tcpSendData(sock, data) orelse error.BadOp;
        },
        else => return error.BadOp,
    }
}

fn applyTcpConnect(sock: *TcpSocket, arg: []const u8) !void {
    var ep: UdpAddr = .{};
    try parseEndpoint(arg, &ep);
    sock.family = ep.family;
    sock.remote = ep;
    sock.has_remote = true;
    sock.state = .syn_sent;
    sock.snd_nxt = 0;
    sock.snd_una = 0;

    {
        const deadline = ferrite.clockMono() + 2 * std.time.ns_per_s;
        while (true) {
            sock.snd_nxt = 0;
            if (sendTcpSegment(sock, TCP_SYN, &.{})) {
                sock.snd_nxt = 1;
                break;
            }
            if (ferrite.clockMono() > deadline) return error.BadOp;
            ferrite.yield();
        }
    }

    const deadline = ferrite.clockMono() + 5 * std.time.ns_per_s;
    while (sock.state != .established) {
        if (sock.state == .closed) return error.BadOp;
        if (ferrite.clockMono() > deadline) return error.BadOp;
        ferrite.yield();
    }
}

/// Address part of `addr!port` is advisory; only the port is bound.
fn applyTcpBind(sock: *TcpSocket, arg: []const u8) !void {
    var ep: UdpAddr = .{};
    try parseEndpoint(arg, &ep);
    sock.family = ep.family;
    sock.local_port = ep.port;
}

fn applyTcpListen(sock: *TcpSocket) !void {
    if (sock.state != .closed) return error.BadOp;
    sock.state = .listen;
    sock.is_listener = true;
}

fn applyTcpHangup(sock: *TcpSocket) void {
    switch (sock.state) {
        .established => {
            _ = sendTcpSegment(sock, TCP_FIN | TCP_ACK, &.{});
            sock.snd_nxt +%= 1;
            sock.state = .fin_wait_1;
        },
        .close_wait => {
            _ = sendTcpSegment(sock, TCP_FIN | TCP_ACK, &.{});
            sock.snd_nxt +%= 1;
            sock.state = .last_ack;
        },
        else => {},
    }
}

/// No queuing: if the wire send fails after the retry budget, return 0.
fn tcpSendData(sock: *TcpSocket, data: []const u8) ?u32 {
    if (data.len == 0) return 0;
    const mss: usize = @intCast(sock.mss);
    var total: u32 = 0;
    var rest = data;
    while (rest.len > 0) {
        const chunk_len = @min(rest.len, mss);
        const chunk = rest[0..chunk_len];
        const deadline = ferrite.clockMono() + 2 * std.time.ns_per_s;
        var ok = false;
        while (true) {
            if (sendTcpSegment(sock, TCP_ACK | TCP_PSH, chunk)) {
                ok = true;
                break;
            }
            if (ferrite.clockMono() > deadline) break;
            ferrite.yield();
        }
        if (!ok) return if (total == 0) null else total;
        sock.snd_nxt +%= @intCast(chunk_len);
        total += @intCast(chunk_len);
        rest = rest[chunk_len..];
    }
    return total;
}

fn applyBind(sock: *UdpSocket, arg: []const u8) !void {
    // "*!port" or "addr!port"; addr ignored (single iface).
    const bang = std.mem.indexOfScalar(u8, arg, '!') orelse return error.BadOp;
    const port_s = arg[bang + 1 ..];
    const p = std.fmt.parseInt(u16, port_s, 10) catch return error.BadOp;
    sock.local_port = p;
}

fn onClose(s: *State, fid: u32) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    if (fid != 0) s.fids[fid] = .{};
}

fn onStatus(s: *State, fid: u32) fs.HandlerError!p9.StatusReply {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    return switch (s.fids[fid].kind) {
        .root, .eth0, .udp_root, .udp_sock, .tcp_root, .tcp_sock => .{ .kind = .dir, .size = 0 },
        .leaf, .udp_leaf, .tcp_leaf => .{ .kind = .file, .size = 0 },
    };
}

// ---- main ------------------------------------------------------------------

pub fn main() void {
    if (!loadConfig()) {
        ferrite.console.print("[svc.net] config load failed\n", .{}) catch {};
        return;
    }

    if (!openEth0()) {
        ferrite.console.print("[svc.net] /dev/eth0 unavailable. Exiting\n", .{}) catch {};
        return;
    }
    readOurMac();

    if (!startRxThread()) {
        ferrite.console.print("[svc.net] failed to start RX thread\n", .{}) catch {};
        return;
    }

    // QEMU slirp uses 52:55:0a:00:02:NN for the v4 gateway and ignores our ARPs;
    // seed it directly. Real networks overwrite this via the ARP/NDP replies the
    // warmup thread sends. Instant (no round-trip), so it stays on the hot path.
    if (ipToU32(our_gw) != 0) {
        const slirp_v4: Mac = .{ 0x52, 0x55, 0x0a, 0x00, 0x02, our_gw[3] };
        arpInsert(our_gw, slirp_v4);
    }

    const ch = ferrite.channelCreate(0);
    if (ch < 0) return;
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);

    fs.register(URI_PREFIX, svc_send) catch |e| {
        ferrite.console.print("[svc.net] register failed: {t}\n", .{e}) catch {};
        return;
    };
    fs.mount(MOUNT_PREFIX, URI_PREFIX) catch |e| switch (e) {
        error.Permission => {},
        else => {
            ferrite.console.print("[svc.net] mount({s}) failed: {t}\n", .{ MOUNT_PREFIX, e }) catch {};
            return;
        },
    };

    state.fids[0] = .{ .used = true, .opened = true, .kind = .root };

    // /sys/net is now resolvable. Prime ARP/NDP + DNS caches concurrently so the
    // slow (under TCG) warmup no longer delays registration past svc.dhcp's wait.
    _ = startWarmupThread();

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

fn openEth0() bool {
    var uri_buf: [128]u8 = undefined;
    // Wait forever; without eth0 we can't serve anything. init respawns on driver crash.
    while (true) {
        if (fs.resolvePath("/dev/eth0", &uri_buf)) |uri| {
            if (fs.open(uri, .{ .mode = .rdwr })) |f| {
                eth0 = f;
                return true;
            } else |_| {}
        } else |_| {}
        ferrite.yield();
    }
}

fn readOurMac() void {
    var uri_buf: [128]u8 = undefined;
    const uri = fs.resolvePath("/dev/eth0/mac", &uri_buf) catch return;
    const f = fs.open(uri, .{ .mode = .read }) catch return;
    defer f.close();
    var text: [32]u8 = undefined;
    var got: usize = 0;
    while (got < text.len) {
        const n = f.read(got, text[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    parseMac(text[0..got]) catch {};
}

/// Pre-resolve nameservers from /etc/resolv.conf via ARP/NDP.
fn preResolveDns() void {
    var buf: [512]u8 = undefined;
    const n = ferrite.readInitrdFile("etc/resolv.conf", &buf);
    if (n == 0) return;
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |raw| {
        const line = stripComment(raw);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var tok = std.mem.tokenizeAny(u8, trimmed, " \t");
        const kw = tok.next() orelse continue;
        if (!std.mem.eql(u8, kw, "nameserver")) continue;
        const ip = tok.next() orelse continue;
        if (std.mem.indexOfScalar(u8, ip, ':') != null) {
            if (parseIpv6(ip)) |a| sendNdpSolicit(if (sameSubnet6(a, our_ip6, our_prefix6)) a else our_gw6);
        } else {
            if (parseIpv4(ip)) |a| sendArpRequest(if (sameSubnet(a, our_ip, our_prefix)) a else our_gw);
        }
    }
}

fn parseMac(s: []const u8) !void {
    var parts = std.mem.tokenizeAny(u8, s, ":\n\r ");
    var i: usize = 0;
    while (parts.next()) |part| {
        if (i >= 6) break;
        our_mac[i] = try std.fmt.parseInt(u8, part, 16);
        i += 1;
    }
}
