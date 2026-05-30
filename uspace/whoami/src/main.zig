const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

pub fn main() void {
    const uid = ferrite.getUid();
    var uri_buf: [128]u8 = undefined;
    const uri = std.fmt.bufPrint(&uri_buf, "com.midstall.ferrite.users@v0:/users/{d}", .{uid}) catch {
        ferrite.console.print("uid {d}\n", .{uid}) catch {};
        return;
    };
    const file = ferrite.fs.open(uri, .{ .mode = .read }) catch {
        ferrite.console.print("uid {d}\n", .{uid}) catch {};
        return;
    };
    defer file.close();

    var buf: [64]u8 = undefined;
    const n = file.read(0, &buf) catch {
        ferrite.console.print("uid {d}\n", .{uid}) catch {};
        return;
    };
    if (n == 0) {
        ferrite.console.print("uid {d}\n", .{uid}) catch {};
        return;
    }
    ferrite.console.print("{s}\n", .{buf[0..n]}) catch {};
}
