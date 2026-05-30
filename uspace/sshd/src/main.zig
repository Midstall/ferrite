// sshd: SSH-2.0 server. Single-algo: curve25519-sha256 / ssh-ed25519 /
// chacha20-poly1305@openssh.com / none.

const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

const con = &ferrite.console;
const fs = ferrite.fs;
const X25519 = std.crypto.dh.X25519;
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const ChaCha20 = std.crypto.stream.chacha.ChaCha20IETF;
const Poly1305 = std.crypto.onetimeauth.Poly1305;

// SSH message numbers (RFC 4250 §4.1).
const MSG_DISCONNECT: u8 = 1;
const MSG_IGNORE: u8 = 2;
const MSG_UNIMPLEMENTED: u8 = 3;
const MSG_DEBUG: u8 = 4;
const MSG_SERVICE_REQUEST: u8 = 5;
const MSG_SERVICE_ACCEPT: u8 = 6;
const MSG_KEXINIT: u8 = 20;
const MSG_NEWKEYS: u8 = 21;
const MSG_KEX_ECDH_INIT: u8 = 30;
const MSG_KEX_ECDH_REPLY: u8 = 31;
const MSG_USERAUTH_REQUEST: u8 = 50;
const MSG_USERAUTH_FAILURE: u8 = 51;
const MSG_USERAUTH_SUCCESS: u8 = 52;
const MSG_GLOBAL_REQUEST: u8 = 80;
const MSG_CHANNEL_OPEN: u8 = 90;
const MSG_CHANNEL_OPEN_CONFIRMATION: u8 = 91;
const MSG_CHANNEL_OPEN_FAILURE: u8 = 92;
const MSG_CHANNEL_WINDOW_ADJUST: u8 = 93;
const MSG_CHANNEL_DATA: u8 = 94;
const MSG_CHANNEL_EXTENDED_DATA: u8 = 95;
const MSG_CHANNEL_EOF: u8 = 96;
const MSG_CHANNEL_CLOSE: u8 = 97;
const MSG_CHANNEL_REQUEST: u8 = 98;
const MSG_CHANNEL_SUCCESS: u8 = 99;
const MSG_CHANNEL_FAILURE: u8 = 100;

const VERSION_LINE = "SSH-2.0-Ferrite_0.1\r\n";

const MAX_PACKET: usize = 35000;

// Rekey before either limit (RFC 4344 §6.1). 2^30 stays an octave under the
// hard 2^32 packet ceiling; 1 GiB matches the OpenSSH default.
const REKEY_PACKETS: u32 = 1 << 30;
const REKEY_BYTES: u64 = 1 << 30;

// chacha20-poly1305@openssh.com layout (cipher-chachapoly.c in OpenSSH):
// - key[0..32]   = "main" key (encrypts payload, derives Poly1305 key)
// - key[32..64]  = "header" key (encrypts the 4-byte length field)
// - nonce = 64-bit BE packet sequence number, padded to 12 bytes (zeros)
// - Poly1305 key = ChaCha20(main, nonce, ctr=0)[0..32]
// - Payload encrypted with ChaCha20(main, nonce, ctr=1)
// - Length encrypted with ChaCha20(header, nonce, ctr=0) (4 bytes)
// - Tag covers encrypted_length || encrypted_payload
const KEY_BYTES: usize = 64;

// Wire-format helpers.

/// Cursor-style writer over a fixed buffer (avoids ArrayList+FBA OOM in auth).
const Builder = struct {
    buf: []u8,
    pos: usize = 0,

    fn init(into: []u8) Builder {
        return .{ .buf = into, .pos = 0 };
    }

    fn append(self: *Builder, byte: u8) !void {
        if (self.pos >= self.buf.len) return error.NoSpace;
        self.buf[self.pos] = byte;
        self.pos += 1;
    }

    fn appendSlice(self: *Builder, data: []const u8) !void {
        if (self.pos + data.len > self.buf.len) return error.NoSpace;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    fn putU32(self: *Builder, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .big);
        try self.appendSlice(&b);
    }

    fn putString(self: *Builder, s: []const u8) !void {
        try self.putU32(@intCast(s.len));
        try self.appendSlice(s);
    }

    /// SSH mpint (positive): strip leading zeros, prepend 0x00 if MSB set.
    fn putMpInt(self: *Builder, raw: []const u8) !void {
        var start: usize = 0;
        while (start < raw.len and raw[start] == 0) start += 1;
        const trimmed = raw[start..];
        if (trimmed.len == 0) return self.putU32(0);
        if (trimmed[0] & 0x80 != 0) {
            try self.putU32(@intCast(trimmed.len + 1));
            try self.append(0);
            try self.appendSlice(trimmed);
        } else {
            try self.putU32(@intCast(trimmed.len));
            try self.appendSlice(trimmed);
        }
    }

    fn slice(self: *const Builder) []const u8 {
        return self.buf[0..self.pos];
    }
};

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn u8c(self: *Reader) !u8 {
        if (self.pos >= self.data.len) return error.Short;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn u32be(self: *Reader) !u32 {
        if (self.pos + 4 > self.data.len) return error.Short;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .big);
        self.pos += 4;
        return v;
    }

    fn string(self: *Reader) ![]const u8 {
        const len = try self.u32be();
        if (self.pos + len > self.data.len) return error.Short;
        const s = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return s;
    }

    fn nameList(self: *Reader) ![]const u8 {
        return self.string();
    }

    fn skip(self: *Reader, n: usize) !void {
        if (self.pos + n > self.data.len) return error.Short;
        self.pos += n;
    }
};

// Entropy.

// Persistent handle: per-packet open+close blew the cap-table during auth.
var rng_file: ?fs.File = null;

fn openRng() !void {
    var uri_buf: [128]u8 = undefined;
    const uri = try fs.resolvePath("/dev/random", &uri_buf);
    // drv.virtio-rng comes up after us; spin until the node appears.
    while (true) {
        if (fs.open(uri, .{ .mode = .read })) |h| {
            rng_file = h;
            return;
        } else |_| {}
        ferrite.nanosleep(100_000_000);
    }
}

