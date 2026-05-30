const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

pub fn main() void {
    var info: ferrite.UnameInfo = undefined;
    if (ferrite.uname(&info) != 0) {
        ferrite.console.print("uname: SYS_UNAME failed\n", .{}) catch {};
        return;
    }
    ferrite.console.print("{s} {s} {s}\n", .{
        info.fieldSlice("name"),
        info.fieldSlice("version"),
        info.fieldSlice("arch"),
    }) catch {};
}
