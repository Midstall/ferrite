const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

pub fn main() void {
    const argv = ferrite.argv;
    const arg = if (argv.len >= 2) std.mem.span(argv[1]) else "/";

    // Virtual roots (e.g. /sys) have no backing file; list mounts under them.
    var mounts_buf: [256]u8 = undefined;
    const mounts_len = ferrite.fs.listMountsAt(arg, &mounts_buf) catch 0;

    var uri_buf: [256]u8 = undefined;
    const uri_or = ferrite.fs.resolvePath(arg, &uri_buf);
    if (uri_or) |uri| {
        if (ferrite.fs.open(uri, .{ .mode = .read })) |file| {
            defer file.close();
            var buf: [256]u8 = undefined;
            var off: u64 = 0;
            while (true) {
                const n = file.read(off, &buf) catch |e| {
                    ferrite.console.print("ls: read: {t}\n", .{e}) catch {};
                    break;
                };
                if (n == 0) break;
                ferrite.console.print("{s}", .{buf[0..n]}) catch {};
                off += n;
            }
        } else |e| switch (e) {
            error.NotFound => if (mounts_len == 0) {
                ferrite.console.print("ls: {s}: {t}\n", .{ arg, e }) catch {};
                return;
            },
            else => {
                ferrite.console.print("ls: {s}: {t}\n", .{ arg, e }) catch {};
                return;
            },
        }
    } else |_| {
        if (mounts_len == 0) {
            ferrite.console.print("ls: bad path: {s}\n", .{arg}) catch {};
            return;
        }
    }

    if (mounts_len == 0) return;
    var it = std.mem.tokenizeScalar(u8, mounts_buf[0..mounts_len], 0);
    while (it.next()) |name| {
        ferrite.console.print("{s}\n", .{name}) catch {};
    }
}