fn randomBytes(out: []u8) !void {
    if (rng_file == null) return error.NoEntropy;
    var got: usize = 0;
    while (got < out.len) {
        const n = try rng_file.?.read(0, out[got..]);
        if (n == 0) return error.NoEntropy;
        got += n;
    }
}

// TCP socket helpers wrapping /sys/net/tcp/<n>/*.

const TcpHandle = struct {
    idx: u8,
    data: fs.File,

    fn open(idx: u8) !TcpHandle {
        var uri_buf: [64]u8 = undefined;
        const data_path = try std.fmt.bufPrint(&uri_buf, "/sys/net/tcp/{d}/data", .{idx});
        var uri_buf2: [128]u8 = undefined;
        const uri = try fs.resolvePath(data_path, &uri_buf2);
        const f = try fs.open(uri, .{ .mode = .rdwr });
        return .{ .idx = idx, .data = f };
    }

    fn close(self: *TcpHandle) void {
        self.data.close();
    }

    fn readSome(self: *TcpHandle, dst: []u8) !usize {
        sshLockAcquire();
        defer sshLockRelease();
        return self.data.read(0, dst);
    }

    /// Lock released between iterations so the tx thread can write meanwhile.
    fn readExact(self: *TcpHandle, dst: []u8) !void {
        var got: usize = 0;
        while (got < dst.len) {
            const n = blk: {
                sshLockAcquire();
                defer sshLockRelease();
                break :blk self.data.read(0, dst[got..]) catch |e| {
                    if (e == error.RecvFailed) break :blk @as(usize, 0);
                    return e;
                };
            };
            if (n == 0) {
                ferrite.nanosleep(10_000_000);
                continue;
            }
            got += n;
        }
    }

    /// Caller must hold `tx_write_lock`; reacquiring here would deadlock.
    fn writeAll(self: *TcpHandle, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const want = bytes.len - off;
            const chunk = @min(want, 1024);
            _ = try self.data.writeAll(bytes[off .. off + chunk]);
            off += chunk;
        }
    }

    /// Read until '\n' (or end of buf); result includes the trailing '\n'.
    fn readLine(self: *TcpHandle, buf: []u8) ![]u8 {
        var i: usize = 0;
        while (i < buf.len) {
            var b: [1]u8 = undefined;
            const n = self.data.read(0, &b) catch |e| {
                if (e == error.RecvFailed) {
                    ferrite.nanosleep(10_000_000);
                    continue;
                }
                return e;
            };
            if (n == 0) {
                ferrite.nanosleep(10_000_000);
                continue;
            }
            buf[i] = b[0];
            i += 1;
            if (b[0] == '\n') return buf[0..i];
        }
        return error.LineTooLong;
    }
};

// Listener: wraps ctl bind/listen + /accept polling.

fn openCtl(idx: u8) !fs.File {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/sys/net/tcp/{d}/ctl", .{idx});
    var uri_buf: [128]u8 = undefined;
    const uri = try fs.resolvePath(path, &uri_buf);
    return try fs.open(uri, .{ .mode = .rdwr });
}

fn openAccept(idx: u8) !fs.File {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/sys/net/tcp/{d}/accept", .{idx});
    var uri_buf: [128]u8 = undefined;
    const uri = try fs.resolvePath(path, &uri_buf);
    return try fs.open(uri, .{ .mode = .read });
}

/// Allocate a listening socket. Spins waiting for svc.net to come up.
fn listenOnPort(port: u16) !u8 {
    var uri_buf: [128]u8 = undefined;
    const clone_uri = try fs.resolvePath("/sys/net/tcp/clone", &uri_buf);
    const clone: fs.File = blk: while (true) {
        if (fs.open(clone_uri, .{ .mode = .read })) |h| break :blk h else |_| {}
        ferrite.nanosleep(200_000_000);
    };
    defer clone.close();
    var buf: [16]u8 = undefined;
    const n = try clone.read(0, &buf);
    const view = std.mem.trim(u8, buf[0..n], " \t\r\n");
    const idx = std.fmt.parseInt(u8, view, 10) catch return error.BadClone;

    var ctl = try openCtl(idx);
    defer ctl.close();
    var cmd_buf: [64]u8 = undefined;
    const bind_cmd = try std.fmt.bufPrint(&cmd_buf, "bind 0.0.0.0!{d}", .{port});
    _ = try ctl.writeAll(bind_cmd);
    _ = try ctl.writeAll("listen");
    return idx;
}

/// Blocking accept: svc.net parks the read until 3WHS completes.
fn waitAccept(listener_idx: u8) !u8 {
    const acc = try openAccept(listener_idx);
    defer acc.close();
    var buf: [16]u8 = undefined;
    const n = try acc.read(0, &buf);
    if (n == 0) return error.AcceptClosed;
    const view = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return std.fmt.parseInt(u8, view, 10) catch error.BadAccept;
}

// Binary Packet Protocol.

const StreamKeys = struct {
    /// [0..32] payload key, [32..64] length key.
    key: [KEY_BYTES]u8 = @splat(0),
    /// Packet sequence number; serves as the chacha20 nonce.
    seq: u32 = 0,
    /// False until NEWKEYS for this direction.
    active: bool = false,
};

