const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

pub fn main() void {
    const argv = ferrite.argv;
    if (argv.len < 3) {
        ferrite.console.print("usage: write <path> <text...>\n", .{}) catch {};
        return;
    }
    const path_arg = std.mem.span(argv[1]);
    var uri_buf: [256]u8 = undefined;
    const uri = ferrite.fs.resolvePath(path_arg, &uri_buf) catch {
        ferrite.console.print("write: bad path: {s}\n", .{path_arg}) catch {};
        return;
    };

    const file = ferrite.fs.open(uri, .{ .mode = .write }) catch |e| {
        ferrite.console.print("write: {s}: {t}\n", .{ path_arg, e }) catch {};
        return;
    };
    defer file.close();

    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const part = std.mem.span(argv[i]);
        _ = file.writeAll(part) catch |e| {
            ferrite.console.print("write: {t}\n", .{e}) catch {};
            return;
        };
        if (i + 1 < argv.len) {
            _ = file.writeAll(" ") catch return;
        }
    }
    _ = file.writeAll("\n") catch return;
}
