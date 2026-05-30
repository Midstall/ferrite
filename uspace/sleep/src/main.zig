const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

pub fn main() void {
    const argv = ferrite.argv;
    if (argv.len < 2) {
        ferrite.console.print("usage: sleep <seconds>\n", .{}) catch {};
        return;
    }
    const arg = std.mem.span(argv[1]);
    const seconds = std.fmt.parseUnsigned(u64, arg, 10) catch {
        ferrite.console.print("sleep: bad number: {s}\n", .{arg}) catch {};
        return;
    };
    ferrite.nanosleep(seconds * 1_000_000_000);
}