const Session = struct {
    tcp: *TcpHandle,
    host_key: Ed25519.KeyPair,
    tx: StreamKeys = .{},
    rx: StreamKeys = .{},
    /// Pinned at first KEX; subsequent rekeys derive C/D against this, not H.
    session_id: [Sha256.digest_length]u8 = @splat(0),
    have_session_id: bool = false,
    /// Client's version string, saved for rekey H computation.
    v_c_buf: [256]u8 = @splat(0),
    v_c_len: u16 = 0,
    /// Since the last NEWKEYS pair.
    tx_bytes: u64 = 0,
    rx_bytes: u64 = 0,
    tx_packets: u32 = 0,
    rx_packets: u32 = 0,

    fn vC(self: *const Session) []const u8 {
        return self.v_c_buf[0..self.v_c_len];
    }

    fn shouldRekey(self: *const Session) bool {
        return self.tx_bytes >= REKEY_BYTES or self.rx_bytes >= REKEY_BYTES or
            self.tx_packets >= REKEY_PACKETS or self.rx_packets >= REKEY_PACKETS;
    }

    fn resetRekeyCounters(self: *Session) void {
        self.tx_bytes = 0;
        self.rx_bytes = 0;
        self.tx_packets = 0;
        self.rx_packets = 0;
    }

    fn writePlain(self: *Session, payload: []const u8) !void {
        // Pre-NEWKEYS: 4+1+payload+pad must be a multiple of 8 (cipher block).
        const block: usize = 8;
        const min_pad: usize = 4;
        const without_pad = 5 + payload.len;
        var pad_len: usize = block - (without_pad % block);
        if (pad_len < min_pad) pad_len += block;
        const packet_len: u32 = @intCast(1 + payload.len + pad_len);

        var hdr: [5]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], packet_len, .big);
        hdr[4] = @intCast(pad_len);
        try self.tcp.writeAll(&hdr);
        try self.tcp.writeAll(payload);
        var pad_buf: [256]u8 = @splat(0);
        try self.tcp.writeAll(pad_buf[0..pad_len]);
        self.tx.seq += 1;
        self.tx_bytes +%= @as(u64, 5) + payload.len + pad_len;
        self.tx_packets +%= 1;
    }

    fn readPlain(self: *Session, buf: []u8) ![]u8 {
        var hdr: [5]u8 = undefined;
        try self.tcp.readExact(&hdr);
        const packet_len = std.mem.readInt(u32, hdr[0..4], .big);
        const pad_len = hdr[4];
        if (packet_len < @as(u32, pad_len) + 1) return error.MalformedPacket;
        const payload_len = packet_len - 1 - @as(u32, pad_len);
        if (payload_len > buf.len) return error.PayloadTooLong;
        try self.tcp.readExact(buf[0..payload_len]);
        var pad_drop: [256]u8 = undefined;
        try self.tcp.readExact(pad_drop[0..pad_len]);
        self.rx.seq += 1;
        self.rx_bytes +%= @as(u64, 5) + packet_len - 1;
        self.rx_packets +%= 1;
        return buf[0..payload_len];
    }

    /// Encrypted send (chacha20-poly1305@openssh.com).
    fn writeEncrypted(self: *Session, payload: []const u8) !void {
        // OpenSSH PROTOCOL: only inner (pad_len|payload|pad) is block-aligned,
        // not the 4-byte length field.
        const block: usize = 8;
        const min_pad: usize = 4;
        const without_pad = 1 + payload.len;
        var pad_len: usize = block - (without_pad % block);
        if (pad_len < min_pad) pad_len += block;
        const inner_len: u32 = @intCast(1 + payload.len + pad_len);

        var nonce: [12]u8 = @splat(0);
        std.mem.writeInt(u32, nonce[8..12], self.tx.seq, .big);

        var len_be: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_be, inner_len, .big);
        var enc_len: [4]u8 = undefined;
        ChaCha20.xor(&enc_len, &len_be, 0, self.tx.key[32..64].*, nonce);

        var inner: [MAX_PACKET]u8 = undefined;
        inner[0] = @intCast(pad_len);
        @memcpy(inner[1..][0..payload.len], payload);
        var pi: usize = 1 + payload.len;
        var pad_random: [256]u8 = undefined;
        randomBytes(pad_random[0..pad_len]) catch |e| return e;
        @memcpy(inner[pi..][0..pad_len], pad_random[0..pad_len]);
        pi += pad_len;

        var enc_inner: [MAX_PACKET]u8 = undefined;
        ChaCha20.xor(enc_inner[0..pi], inner[0..pi], 1, self.tx.key[0..32].*, nonce);

        var poly_key: [32]u8 = undefined;
        var zero32: [32]u8 = @splat(0);
        ChaCha20.xor(&poly_key, &zero32, 0, self.tx.key[0..32].*, nonce);

        var tag: [16]u8 = undefined;
        var mac_buf: [MAX_PACKET + 4]u8 = undefined;
        @memcpy(mac_buf[0..4], &enc_len);
        @memcpy(mac_buf[4..][0..pi], enc_inner[0..pi]);
        Poly1305.create(&tag, mac_buf[0 .. 4 + pi], &poly_key);

        try self.tcp.writeAll(&enc_len);
        try self.tcp.writeAll(enc_inner[0..pi]);
        try self.tcp.writeAll(&tag);
        self.tx.seq += 1;
        self.tx_bytes +%= @as(u64, 4) + pi + 16;
        self.tx_packets +%= 1;
    }

    fn readEncrypted(self: *Session, buf: []u8) ![]u8 {
        var enc_len: [4]u8 = undefined;
        try self.tcp.readExact(&enc_len);

        var nonce: [12]u8 = @splat(0);
        std.mem.writeInt(u32, nonce[8..12], self.rx.seq, .big);

        var len_be: [4]u8 = undefined;
        ChaCha20.xor(&len_be, &enc_len, 0, self.rx.key[32..64].*, nonce);
        const inner_len = std.mem.readInt(u32, &len_be, .big);
        if (inner_len > MAX_PACKET) return error.PayloadTooLong;

        var enc_inner: [MAX_PACKET]u8 = undefined;
        try self.tcp.readExact(enc_inner[0..inner_len]);
        var tag: [16]u8 = undefined;
        try self.tcp.readExact(&tag);

        var poly_key: [32]u8 = undefined;
        var zero32: [32]u8 = @splat(0);
        ChaCha20.xor(&poly_key, &zero32, 0, self.rx.key[0..32].*, nonce);
        var mac_buf: [MAX_PACKET + 4]u8 = undefined;
        @memcpy(mac_buf[0..4], &enc_len);
        @memcpy(mac_buf[4..][0..inner_len], enc_inner[0..inner_len]);
        var expected: [16]u8 = undefined;
        Poly1305.create(&expected, mac_buf[0 .. 4 + inner_len], &poly_key);
        if (!std.crypto.timing_safe.eql([16]u8, expected, tag)) return error.BadMac;

        var inner: [MAX_PACKET]u8 = undefined;
        ChaCha20.xor(inner[0..inner_len], enc_inner[0..inner_len], 1, self.rx.key[0..32].*, nonce);

        const pad_len = inner[0];
        if (@as(u32, pad_len) + 1 > inner_len) return error.MalformedPacket;
        const payload_len = inner_len - 1 - @as(u32, pad_len);
        if (payload_len > buf.len) return error.PayloadTooLong;
        @memcpy(buf[0..payload_len], inner[1..][0..payload_len]);
        self.rx.seq += 1;
        self.rx_bytes +%= @as(u64, 4) + inner_len + 16;
        self.rx_packets +%= 1;
        return buf[0..payload_len];
    }

    fn writePacket(self: *Session, payload: []const u8) !void {
        // Held across the whole packet so tx.seq + tx.key updates stay paired
        // with the wire write; readers release the lock between reads.
        sshLockAcquire();
        defer sshLockRelease();
        if (self.tx.active) {
            try self.writeEncrypted(payload);
        } else {
            try self.writePlain(payload);
        }
    }

    fn readPacket(self: *Session, buf: []u8) ![]u8 {
        return if (self.rx.active)
            try self.readEncrypted(buf)
        else
            try self.readPlain(buf);
    }
};

