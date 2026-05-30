const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

pub fn main() void {
    var buf: [1024]u8 = undefined;
    const n = ferrite.fs.dumpMounts(&buf) catch |e| {
        ferrite.console.print("mount: dump failed: {t}\n", .{e}) catch {};
        return;
    };
    if (n == 0) {
        ferrite.console.print("(no mounts)\n", .{}) catch {};
        return;
    }
    var lines = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
    ferrite.console.print("{s:<12} {s}\n", .{ "PREFIX", "AUTHORITY" }) catch {};
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const prefix = line[0..tab];
        const authority = line[tab + 1 ..];
        ferrite.console.print("{s:<12} {s}\n", .{ prefix, authority }) catch {};
    }
}
