// readlink <path>: print a symbolic link's target.
const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

pub fn main() void {
    const argv = ferrite.argv;
    if (argv.len < 2) {
        ferrite.console.print("usage: readlink <path>\n", .{}) catch {};
        return;
    }
    const path = std.mem.span(argv[1]);
    var buf: [256]u8 = undefined;
    const n = ferrite.fs.readlink(path, &buf) catch |e| {
        ferrite.console.print("readlink: {s}: {t}\n", .{ path, e }) catch {};
        return;
    };
    ferrite.console.print("{s}\n", .{buf[0..n]}) catch {};
}
