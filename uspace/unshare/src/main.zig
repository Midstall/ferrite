const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

const USAGE =
    \\usage: unshare [--ns] PROGRAM [ARG...]
    \\
    \\Spawn PROGRAM with a fresh namespace.
    \\
    \\Flags:
    \\  --ns    Clear the child's namespace (default).
    \\
;

pub fn main() void {
    const argv = ferrite.argv;
    var flags: usize = ferrite.SPAWN_NS_CLEAR;
    var first: usize = 1;
    while (first < argv.len) {
        const s = std.mem.span(argv[first]);
        if (s.len == 0 or s[0] != '-') break;
        if (std.mem.eql(u8, s, "--")) {
            first += 1;
            break;
        } else if (std.mem.eql(u8, s, "--ns")) {
            flags |= ferrite.SPAWN_NS_CLEAR;
        } else {
            ferrite.console.print("unshare: unknown flag: {s}\n", .{s}) catch {};
            ferrite.console.print(USAGE, .{}) catch {};
            return;
        }
        first += 1;
    }

    if (first >= argv.len) {
        ferrite.console.print(USAGE, .{}) catch {};
        return;
    }

    const path = std.mem.span(argv[first]);

    // Pack remaining argv into a NUL-separated buffer the kernel splits.
    var args_buf: [512]u8 = undefined;
    var args_len: usize = 0;
    var i = first + 1;
    while (i < argv.len) : (i += 1) {
        const a = std.mem.span(argv[i]);
        if (args_len + a.len + 1 > args_buf.len) {
            ferrite.console.print("unshare: argv too long\n", .{}) catch {};
            return;
        }
        @memcpy(args_buf[args_len .. args_len + a.len], a);
        args_len += a.len;
        args_buf[args_len] = 0;
        args_len += 1;
    }

    const rc = ferrite.spawnNs(path, args_buf[0..args_len], flags);
    if (rc < 0) {
        ferrite.console.print("unshare: spawn '{s}' failed: {d}\n", .{ path, rc }) catch {};
        return;
    }
    const handle: u32 = @intCast(rc);
    _ = ferrite.wait(handle);
}