inline fn sshLockAcquire() void {
    while (@atomicRmw(u32, &tx_write_lock, .Xchg, 1, .acquire) != 0) {
        ferrite.yield();
    }
}

inline fn sshLockRelease() void {
    @atomicStore(u32, &tx_write_lock, 0, .release);
}

// KEXINIT.

const SERVER_ALGS = struct {
    const kex = "curve25519-sha256";
    const host_key = "ssh-ed25519";
    const cipher = "chacha20-poly1305@openssh.com";
    const mac = "";
    const compress = "none";
};

/// Build server KEXINIT into `dst`; `cookie` is 16 random bytes.
fn buildKexinit(dst: []u8, cookie: *const [16]u8) ![]const u8 {
    var b: Builder = .init(dst);
    try b.append(MSG_KEXINIT);
    try b.appendSlice(cookie);
    try b.putString(SERVER_ALGS.kex);
    try b.putString(SERVER_ALGS.host_key);
    try b.putString(SERVER_ALGS.cipher); // c→s
    try b.putString(SERVER_ALGS.cipher); // s→c
    try b.putString(SERVER_ALGS.mac); // c→s (empty: AEAD)
    try b.putString(SERVER_ALGS.mac); // s→c
    try b.putString(SERVER_ALGS.compress); // c→s
    try b.putString(SERVER_ALGS.compress); // s→c
    try b.putString(""); // langs c→s
    try b.putString(""); // langs s→c
    try b.append(0); // first_kex_packet_follows
    try b.putU32(0); // reserved
    return b.slice();
}

// KEX.

const KexResult = struct {
    session_id: [Sha256.digest_length]u8,
    c2s_key: [KEY_BYTES]u8,
    s2c_key: [KEY_BYTES]u8,
};

/// curve25519-sha256 KEX. `i_c`/`i_s` are the on-wire SSH payloads (no BPP).
/// `session_id_override`: null on first KEX (use H), original H on rekey.
fn runKex(
    sess: *Session,
    v_c: []const u8,
    v_s: []const u8,
    i_c: []const u8,
    i_s: []const u8,
    session_id_override: ?[]const u8,
) !KexResult {
    var buf: [MAX_PACKET]u8 = undefined;
    const msg = try sess.readPacket(&buf);
    if (msg.len < 1 or msg[0] != MSG_KEX_ECDH_INIT) return error.UnexpectedMsg;
    var r: Reader = .{ .data = msg[1..] };
    const q_c = try r.string();
    if (q_c.len != 32) return error.BadEcdh;

    var eph_seed: [32]u8 = undefined;
    try randomBytes(&eph_seed);
    const eph_pub = try X25519.recoverPublicKey(eph_seed);

    var q_c_arr: [32]u8 = undefined;
    @memcpy(&q_c_arr, q_c);
    const shared = try X25519.scalarmult(eph_seed, q_c_arr);

    // K_S = string("ssh-ed25519") || string(pubkey).
    var hk_buf: [256]u8 = undefined;
    var hk = Builder.init(&hk_buf);
    try hk.putString("ssh-ed25519");
    try hk.putString(&sess.host_key.public_key.bytes);

    // H = SHA256( V_C, V_S, I_C, I_S, K_S, Q_C, Q_S, mpint K ).
    var hash_buf: [4096]u8 = undefined;
    var hb = Builder.init(&hash_buf);
    try hb.putString(v_c);
    try hb.putString(v_s);
    try hb.putString(i_c);
    try hb.putString(i_s);
    try hb.putString(hk.slice());
    try hb.putString(q_c);
    try hb.putString(&eph_pub);
    try hb.putMpInt(&shared);

    var h: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(hb.slice(), &h, .{});

    // sig blob = string("ssh-ed25519") || string(sig).
    var noise: [Ed25519.noise_length]u8 = undefined;
    try randomBytes(&noise);
    const sig = try sess.host_key.sign(&h, noise);
    var sig_buf: [256]u8 = undefined;
    var sb = Builder.init(&sig_buf);
    try sb.putString("ssh-ed25519");
    try sb.putString(&sig.toBytes());

    var reply_buf: [1024]u8 = undefined;
    var rb = Builder.init(&reply_buf);
    try rb.append(MSG_KEX_ECDH_REPLY);
    try rb.putString(hk.slice());
    try rb.putString(&eph_pub);
    try rb.putString(sb.slice());
    try sess.writePacket(rb.slice());

    var nk: [1]u8 = .{MSG_NEWKEYS};
    try sess.writePacket(&nk);

    const peer = try sess.readPacket(&buf);
    if (peer.len < 1 or peer[0] != MSG_NEWKEYS) return error.UnexpectedMsg;

    // RFC 4253 §7.2: for AEAD we only need 'C' (c->s) and 'D' (s->c), 64B each.
    const sid: []const u8 = session_id_override orelse &h;
    var c2s_key: [KEY_BYTES]u8 = undefined;
    var s2c_key: [KEY_BYTES]u8 = undefined;
    try deriveKey('C', &shared, &h, sid, &c2s_key);
    try deriveKey('D', &shared, &h, sid, &s2c_key);

    return .{ .session_id = h, .c2s_key = c2s_key, .s2c_key = s2c_key };
}

