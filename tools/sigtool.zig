// Sign expects an existing LC_CODE_SIGNATURE blob region sized for
// SigBlobHeader + 64-byte Ed25519 signature (elf2macho emits this shape).
// Digest = SHA-256 over the image with the sig region bytes zeroed.

const std = @import("std");
const Io = std.Io;
const common = @import("common");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    if (args.len < 2) {
        usage(io, args[0]);
        return error.BadUsage;
    }
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "sign")) {
        return cmdSign(arena, io, args[2..]);
    } else if (std.mem.eql(u8, cmd, "verify")) {
        return cmdVerify(arena, io, args[2..]);
    } else {
        usage(io, args[0]);
        return error.BadUsage;
    }
}

fn usage(io: Io, prog: []const u8) void {
    common.stdoutPrint(io,
        \\usage:
        \\  {s} sign   <key.key>    <input.macho>
        \\  {s} verify <pubkey.pub> <input.macho>
        \\
    , .{ prog, prog });
}

fn cmdSign(arena: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    if (args.len != 2) return error.BadUsage;
    const key_path = args[0];
    const file_path = args[1];

    const cwd: Io.Dir = .cwd();
    const kp = try common.loadKey(cwd, io, key_path);
    const pub_bytes = kp.public_key.toBytes();
    var keyid: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&pub_bytes, &keyid, .{});

    var bytes = try common.readAll(arena, cwd, io, file_path);

    const sigreg = common.findSignatureRegion(bytes) orelse return error.NoSigSection;
    if (sigreg.size < common.SIG_BLOB_SIZE) return error.SigRegionTooSmall;

    const hdr: common.SigBlobHeader = .{
        .magic = common.SIG_MAGIC,
        .version = 1,
        .algo = @intFromEnum(common.SigAlgo.ed25519),
        .keyid = keyid,
        .sig_len = 64,
    };
    @memcpy(bytes[sigreg.off..][0..@sizeOf(common.SigBlobHeader)], std.mem.asBytes(&hdr));
    // Zero trailing slack so producer state doesn't leak into the hashed area.
    @memset(bytes[sigreg.off + @sizeOf(common.SigBlobHeader) + 64 .. sigreg.off + sigreg.size], 0);
    try common.signInPlace(bytes, &kp);

    try common.writeAll(cwd, io, file_path, bytes);
}

fn cmdVerify(arena: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    if (args.len != 2) return error.BadUsage;
    const pub_path = args[0];
    const file_path = args[1];

    const cwd: Io.Dir = .cwd();

    // .pub format: u16 LE algo + raw key. Mirrors kernel/src/signature.zig.
    const pub_bytes = try common.readAll(arena, cwd, io, pub_path);
    if (pub_bytes.len < 2) return error.BadPubkey;
    const algo: common.SigAlgo = @enumFromInt(std.mem.readInt(u16, pub_bytes[0..2], .little));
    if (algo != .ed25519) return error.UnsupportedAlgo;
    const raw_pub = pub_bytes[2..];
    if (raw_pub.len != std.crypto.sign.Ed25519.PublicKey.encoded_length) return error.BadPubkey;
    var expect_keyid: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw_pub, &expect_keyid, .{});

    const bytes = try common.readAll(arena, cwd, io, file_path);
    const sigreg = common.findSignatureRegion(bytes) orelse return error.NoSigSection;
    if (sigreg.size < @sizeOf(common.SigBlobHeader) + 64) return error.SigRegionTooSmall;

    const blob = bytes[sigreg.off..][0..sigreg.size];
    const hdr = std.mem.bytesAsValue(common.SigBlobHeader, blob[0..@sizeOf(common.SigBlobHeader)]).*;
    if (hdr.magic != common.SIG_MAGIC) return error.BadMagic;
    if (!std.mem.eql(u8, &hdr.keyid, &expect_keyid)) return error.KeyMismatch;
    if (hdr.algo != @intFromEnum(common.SigAlgo.ed25519)) return error.AlgoMismatch;
    if (hdr.sig_len != 64) return error.BadSigLen;

    const digest = common.computeDigest(bytes, sigreg);
    common.stdoutPrint(io, "digest=", .{});
    for (digest) |b| common.stdoutPrint(io, "{x:0>2}", .{b});
    common.stdoutPrint(io, " len={d} sig_off={d} sig_size={d}\n", .{ bytes.len, sigreg.off, sigreg.size });
    const sig_bytes = blob[@sizeOf(common.SigBlobHeader)..][0..64];
    const sig = std.crypto.sign.Ed25519.Signature.fromBytes(sig_bytes.*);
    var pk_bytes: [32]u8 = undefined;
    @memcpy(&pk_bytes, raw_pub);
    const pk = try std.crypto.sign.Ed25519.PublicKey.fromBytes(pk_bytes);
    sig.verify(&digest, pk) catch return error.BadSignature;
}
