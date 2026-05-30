// cpio newc parser.

const std = @import("std");

pub const Header = extern struct {
    magic: [6]u8,
    /// ino, mode, uid, gid, nlink, mtime, filesize, devmajor, devminor,
    /// rdevmajor, rdevminor, namesize, check (ASCII hex).
    fields: [13][8]u8,
};

pub const CPIO_NEWC_MAGIC: *const [6]u8 = "070701";
pub const TRAILER: []const u8 = "TRAILER!!!";

const S_IFMT: u32 = 0o170000;
const S_IFREG: u32 = 0o100000;

pub const Record = struct {
    name: []const u8,
    data: []const u8,
    mode: u32,
};

pub const Error = error{
    NotPresent,
    BadMagic,
    Truncated,
    BadField,
};

var image: ?[]const u8 = null;

/// Idempotent.
pub fn init(bytes: []const u8) Error!void {
    if (bytes.len < @sizeOf(Header)) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..6], CPIO_NEWC_MAGIC)) return error.BadMagic;
    image = bytes;
}

pub fn isPresent() bool {
    return image != null;
}

pub fn rawImage() ?[]const u8 {
    return image;
}

pub const Iterator = struct {
    bytes: []const u8,
    cur: usize,

    pub fn next(self: *Iterator) Error!?Record {
        while (true) {
            if (self.cur + @sizeOf(Header) > self.bytes.len) return error.Truncated;
            const hdr = std.mem.bytesAsValue(Header, self.bytes[self.cur..][0..@sizeOf(Header)]).*;
            if (!std.mem.eql(u8, &hdr.magic, CPIO_NEWC_MAGIC)) return error.BadMagic;

            const mode: u32 = @intCast(try parseHex(&hdr.fields[1]));
            const filesize_u = try parseHex(&hdr.fields[6]);
            const namesize_u = try parseHex(&hdr.fields[11]);
            const filesize: usize = @intCast(filesize_u);
            const namesize: usize = @intCast(namesize_u);
            if (namesize == 0) return error.BadField;

            const name_lo = self.cur + @sizeOf(Header);
            const name_hi = name_lo + namesize;
            if (name_hi > self.bytes.len) return error.Truncated;
            const data_lo = std.mem.alignForward(usize, name_hi, 4);
            const data_hi = data_lo + filesize;
            if (data_hi > self.bytes.len) return error.Truncated;
            const after_data = std.mem.alignForward(usize, data_hi, 4);

            const name_with_nul = self.bytes[name_lo..name_hi];
            const name = if (name_with_nul.len > 0 and name_with_nul[name_with_nul.len - 1] == 0)
                name_with_nul[0 .. name_with_nul.len - 1]
            else
                name_with_nul;

            self.cur = after_data;

            if (std.mem.eql(u8, name, TRAILER)) return null;
            if ((mode & S_IFMT) != S_IFREG) continue;

            return .{
                .name = name,
                .data = self.bytes[data_lo..data_hi],
                .mode = mode,
            };
        }
    }
};

pub fn iterator() Error!Iterator {
    const bytes = image orelse return error.NotPresent;
    return .{ .bytes = bytes, .cur = 0 };
}

pub fn find(name: []const u8) Error!?Record {
    var it = try iterator();
    while (try it.next()) |rec| {
        if (std.mem.eql(u8, rec.name, name)) return rec;
    }
    return null;
}

pub fn forEachWithPrefix(
    prefix: []const u8,
    ctx: anytype,
    comptime cb: fn (@TypeOf(ctx), Record) void,
) Error!void {
    var it = try iterator();
    while (try it.next()) |rec| {
        if (std.mem.startsWith(u8, rec.name, prefix)) cb(ctx, rec);
    }
}

fn parseHex(field: *const [8]u8) Error!u64 {
    var v: u64 = 0;
    for (field) |c| {
        const d: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.BadField,
        };
        v = (v << 4) | d;
    }
    return v;
}
