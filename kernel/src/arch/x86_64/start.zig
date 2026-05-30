const std = @import("std");
const kernel = @import("kernel");
const arch = @import("arch");
const libc = @import("libc");

extern var __bss_start: u8;
extern var __bss_end: u8;

// Manual ld.lld link doesn't bundle compiler_rt; pull in libc memcpy/memset.
comptime {
    _ = libc;
}

export fn zigStart() noreturn {
    const bss_start: [*]u8 = @ptrCast(&__bss_start);
    const bss_end: [*]u8 = @ptrCast(&__bss_end);
    const len = @intFromPtr(bss_end) - @intFromPtr(bss_start);
    @memset(bss_start[0..len], 0);

    kernel.kmain();
}

pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    arch.uart.write("\n[PANIC] ");
    arch.uart.write(msg);
    arch.uart.write("\n");
    while (true) asm volatile ("hlt");
}
