// Signed message = SHA-256 of the thin Mach-O image with `sig_off..sig_off+sig_size` zeroed.
// Blob: "FERS" | u16 version=1 | u16 algo | u8[32] keyid (SHA-256(pubkey)[0..32]) |
//       u32 sig_len | u32 _pad | u8[sig_len] signature.

const std = @import("std");
const arch = @import("arch");
const heap = @import("heap.zig");
const initrd = @import("initrd.zig");
const kernel_options = @import("kernel-options");

pub const Status = enum {
    warning,
    enforcing,
};

pub var status: Status = .warning;

pub const Algo = enum(u16) {
    none = 0,
    ed25519 = 1,
    ecdsa_p256_sha256 = 2,
    _,
};

pub const Error = error{
    BadMagic,
    BadVersion,
    BadAlgo,
    Truncated,
    UnknownKey,
    BadSignature,
    Unsigned,
    UnsupportedAlgo,
    TooManyKeys,
    OutOfMemory,
};

pub const SIG_MAGIC: u32 = std.mem.bytesToValue(u32, "FERS");

pub const BlobHeader = extern struct {
    magic: u32,
    version: u16,
    algo: u16,
    keyid: [32]u8,
    sig_len: u32,
    _pad: u32 = 0,
};

pub const KeyId = [32]u8;

pub const TrustEntry = struct {
    algo: Algo,
    keyid: KeyId,
    /// Valid length: 32 for Ed25519, 65 for ECDSA P-256 (0x04 || X || Y).
    pubkey: [65]u8,
    pubkey_len: u8,
};

const MAX_KEYS: usize = kernel_options.sig_max_keys;
var keys_buf: [MAX_KEYS]TrustEntry = undefined;
var keys_count: usize = 0;

/// Optional hardware backend for Ed25519 verification. When installed, the
/// enforcing-mode verify calls it instead of the software `std.crypto` path.
/// The in-order targets Ferrite runs on (e.g. the Albion SEP) verify Ed25519 in
/// software far too slowly (the Curve25519 double-scalar multiply is hundreds of
/// millions of cycles), so a platform with a verify accelerator installs one
/// here. It receives the on-wire encodings -- 32-byte public key, 64-byte
/// signature (`R || S`), and the 32-byte message digest that was signed -- and
/// returns true iff the signature verifies. Generic: nothing platform-specific
/// lives in the kernel, only this hook.
pub const Ed25519Backend = *const fn (
    pubkey: *const [32]u8,
    sig: *const [64]u8,
    digest: *const [32]u8,
) bool;
pub var ed25519_backend: ?Ed25519Backend = null;

pub fn keyCount() usize {
    return keys_count;
}

/// Per-record encoding: u16 little-endian `Algo`, then raw pubkey bytes.
pub fn init() void {
    keys_count = 0;
    status = .warning;
    if (!initrd.isPresent()) {
        warnBanner("no initrd present");
        return;
    }
    initrd.forEachWithPrefix("keys/", {}, registerKeyRecord) catch |e| {
        arch.uart.print("[sig] initrd walk failed: {s}\n", .{@errorName(e)});
    };
    if (keys_count > 0) {
        status = .enforcing;
    } else {
        warnBanner("no keys/* records found in initrd");
    }
}

fn warnBanner(reason: []const u8) void {
    arch.uart.write("\n");
    arch.uart.write("================ FERRITE WARNING ================\n");
    arch.uart.write("Code signing is in PERMISSIVE / WARNING mode:\n  ");
    arch.uart.write(reason);
    arch.uart.write("\nAll binaries will load regardless of signature.\n");
    arch.uart.write("=================================================\n\n");
}

fn registerKeyRecord(_: void, rec: initrd.Record) void {
    if (rec.data.len < 2) return;
    const algo: Algo = @enumFromInt(std.mem.readInt(u16, rec.data[0..2], .little));
    const pub_bytes = rec.data[2..];

    const expect_len: usize = switch (algo) {
        .ed25519 => 32,
        .ecdsa_p256_sha256 => 65,
        else => return,
    };
    if (pub_bytes.len != expect_len) return;
    if (keys_count >= MAX_KEYS) return;

    var entry: TrustEntry = .{
        .algo = algo,
        .keyid = undefined,
        .pubkey = @splat(0),
        .pubkey_len = @intCast(pub_bytes.len),
    };
    @memcpy(entry.pubkey[0..pub_bytes.len], pub_bytes);

    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pub_bytes, &h, .{});
    entry.keyid = h;

    keys_buf[keys_count] = entry;
    keys_count += 1;
}

fn findKey(id: KeyId) ?*const TrustEntry {
    var i: usize = 0;
    while (i < keys_count) : (i += 1) {
        if (std.mem.eql(u8, &keys_buf[i].keyid, &id)) return &keys_buf[i];
    }
    return null;
}

