// Ed25519 keypair generator. <pub>: u16 LE algo + 32-byte pubkey.
// <key>: 64-byte raw secret (seed + public). Two output paths so each can flow
// through Zig build's addOutputFileArg.

const std = @import("std");
const Io = std.Io;
const common = @import("common");

const ALGO_ED25519: u16 = 1;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    if (args.len != 3) {
        common.stdoutPrint(io, "usage: {s} <pub.out> <key.out>\n", .{args[0]});
        return error.BadUsage;
    }
    const pub_path = args[1];
    const key_path = args[2];

    const kp = std.crypto.sign.Ed25519.KeyPair.generate(io);

    var pub_buf: [2 + std.crypto.sign.Ed25519.PublicKey.encoded_length]u8 = undefined;
    std.mem.writeInt(u16, pub_buf[0..2], ALGO_ED25519, .little);
    const pub_bytes = kp.public_key.toBytes();
    @memcpy(pub_buf[2..], &pub_bytes);

    const cwd: Io.Dir = .cwd();
    const pub_file = try cwd.createFile(io, pub_path, .{});
    defer pub_file.close(io);
    try pub_file.writeStreamingAll(io, &pub_buf);

    const kp_bytes = kp.secret_key.toBytes();
    const key_file = try cwd.createFile(io, key_path, .{});
    defer key_file.close(io);
    try key_file.writeStreamingAll(io, &kp_bytes);
}
