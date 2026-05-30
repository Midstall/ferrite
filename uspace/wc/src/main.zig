const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

// wc: count lines, words, and bytes from stdin.
pub fn main() void {
    var lines: u64 = 0;
    var words: u64 = 0;
    var bytes: u64 = 0;
    var in_word = false;

    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = ferrite.readStdin(&chunk);
        if (n == 0) break;
        bytes += n;
        for (chunk[0..n]) |c| {
            if (c == '\n') lines += 1;
            const ws = c == ' ' or c == '\t' or c == '\n' or c == '\r';
            if (ws) {
                in_word = false;
            } else if (!in_word) {
                in_word = true;
                words += 1;
            }
        }
    }
    ferrite.console.print("{d} {d} {d}\n", .{ lines, words, bytes }) catch {};
}
