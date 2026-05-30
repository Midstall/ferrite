// ln -s <target> <linkpath>: create a symbolic link.
const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

pub fn main() void {
    const argv = ferrite.argv;
    if (argv.len < 4 or !std.mem.eql(u8, std.mem.span(argv[1]), "-s")) {
        ferrite.console.print("usage: ln -s <target> <linkpath>\n", .{}) catch {};
        return;
    }
    const target = std.mem.span(argv[2]);
    const linkpath = std.mem.span(argv[3]);
    ferrite.fs.symlink(linkpath, target) catch |e| {
        ferrite.console.print("ln: {s}: {t}\n", .{ linkpath, e }) catch {};
    };
}
