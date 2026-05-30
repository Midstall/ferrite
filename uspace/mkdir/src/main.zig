const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

pub fn main() void {
    const argv = ferrite.argv;
    if (argv.len < 2) {
        ferrite.console.print("usage: mkdir <path>\n", .{}) catch {};
        return;
    }
    const path = std.mem.span(argv[1]);
    ferrite.fs.create(path, .dir) catch |e| {
        ferrite.console.print("mkdir: {s}: {t}\n", .{ path, e }) catch {};
    };
}
