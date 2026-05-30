// rmdir <dir>: remove an empty directory.
const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

pub fn main() void {
    const argv = ferrite.argv;
    if (argv.len < 2) {
        ferrite.console.print("usage: rmdir <dir>\n", .{}) catch {};
        return;
    }
    const path = std.mem.span(argv[1]);
    ferrite.fs.remove(path) catch |e| {
        ferrite.console.print("rmdir: {s}: {t}\n", .{ path, e }) catch {};
    };
}