/// `peer_kexinit` non-null = client-initiated rekey (its KEXINIT already read).
fn rekey(sess: *Session, v_s: []const u8, peer_kexinit: ?[]const u8) !void {
    if (!sess.have_session_id) return error.NotKeyed;

    @atomicStore(u32, &tx_paused, 1, .release);
    defer @atomicStore(u32, &tx_paused, 0, .release);
    // Above tx pump's idle period (20 ms), so it notices the flag
    // before our KEXINIT goes on the wire.
    ferrite.nanosleep(50_000_000);

    var cookie: [16]u8 = undefined;
    try randomBytes(&cookie);
    var i_s_buf: [1024]u8 = undefined;
    const i_s = try buildKexinit(&i_s_buf, &cookie);
    try sess.writePacket(i_s);

    var i_c_buf: [MAX_PACKET]u8 = undefined;
    var i_c: []const u8 = undefined;
    if (peer_kexinit) |pi| {
        if (pi.len > i_c_buf.len) return error.PayloadTooLong;
        @memcpy(i_c_buf[0..pi.len], pi);
        i_c = i_c_buf[0..pi.len];
    } else {
        // Client's in-flight CHANNEL_DATA arriving on the old keys still has
        // to reach the tty; everything else between our KEXINIT and theirs
        // is dropped.
        var work: [MAX_PACKET]u8 = undefined;
        while (true) {
            const m = try sess.readPacket(&work);
            if (m.len < 1) continue;
            if (m[0] == MSG_KEXINIT) {
                if (m.len > i_c_buf.len) return error.PayloadTooLong;
                @memcpy(i_c_buf[0..m.len], m);
                i_c = i_c_buf[0..m.len];
                break;
            }
            if (m[0] == MSG_CHANNEL_DATA) {
                var r: Reader = .{ .data = m[1..] };
                _ = r.u32be() catch continue;
                const payload = r.string() catch continue;
                pushTtyIn(&tty_state, payload);
            }
        }
    }

    const result = try runKex(sess, sess.vC(), v_s, i_c, i_s, &sess.session_id);
    sess.tx.key = result.s2c_key;
    sess.rx.key = result.c2s_key;
    sess.resetRekeyCounters();
}

/// RFC 4253 §7.2 key derivation.
fn deriveKey(x: u8, k: []const u8, h: []const u8, session_id: []const u8, out: []u8) !void {
    var k1_buf: [4096]u8 = undefined;
    var k1 = Builder.init(&k1_buf);
    try k1.putMpInt(k);
    try k1.appendSlice(h);
    try k1.append(x);
    try k1.appendSlice(session_id);

    var block: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(k1.slice(), &block, .{});
    var written: usize = 0;

    var rolling_buf: [4096]u8 = undefined;
    var rolling = Builder.init(&rolling_buf);
    try rolling.putMpInt(k);
    try rolling.appendSlice(h);
    const prefix_end = rolling.pos;

    while (written < out.len) {
        const take = @min(out.len - written, block.len);
        @memcpy(out[written..][0..take], block[0..take]);
        written += take;
        if (written >= out.len) break;
        try rolling.appendSlice(&block);
        Sha256.hash(rolling.slice(), &block, .{});
    }
    _ = prefix_end;
}

// User authentication: currently accepts any password.

fn handleAuth(sess: *Session) !void {
    var buf: [MAX_PACKET]u8 = undefined;
    const msg = try sess.readPacket(&buf);
    if (msg.len < 1 or msg[0] != MSG_SERVICE_REQUEST) return error.UnexpectedMsg;
    var r: Reader = .{ .data = msg[1..] };
    const svc = try r.string();
    if (!std.mem.eql(u8, svc, "ssh-userauth")) return error.UnknownService;

    var ack_buf: [256]u8 = undefined;
    var ack = Builder.init(&ack_buf);
    try ack.append(MSG_SERVICE_ACCEPT);
    try ack.putString("ssh-userauth");
    try sess.writePacket(ack.slice());

    while (true) {
        const m = try sess.readPacket(&buf);
        if (m.len < 1) return error.MalformedPacket;
        if (m[0] != MSG_USERAUTH_REQUEST) return error.UnexpectedMsg;
        var rr: Reader = .{ .data = m[1..] };
        _ = try rr.string(); // user
        _ = try rr.string(); // service ("ssh-connection")
        const method = try rr.string();
        if (std.mem.eql(u8, method, "none")) {
            // RFC: "none" must reject so client can enumerate methods.
            var fail_buf: [128]u8 = undefined;
            var fb = Builder.init(&fail_buf);
            try fb.append(MSG_USERAUTH_FAILURE);
            try fb.putString("password");
            try fb.append(0);
            try sess.writePacket(fb.slice());
            continue;
        }
        var ok: [1]u8 = .{MSG_USERAUTH_SUCCESS};
        try sess.writePacket(&ok);
        return;
    }
}

// /dev/ssh.tty: per-session pty backed by in-memory rings (in: client->sh,
// out: sh->client). Wakes use an atomic Xchg on pending_reply_cap.

const TTY_BUF_LEN: usize = 4096;

const TtyState = struct {
    in_buf: [TTY_BUF_LEN]u8 = undefined,
    in_head: usize = 0,
    in_tail: usize = 0,
    out_buf: [TTY_BUF_LEN]u8 = undefined,
    out_head: usize = 0,
    out_tail: usize = 0,
    pending_reply_cap: u32 = 0,
    pending_tag: u8 = 0,
    pending_want: u32 = 0,
    pending_fid: u32 = 0,
    open_count: u32 = 0,
};

var tty_state: TtyState = .{};
var tty_reply_buf: [256]u8 = undefined;

const TTY_DEV_NAME = "ssh.tty";
const TTY_STACK_PAGES: usize = 64;
const TX_STACK_PAGES: usize = 64;

inline fn ttyInBytes(s: *const TtyState) usize {
    return (s.in_tail + TTY_BUF_LEN - s.in_head) % TTY_BUF_LEN;
}

inline fn ttyOutBytes(s: *const TtyState) usize {
    return (s.out_tail + TTY_BUF_LEN - s.out_head) % TTY_BUF_LEN;
}

fn drainTtyIn(s: *TtyState, want: usize) []u8 {
    var n: usize = 0;
    const cap_bytes = @min(want, tty_reply_buf.len);
    while (n < cap_bytes and s.in_head != s.in_tail) : (n += 1) {
        tty_reply_buf[n] = s.in_buf[s.in_head];
        s.in_head = (s.in_head + 1) % TTY_BUF_LEN;
    }
    return tty_reply_buf[0..n];
}

