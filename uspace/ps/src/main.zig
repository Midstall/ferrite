const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

const MAX = 32;

pub fn main() void {
    var buf: [MAX]ferrite.ProcEntry = undefined;
    const n = ferrite.procList(buf[0..]);
    ferrite.console.print("{s:>5} {s:>5} NAME\n", .{ "PID", "STATE" }) catch {};
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e = &buf[i];
        const tag: []const u8 = if (e.state & 1 != 0) "R" else "Z";
        ferrite.console.print("{d:>5} {s:>5} {s}\n", .{ e.pid, tag, e.nameSlice() }) catch {};
    }
}
