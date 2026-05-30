const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

pub fn main() void {
    const argv = ferrite.argv;
    // No path (or "-"): copy stdin to stdout, acting as a pipe consumer.
    if (argv.len < 2 or std.mem.eql(u8, std.mem.span(argv[1]), "-")) {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = ferrite.readStdin(&buf);
            if (n == 0) break;
            ferrite.writeStdout(buf[0..n]);
        }
        return;
    }
    const arg = std.mem.span(argv[1]);
    var uri_buf: [256]u8 = undefined;
    const uri = ferrite.fs.resolvePath(arg, &uri_buf) catch {
        ferrite.console.print("cat: bad path: {s}\n", .{arg}) catch {};
        return;
    };

    const file = ferrite.fs.open(uri, .{ .mode = .read }) catch |e| {
        ferrite.console.print("cat: {s}: {t}\n", .{ arg, e }) catch {};
        return;
    };
    defer file.close();

    var buf: [4096]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = file.read(off, &buf) catch |e| {
            ferrite.console.print("cat: read: {t}\n", .{e}) catch {};
            return;
        };
        if (n == 0) break;
        ferrite.console.print("{s}", .{buf[0..n]}) catch {};
        off += n;
    }
}