fn pushTtyIn(s: *TtyState, data: []const u8) void {
    for (data) |b| {
        const next = (s.in_tail + 1) % TTY_BUF_LEN;
        if (next == s.in_head) break; // ring full; back-pressure not yet wired
        s.in_buf[s.in_tail] = b;
        s.in_tail = next;
    }
    const cap = @atomicRmw(u32, &s.pending_reply_cap, .Xchg, @as(u32, 0), .acquire);
    if (cap != 0) {
        const out = drainTtyIn(s, s.pending_want);
        const p = fs.PendingRead{
            .reply_cap = cap,
            .tag = s.pending_tag,
            .fid = s.pending_fid,
            .offset = 0,
            .want = 0,
        };
        p.respondRead(out);
    }
}

fn drainTtyOut(s: *TtyState, dst: []u8) usize {
    var n: usize = 0;
    while (n < dst.len and s.out_head != s.out_tail) : (n += 1) {
        dst[n] = s.out_buf[s.out_head];
        s.out_head = (s.out_head + 1) % TTY_BUF_LEN;
    }
    return n;
}

fn ttyOnWalk(_: *TtyState, fid: u32, path: []const u8) fs.HandlerError!fs.WalkResult {
    if (path.len > 0) return error.NotFound;
    return .{ .bound = fid };
}

fn ttyOnOpen(s: *TtyState, _: u32, _: ferrite.p9.Mode) fs.HandlerError!void {
    s.open_count +%= 1;
}

fn ttyOnRead(s: *TtyState, _: u32, _: u64, out: []u8) fs.HandlerError!usize {
    // Unused fallback; on_read_async covers every case.
    var n: usize = 0;
    while (n < out.len and s.in_head != s.in_tail) : (n += 1) {
        out[n] = s.in_buf[s.in_head];
        s.in_head = (s.in_head + 1) % TTY_BUF_LEN;
    }
    return n;
}

fn ttyOnReadAsync(s: *TtyState, pending: fs.PendingRead) fs.HandlerError!fs.ReadOutcome {
    if (s.in_head != s.in_tail) {
        return .{ .immediate = drainTtyIn(s, pending.want) };
    }
    if (@atomicLoad(u32, &s.pending_reply_cap, .acquire) != 0) {
        return .{ .immediate = "" };
    }
    s.pending_tag = pending.tag;
    s.pending_want = pending.want;
    s.pending_fid = pending.fid;
    @atomicStore(u32, &s.pending_reply_cap, pending.reply_cap, .release);
    if (s.in_head != s.in_tail) {
        const claimed = @atomicRmw(u32, &s.pending_reply_cap, .Xchg, @as(u32, 0), .acquire);
        if (claimed != 0) {
            const data = drainTtyIn(s, s.pending_want);
            const p = fs.PendingRead{
                .reply_cap = claimed,
                .tag = s.pending_tag,
                .fid = s.pending_fid,
                .offset = 0,
                .want = 0,
            };
            p.respondRead(data);
        }
    }
    return .deferred;
}

fn ttyOnWrite(s: *TtyState, _: u32, _: u64, data: []const u8) fs.HandlerError!u32 {
    // Raw-mode PTY: client expects CRLF; translate LF -> CRLF.
    for (data) |b| {
        if (b == '\n') pushTtyOut(s, '\r');
        pushTtyOut(s, b);
    }
    return @intCast(data.len);
}

inline fn pushTtyOut(s: *TtyState, b: u8) void {
    const next = (s.out_tail + 1) % TTY_BUF_LEN;
    if (next == s.out_head) return;
    s.out_buf[s.out_tail] = b;
    s.out_tail = next;
}

fn ttyOnClose(s: *TtyState, _: u32) fs.HandlerError!void {
    if (s.open_count > 0) s.open_count -= 1;
}

fn ttyOnStatus(_: *TtyState, _: u32) fs.HandlerError!ferrite.p9.StatusReply {
    return .{ .kind = .file, .size = 0 };
}

fn ttyServeThread() callconv(.c) noreturn {
    const ch = ferrite.channelCreate(0);
    if (ch < 0) {
        con.print("[sshd.tty] channelCreate failed\n", .{}) catch {};
        while (true) ferrite.yield();
    }
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);
    fs.registerDevice(TTY_DEV_NAME, .char, svc_send) catch |e| {
        con.print("[sshd.tty] registerDevice failed: {t}\n", .{e}) catch {};
        while (true) ferrite.yield();
    };
    const handlers: fs.Handlers(TtyState) = .{
        .on_walk = ttyOnWalk,
        .on_open = ttyOnOpen,
        .on_read = ttyOnRead,
        .on_write = ttyOnWrite,
        .on_close = ttyOnClose,
        .on_status = ttyOnStatus,
        .on_read_async = ttyOnReadAsync,
    };
    fs.serve(TtyState, svc_recv, &tty_state, &handlers);
    while (true) ferrite.yield();
}

fn startTtyServeThread() bool {
    var stack_va: usize = 0;
    if (ferrite.allocPages(TTY_STACK_PAGES, &stack_va) != 0) return false;
    const stack_top = stack_va + TTY_STACK_PAGES * ferrite.pageSize() - 16;
    return ferrite.threadSpawn(@intFromPtr(&ttyServeThread), stack_top) >= 0;
}

// tx pump: drains tty_out -> CHANNEL_DATA -> TCP. Post-handshake the main
// thread does only reads, so tx owns the wire.

const TxState = struct {
    sess: ?*Session = null,
    remote_chan: u32 = 0,
    active: u32 = 0,
};

var tx_state: TxState = .{};

/// Userspace spinlock guarding `Session.writePacket`.
var tx_write_lock: u32 = 0;

/// Held during KEX so the channel-data pump doesn't violate RFC 4253 §7.1
/// (no non-KEX traffic between KEXINIT and NEWKEYS).
var tx_paused: u32 = 0;

