const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

pub fn main() void {
    ferrite.console.print("hello from child (spawned)\n", .{}) catch {};

    const file = ferrite.fs.open(
        "com.midstall.ferrite.devfs@v0:/console",
        .{ .mode = .write },
    ) catch |e| {
        ferrite.console.print("[hello] fs.open failed: {t}\n", .{e}) catch {};
        return;
    };
    defer file.close();

    const wrote = file.writeAll("[hello via devfs] greetings!\n") catch |e| {
        ferrite.console.print("[hello] fs.write failed: {t}\n", .{e}) catch {};
        return;
    };
    ferrite.console.print("[hello] wrote {d} bytes via VFS\n", .{wrote}) catch {};
}
