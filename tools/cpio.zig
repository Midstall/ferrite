// Flat-only cpio newc writer: regular files only, mode 0o100644, uid/gid/mtime=0.
// Names are stored relative (no leading slash); kernel/src/initrd.zig matches that.

const std = @import("std");
const Io = std.Io;
const common = @import("common");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    if (args.len < 2) {
        common.stdoutPrint(io, "usage: {s} <out.cpio> <name=path|dir:prefix=path>...\n", .{args[0]});
        return error.BadUsage;
    }
    const out_path = args[1];
    const entries = args[2..];

    const cwd: Io.Dir = .cwd();

    var out: std.ArrayList(u8) = .empty;
    var ino: u32 = 1;
    for (entries) |spec| {
        if (std.mem.startsWith(u8, spec, "dir:")) {
            const rest = spec[4..];
            const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return error.BadUsage;
            const prefix = rest[0..eq];
            const path = rest[eq + 1 ..];
            try addDir(arena, &out, &ino, cwd, io, prefix, path);
        } else {
            const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return error.BadUsage;
            const name = spec[0..eq];
            const path = spec[eq + 1 ..];
            const data = try common.readAll(arena, cwd, io, path);
            try writeEntry(arena, &out, name, data, 0o100644, ino);
            ino += 1;
        }
    }
    try writeEntry(arena, &out, "TRAILER!!!", &.{}, 0, ino);

    try common.writeAll(cwd, io, out_path, out.items);
}

fn addDir(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    ino_ptr: *u32,
    cwd: Io.Dir,
    io: Io,
    prefix: []const u8,
    root_path: []const u8,
) !void {
    var dir = try cwd.openDir(io, root_path, .{ .iterate = true });
    defer dir.close(io);
    var w = try dir.walk(arena);
    defer w.deinit();
    while (try w.next(io)) |entry| {
        if (entry.kind != .file) continue;
        var name_buf: std.ArrayList(u8) = .empty;
        if (prefix.len > 0) {
            try name_buf.appendSlice(arena, prefix);
            try name_buf.append(arena, '/');
        }
        try name_buf.appendSlice(arena, entry.path);
        for (name_buf.items) |*c| if (c.* == '\\') {
            c.* = '/';
        };
        var rel_path: std.ArrayList(u8) = .empty;
        try rel_path.appendSlice(arena, root_path);
        try rel_path.append(arena, '/');
        try rel_path.appendSlice(arena, entry.path);
        const data = try common.readAll(arena, cwd, io, rel_path.items);
        try writeEntry(arena, out, name_buf.items, data, 0o100644, ino_ptr.*);
        ino_ptr.* += 1;
    }
}

fn writeEntry(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    data: []const u8,
    mode: u32,
    ino: u32,
) !void {
    // cpio newc header: 6-byte magic + 13 × 8-char ASCII-hex fields = 110 bytes.
    var header: [110]u8 = undefined;
    @memcpy(header[0..6], "070701");
    writeHex(header[6..][0..8], ino);
    writeHex(header[14..][0..8], mode);
    writeHex(header[22..][0..8], 0); // uid
    writeHex(header[30..][0..8], 0); // gid
    writeHex(header[38..][0..8], 1); // nlink
    writeHex(header[46..][0..8], 0); // mtime
    writeHex(header[54..][0..8], @intCast(data.len));
    writeHex(header[62..][0..8], 0); // devmajor
    writeHex(header[70..][0..8], 0); // devminor
    writeHex(header[78..][0..8], 0); // rdevmajor
    writeHex(header[86..][0..8], 0); // rdevminor
    writeHex(header[94..][0..8], @intCast(name.len + 1)); // namesize incl NUL
    writeHex(header[102..][0..8], 0); // check

    try out.appendSlice(arena, &header);
    try out.appendSlice(arena, name);
    try out.append(arena, 0);
    while (out.items.len % 4 != 0) try out.append(arena, 0);
    try out.appendSlice(arena, data);
    while (out.items.len % 4 != 0) try out.append(arena, 0);
}

fn writeHex(dst: *[8]u8, val: u32) void {
    const hex = "0123456789abcdef";
    var v = val;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        dst[i] = hex[v & 0xf];
        v >>= 4;
    }
}