fn txThread() callconv(.c) noreturn {
    while (true) {
        if (@atomicLoad(u32, &tx_state.active, .acquire) == 0 or
            @atomicLoad(u32, &tx_paused, .acquire) != 0)
        {
            ferrite.nanosleep(20_000_000);
            continue;
        }
        const sess = tx_state.sess.?;
        const rc = tx_state.remote_chan;
        var chunk: [256]u8 = undefined;
        const n = drainTtyOut(&tty_state, &chunk);
        if (n == 0) {
            ferrite.nanosleep(20_000_000);
            continue;
        }
        var pkt_buf: [320]u8 = undefined;
        var pb = Builder.init(&pkt_buf);
        pb.append(MSG_CHANNEL_DATA) catch continue;
        pb.putU32(rc) catch continue;
        pb.putString(chunk[0..n]) catch continue;
        sess.writePacket(pb.slice()) catch |e| {
            con.print("[sshd.tx] writePacket: {t}\n", .{e}) catch {};
            @atomicStore(u32, &tx_state.active, 0, .release);
            continue;
        };
    }
}

fn startTxThread() bool {
    var stack_va: usize = 0;
    if (ferrite.allocPages(TX_STACK_PAGES, &stack_va) != 0) return false;
    const stack_top = stack_va + TX_STACK_PAGES * ferrite.pageSize() - 16;
    return ferrite.threadSpawn(@intFromPtr(&txThread), stack_top) >= 0;
}

// Channel: open session, spawn sh, bridge SSH <-> /dev/ssh.tty.

fn handleSession(sess: *Session) !void {
    var buf: [MAX_PACKET]u8 = undefined;
    const local_chan: u32 = 1;
    var remote_chan: u32 = 0;

    while (true) {
        const m = try sess.readPacket(&buf);
        if (m.len < 1) return error.MalformedPacket;
        switch (m[0]) {
            MSG_GLOBAL_REQUEST => continue,
            MSG_CHANNEL_OPEN => {
                var r: Reader = .{ .data = m[1..] };
                const kind = try r.string();
                remote_chan = try r.u32be();
                _ = try r.u32be(); // client window
                _ = try r.u32be(); // max packet
                if (!std.mem.eql(u8, kind, "session")) {
                    var fail_buf: [128]u8 = undefined;
                    var fb = Builder.init(&fail_buf);
                    try fb.append(MSG_CHANNEL_OPEN_FAILURE);
                    try fb.putU32(remote_chan);
                    try fb.putU32(3); // SSH_OPEN_UNKNOWN_CHANNEL_TYPE
                    try fb.putString("unsupported");
                    try fb.putString("");
                    try sess.writePacket(fb.slice());
                    continue;
                }
                break;
            },
            else => continue,
        }
    }

    var conf_buf: [64]u8 = undefined;
    var cb = Builder.init(&conf_buf);
    try cb.append(MSG_CHANNEL_OPEN_CONFIRMATION);
    try cb.putU32(remote_chan);
    try cb.putU32(local_chan);
    try cb.putU32(32768);
    try cb.putU32(16384);
    try sess.writePacket(cb.slice());

    while (true) {
        const m = try sess.readPacket(&buf);
        if (m.len < 1) return error.MalformedPacket;
        if (m[0] == MSG_CHANNEL_REQUEST) {
            var r: Reader = .{ .data = m[1..] };
            _ = try r.u32be();
            const req_type = try r.string();
            const want_reply = (try r.u8c()) != 0;
            if (std.mem.eql(u8, req_type, "shell") or std.mem.eql(u8, req_type, "exec")) {
                if (want_reply) try sendChannelSuccess(sess, remote_chan);
                break;
            }
            if (want_reply) try sendChannelSuccess(sess, remote_chan);
            continue;
        }
        if (m[0] == MSG_CHANNEL_WINDOW_ADJUST) continue;
        if (m[0] == MSG_CHANNEL_DATA) continue;
    }

    // One TtyState shared across connections; sshd serves one at a time.
    tty_state.in_head = 0;
    tty_state.in_tail = 0;
    tty_state.out_head = 0;
    tty_state.out_tail = 0;

    var arg_buf: [64]u8 = undefined;
    @memcpy(arg_buf[0..6], "--tty=");
    const dev_path = "/dev/" ++ TTY_DEV_NAME;
    @memcpy(arg_buf[6..][0..dev_path.len], dev_path);
    arg_buf[6 + dev_path.len] = 0;
    const child = ferrite.spawnArgs("bin/sh", arg_buf[0 .. 6 + dev_path.len + 1]);
    if (child < 0) {
        const banner_err = "Failed to spawn sh.\r\n";
        var dat_buf: [64]u8 = undefined;
        var db = Builder.init(&dat_buf);
        try db.append(MSG_CHANNEL_DATA);
        try db.putU32(remote_chan);
        try db.putString(banner_err);
        try sess.writePacket(db.slice());
        try sendChannelEof(sess, remote_chan);
        try sendChannelClose(sess, remote_chan);
        return;
    }
    const child_handle: u32 = @intCast(child);

    tx_state.sess = sess;
    tx_state.remote_chan = remote_chan;
    @atomicStore(u32, &tx_state.active, 1, .release);
    defer @atomicStore(u32, &tx_state.active, 0, .release);

    const v_s_str = std.mem.trimEnd(u8, VERSION_LINE, "\r\n");
    while (true) {
        if (ferrite.tryWait(child_handle) >= 1) break;

        if (sess.shouldRekey()) {
            // Bail on failure. Counters stay above threshold, so retrying
            // would spin.
            rekey(sess, v_s_str, null) catch |e| {
                con.print("[sshd] rekey: {t}\n", .{e}) catch {};
                return;
            };
        }

        const m = try sess.readPacket(&buf);
        if (m.len < 1) continue;
        switch (m[0]) {
            MSG_KEXINIT => {
                rekey(sess, v_s_str, m) catch |e| {
                    con.print("[sshd] client-rekey: {t}\n", .{e}) catch {};
                    return;
                };
            },
            MSG_CHANNEL_DATA => {
                var r: Reader = .{ .data = m[1..] };
                _ = try r.u32be();
                const payload = try r.string();
                pushTtyIn(&tty_state, payload);
            },
            MSG_CHANNEL_EOF => {},
            MSG_CHANNEL_CLOSE => break,
            MSG_CHANNEL_WINDOW_ADJUST => {},
            MSG_CHANNEL_REQUEST => {
                var r: Reader = .{ .data = m[1..] };
                _ = try r.u32be();
                _ = try r.string();
                const want_reply = (try r.u8c()) != 0;
                if (want_reply) try sendChannelSuccess(sess, remote_chan);
            },
            else => {},
        }
    }

    if (ferrite.tryWait(child_handle) < 1) _ = ferrite.kill(child_handle);
    _ = ferrite.wait(child_handle);

    @atomicStore(u32, &tx_state.active, 0, .release);
    var flush_buf: [256]u8 = undefined;
    while (true) {
        const n = drainTtyOut(&tty_state, &flush_buf);
        if (n == 0) break;
        var pkt_buf: [320]u8 = undefined;
        var pb = Builder.init(&pkt_buf);
        try pb.append(MSG_CHANNEL_DATA);
        try pb.putU32(remote_chan);
        try pb.putString(flush_buf[0..n]);
        try sess.writePacket(pb.slice());
    }

    try sendChannelEof(sess, remote_chan);
    try sendChannelClose(sess, remote_chan);
}

