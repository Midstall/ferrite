const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

pub fn main() void {
    const argv = ferrite.argv;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (i > 1) ferrite.writeStdout(" ");
        ferrite.writeStdout(std.mem.span(argv[i]));
    }
    ferrite.writeStdout("\n");
}
