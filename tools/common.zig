// Mirrors kernel/src/macho.zig + kernel/src/signature.zig. Keep in sync.

const std = @import("std");
const Io = std.Io;
const macho = std.macho;

// --- Ferrite-extension wire structs -----------------------------------------

pub const LC_FERRITE_AUTH: u32 = 0x1000;

pub const FerriteAuthCommand = extern struct {
    cmd: u32 = LC_FERRITE_AUTH,
    cmdsize: u32 = @sizeOf(FerriteAuthCommand),
    authority: u32 = 0,
    manifest_count: u32 = 0,
};

/// PIE pointer-rebase table: `count` (r_offset, r_addend) pairs; loader writes
/// `r_addend + slide` at `r_offset + slide`.
pub const LC_FERRITE_REBASE: u32 = 0x1001;

pub const FerriteRebaseCommand = extern struct {
    cmd: u32 = LC_FERRITE_REBASE,
    cmdsize: u32 = @sizeOf(FerriteRebaseCommand),
    count: u32 = 0,
    _pad: u32 = 0,
};

pub const FerriteRebaseEntry = extern struct {
    r_offset: u64,
    r_addend: u64,
};

pub const SIG_MAGIC: u32 = std.mem.bytesToValue(u32, "FERS");

pub const SigAlgo = enum(u16) {
    none = 0,
    ed25519 = 1,
    ecdsa_p256_sha256 = 2,
};

pub const SigBlobHeader = extern struct {
    magic: u32,
    version: u16,
    algo: u16,
    keyid: [32]u8,
    sig_len: u32,
    _pad: u32 = 0,
};

pub const SIG_BLOB_SIZE: usize = @sizeOf(SigBlobHeader) + 64; // Ed25519 sig = 64 bytes

// --- file helpers ----------------------------------------------------------

pub fn loadKey(cwd: Io.Dir, io: Io, path: []const u8) !std.crypto.sign.Ed25519.KeyPair {
    const key_file = try cwd.openFile(io, path, .{});
    defer key_file.close(io);
    var key_bytes: [std.crypto.sign.Ed25519.SecretKey.encoded_length]u8 = undefined;
    var reader_buf: [64]u8 = undefined;
    var rs: Io.File.Reader = .init(key_file, io, &reader_buf);
    const r = &rs.interface;
    try r.readSliceAll(&key_bytes);
    const sk = try std.crypto.sign.Ed25519.SecretKey.fromBytes(key_bytes);
    return try std.crypto.sign.Ed25519.KeyPair.fromSecretKey(sk);
}

/// .pub format: u16 LE algo + raw pubkey.
pub fn loadPubKey(arena: std.mem.Allocator, cwd: Io.Dir, io: Io, path: []const u8) ![]const u8 {
    return try readAll(arena, cwd, io, path);
}

pub fn readAll(arena: std.mem.Allocator, cwd: Io.Dir, io: Io, path: []const u8) ![]u8 {
    const file = try cwd.openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try arena.alloc(u8, @intCast(stat.size));
    var reader_buf: [4096]u8 = undefined;
    var rs: Io.File.Reader = .init(file, io, &reader_buf);
    const r = &rs.interface;
    try r.readSliceAll(buf);
    return buf;
}

pub fn writeAll(cwd: Io.Dir, io: Io, path: []const u8, bytes: []const u8) !void {
    const out = try cwd.createFile(io, path, .{});
    defer out.close(io);
    try out.writeStreamingAll(io, bytes);
}

/// Stdout (not stderr): the build runner surfaces stderr as "failed command:" noise.
pub fn stdoutPrint(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const f = Io.File.stdout();
    f.writeStreamingAll(io, msg) catch {};
}

// --- Mach-O helpers --------------------------------------------------------

pub const SigRegion = struct { off: usize, size: usize };

/// Returns LC_CODE_SIGNATURE's data range, or null if absent / not a Mach-O64.
pub fn findSignatureRegion(bytes: []const u8) ?SigRegion {
    if (bytes.len < @sizeOf(macho.mach_header_64)) return null;
    const magic = std.mem.readInt(u32, bytes[0..4], .little);
    if (magic != macho.MH_MAGIC_64) return null;
    const hdr = std.mem.bytesAsValue(macho.mach_header_64, bytes[0..@sizeOf(macho.mach_header_64)]).*;

    var cur: usize = @sizeOf(macho.mach_header_64);
    var i: u32 = 0;
    while (i < hdr.ncmds) : (i += 1) {
        if (cur + @sizeOf(macho.load_command) > bytes.len) return null;
        const lc = std.mem.bytesAsValue(macho.load_command, bytes[cur..][0..@sizeOf(macho.load_command)]).*;
        if (@intFromEnum(lc.cmd) == @intFromEnum(macho.LC.CODE_SIGNATURE)) {
            if (lc.cmdsize < @sizeOf(macho.linkedit_data_command)) return null;
            const led = std.mem.bytesAsValue(
                macho.linkedit_data_command,
                bytes[cur..][0..@sizeOf(macho.linkedit_data_command)],
            ).*;
            return .{ .off = @intCast(led.dataoff), .size = @intCast(led.datasize) };
        }
        cur += lc.cmdsize;
    }
    return null;
}

/// SHA-256 over the image with bytes inside the sig region masked to zero.
pub fn computeDigest(bytes: []const u8, sigreg: SigRegion) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes[0..sigreg.off]);
    var zero_buf: [128]u8 = @splat(0);
    var remaining: usize = sigreg.size;
    while (remaining > 0) {
        const chunk = @min(remaining, zero_buf.len);
        hasher.update(zero_buf[0..chunk]);
        remaining -= chunk;
    }
    hasher.update(bytes[sigreg.off + sigreg.size ..]);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

/// Caller must have populated the blob header (algo, keyid, sig_len) first.
pub fn signInPlace(bytes: []u8, kp: *const std.crypto.sign.Ed25519.KeyPair) !void {
    const sigreg = findSignatureRegion(bytes) orelse return error.NoSigSection;
    const digest = computeDigest(bytes, sigreg);
    const sig = try kp.sign(&digest, null);
    const sig_bytes = sig.toBytes();
    @memcpy(bytes[sigreg.off + @sizeOf(SigBlobHeader) ..][0..64], &sig_bytes);
}

pub fn strName(comptime name: []const u8) [16]u8 {
    var out: [16]u8 = @splat(0);
    @memcpy(out[0..name.len], name);
    return out;
}

pub fn alignUp(x: u64, a: u64) u64 {
    return (x + a - 1) & ~(a - 1);
}