pub fn verify(image_bytes: []const u8, sig_off: u64, sig_size: u64) Error!void {
    if (sig_size == 0) {
        switch (status) {
            .warning => {
                arch.uart.write("[sig] WARNING: loading unsigned binary (no trust roots)\n");
                return;
            },
            .enforcing => return error.Unsigned,
        }
    }

    const off_usize: usize = @intCast(sig_off);
    const sz_usize: usize = @intCast(sig_size);
    const sig_end = off_usize + sz_usize;
    if (sig_end > image_bytes.len) return error.Truncated;
    if (sz_usize < @sizeOf(BlobHeader)) return error.Truncated;

    const blob_bytes = image_bytes[off_usize..sig_end];
    const hdr = std.mem.bytesAsValue(BlobHeader, blob_bytes[0..@sizeOf(BlobHeader)]).*;
    if (hdr.magic != SIG_MAGIC) return error.BadMagic;
    if (hdr.version != 1) return error.BadVersion;

    const sig_payload_end = @sizeOf(BlobHeader) + @as(usize, hdr.sig_len);
    if (sig_payload_end > blob_bytes.len) return error.Truncated;
    const sig_payload = blob_bytes[@sizeOf(BlobHeader)..sig_payload_end];

    if (status == .warning) {
        arch.uart.write("[sig] WARNING: signed binary accepted without trust check\n");
        return;
    }

    const key = findKey(hdr.keyid) orelse return error.UnknownKey;
    if (key.algo != @as(Algo, @enumFromInt(hdr.algo))) return error.BadAlgo;

    // Retry: ReleaseFast on riscv64 + i386 has shown intermittent failure
    // where the digest computation reads stale bytes mid-stream (suspected
    // page-allocator-vs-initrd window). Recomputing 1-2 times stabilises.
    var digest: [32]u8 = undefined;
    var attempt: u8 = 0;
    while (attempt < 8) : (attempt += 1) {
        rehash(image_bytes, off_usize, sz_usize, sig_end, &digest);
        verifyOne(key, @enumFromInt(hdr.algo), &digest, sig_payload) catch |e| {
            if (attempt + 1 == 8) {
                arch.uart.print("[sig] EXHAUSTED retries: {s}\n", .{@errorName(e)});
                return e;
            }
            continue;
        };
        if (attempt > 0) arch.uart.print("[sig] OK after {d} retries\n", .{attempt});
        return;
    }
}

fn rehash(image_bytes: []const u8, off_usize: usize, sz_usize: usize, sig_end: usize, out: *[32]u8) void {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(image_bytes[0..off_usize]);
    var zb: [128]u8 = @splat(0);
    var rem: usize = sz_usize;
    while (rem > 0) {
        const c = @min(rem, zb.len);
        h.update(zb[0..c]);
        rem -= c;
    }
    h.update(image_bytes[sig_end..]);
    h.final(out);
}

fn verifyOne(key: *const TrustEntry, algo: Algo, digest: *const [32]u8, sig_payload: []const u8) Error!void {
    switch (algo) {
        .ed25519 => {
            if (sig_payload.len != std.crypto.sign.Ed25519.Signature.encoded_length) return error.BadSignature;
            if (key.pubkey_len != std.crypto.sign.Ed25519.PublicKey.encoded_length) return error.BadSignature;
            // Hardware offload: if a verify accelerator is installed, use it
            // (the software path below is impractically slow on the in-order SEP).
            if (ed25519_backend) |hw| {
                if (hw(key.pubkey[0..32], sig_payload[0..64], digest)) return;
                return error.BadSignature;
            }
            const sig = std.crypto.sign.Ed25519.Signature.fromBytes(sig_payload[0..std.crypto.sign.Ed25519.Signature.encoded_length].*);
            const pk = std.crypto.sign.Ed25519.PublicKey.fromBytes(
                key.pubkey[0..std.crypto.sign.Ed25519.PublicKey.encoded_length].*,
            ) catch return error.BadSignature;
            sig.verify(digest, pk) catch return error.BadSignature;
        },
        .ecdsa_p256_sha256 => {
            const Ec = std.crypto.sign.ecdsa.EcdsaP256Sha256;
            if (sig_payload.len != Ec.Signature.encoded_length) return error.BadSignature;
            if (key.pubkey_len != Ec.PublicKey.uncompressed_sec1_encoded_length) return error.BadSignature;
            const sig = Ec.Signature.fromBytes(sig_payload[0..Ec.Signature.encoded_length].*);
            const pk = Ec.PublicKey.fromSec1(key.pubkey[0..key.pubkey_len]) catch return error.BadSignature;
            sig.verifyPrehashed(digest.*, pk) catch return error.BadSignature;
        },
        else => return error.UnsupportedAlgo,
    }
}
