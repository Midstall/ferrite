const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

// grep PATTERN: print stdin lines containing PATTERN (literal substring).
pub fn main() void {
    const argv = ferrite.argv;
    if (argv.len < 2) {
        ferrite.console.print("usage: grep PATTERN\n", .{}) catch {};
        return;
    }
    const pat = std.mem.span(argv[1]);

    var line: [4096]u8 = undefined;
    var ll: usize = 0;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = ferrite.readStdin(&chunk);
        if (n == 0) break;
        for (chunk[0..n]) |c| {
            if (c == '\n') {
                emitIfMatch(line[0..ll], pat);
                ll = 0;
            } else if (ll < line.len) {
                line[ll] = c;
                ll += 1;
            }
        }
    }
    if (ll > 0) emitIfMatch(line[0..ll], pat);
}

fn emitIfMatch(l: []const u8, pat: []const u8) void {
    if (std.mem.indexOf(u8, l, pat) != null) {
        ferrite.writeStdout(l);
        ferrite.writeStdout("\n");
    }
}
