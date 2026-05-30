const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

pub fn main() void {
    var info: ferrite.MemInfo = undefined;
    if (ferrite.memInfo(&info) != 0) {
        ferrite.console.print("free: SYS_MEM_INFO failed\n", .{}) catch {};
        return;
    }
    const used = info.total_bytes - info.free_bytes;
    ferrite.console.print("{s:>10} {s:>12} {s:>12} {s:>12}\n", .{ "", "total", "used", "free" }) catch {};
    ferrite.console.print("{s:>10} {d:>10}MiB {d:>10}MiB {d:>10}MiB\n", .{
        "Mem:",
        info.total_bytes / (1024 * 1024),
        used / (1024 * 1024),
        info.free_bytes / (1024 * 1024),
    }) catch {};
}
