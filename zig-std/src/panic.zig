const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, ra: ?usize) noreturn {
    _ = ferrite.writeConsole("\n[panic] ");
    _ = ferrite.writeConsole(msg);
    // Resolve with `llvm-addr2line -fe <bin> <ra-load_base>`.
    if (ra) |addr| {
        var buf: [32]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, " ra=0x{x}", .{addr}) catch "";
        _ = ferrite.writeConsole(txt);
    }
    _ = ferrite.writeConsole("\n");
    ferrite.exit(1);
}