fn sendChannelEof(sess: *Session, remote_chan: u32) !void {
    var eof_buf: [8]u8 = undefined;
    var eb = Builder.init(&eof_buf);
    try eb.append(MSG_CHANNEL_EOF);
    try eb.putU32(remote_chan);
    try sess.writePacket(eb.slice());
}

fn sendChannelClose(sess: *Session, remote_chan: u32) !void {
    var cls_buf: [8]u8 = undefined;
    var clb = Builder.init(&cls_buf);
    try clb.append(MSG_CHANNEL_CLOSE);
    try clb.putU32(remote_chan);
    try sess.writePacket(clb.slice());
}

fn sendChannelSuccess(sess: *Session, remote_chan: u32) !void {
    var buf: [8]u8 = undefined;
    var b = Builder.init(&buf);
    try b.append(MSG_CHANNEL_SUCCESS);
    try b.putU32(remote_chan);
    try sess.writePacket(b.slice());
}

// Per-connection driver.

fn driveConnection(tcp: *TcpHandle, host_key: Ed25519.KeyPair) !void {
    try tcp.writeAll(VERSION_LINE);
    var line_buf: [256]u8 = undefined;
    const client_line = try tcp.readLine(&line_buf);
    const v_c = std.mem.trimEnd(u8, client_line, "\r\n");
    if (!std.mem.startsWith(u8, v_c, "SSH-2.0-")) return error.BadVersion;
    const v_s = std.mem.trimEnd(u8, VERSION_LINE, "\r\n");

    var session: Session = .{ .tcp = tcp, .host_key = host_key };

    var cookie: [16]u8 = undefined;
    try randomBytes(&cookie);
    var i_s_buf: [1024]u8 = undefined;
    const i_s = try buildKexinit(&i_s_buf, &cookie);
    try session.writePacket(i_s);

    var i_c_buf: [MAX_PACKET]u8 = undefined;
    const i_c_full = try session.readPacket(&i_c_buf);
    if (i_c_full.len < 1 or i_c_full[0] != MSG_KEXINIT) return error.UnexpectedMsg;

    const kex_result = try runKex(&session, v_c, v_s, i_c_full, i_s, null);

    // RFC 4253 §6.4: seq numbers do NOT reset at NEWKEYS; chacha20-poly1305's
    // nonce derives from seq, so resetting would break it.
    session.tx.key = kex_result.s2c_key;
    session.rx.key = kex_result.c2s_key;
    session.tx.active = true;
    session.rx.active = true;
    session.session_id = kex_result.session_id;
    session.have_session_id = true;
    if (v_c.len <= session.v_c_buf.len) {
        @memcpy(session.v_c_buf[0..v_c.len], v_c);
        session.v_c_len = @intCast(v_c.len);
    }
    session.resetRekeyCounters();

    try handleAuth(&session);
    try handleSession(&session);
}

// Top-level: listen on :22, accept, drive.

pub fn main() void {
    openRng() catch |e| {
        con.print("[sshd] /dev/random open: {t}\n", .{e}) catch {};
        return;
    };
    con.print("[sshd] generating host key\n", .{}) catch {};
    var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
    randomBytes(&seed) catch |e| {
        con.print("[sshd] no entropy: {t}\n", .{e}) catch {};
        return;
    };
    const host_key = Ed25519.KeyPair.generateDeterministic(seed) catch |e| {
        con.print("[sshd] ed25519 keygen: {t}\n", .{e}) catch {};
        return;
    };
    con.print("[sshd] host key ready; binding port 22\n", .{}) catch {};

    if (!startTtyServeThread()) {
        con.print("[sshd] failed to start tty service\n", .{}) catch {};
        return;
    }
    if (!startTxThread()) {
        con.print("[sshd] failed to start tx pump\n", .{}) catch {};
        return;
    }

    const listener = listenOnPort(22) catch |e| {
        con.print("[sshd] listen failed: {t}\n", .{e}) catch {};
        return;
    };
    con.print("[sshd] listening on tcp/{d} (port 22)\n", .{listener}) catch {};

    while (true) {
        const child_idx = waitAccept(listener) catch |e| {
            con.print("[sshd] accept failed: {t}\n", .{e}) catch {};
            ferrite.nanosleep(500_000_000);
            continue;
        };
        con.print("[sshd] connection on tcp/{d}\n", .{child_idx}) catch {};

        if (TcpHandle.open(child_idx)) |opened| {
            var tcp = opened;
            driveConnection(&tcp, host_key) catch |e| {
                con.print("[sshd] driver: {t}\n", .{e}) catch {};
            };
            tcp.close();
        } else |e| {
            con.print("[sshd] open child {d}: {t}\n", .{ child_idx, e }) catch {};
        }

        // svc.net's onClose only frees the fid; the TcpSocket slot (cap 8)
        // needs an explicit `release` or the next SYN finds no free socket.
        releaseChild(child_idx) catch |e| {
            con.print("[sshd] release child {d}: {t}\n", .{ child_idx, e }) catch {};
        };
    }
}

fn releaseChild(idx: u8) !void {
    var ctl = try openCtl(idx);
    defer ctl.close();
    _ = try ctl.writeAll("release");
}
