const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

pub fn main() void {
    const argv = ferrite.argv;
    if (argv.len < 2) {
        ferrite.console.print("usage: kill <pid>\n", .{}) catch {};
        return;
    }
    const arg = std.mem.span(argv[1]);
    const pid = std.fmt.parseUnsigned(u32, arg, 10) catch {
        ferrite.console.print("kill: bad pid: {s}\n", .{arg}) catch {};
        return;
    };
    if (ferrite.killPid(pid) != 0) {
        ferrite.console.print("kill: no such pid: {d}\n", .{pid}) catch {};
    }
}
