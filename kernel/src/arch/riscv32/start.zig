// ESP32-C6 entry. The 2nd-stage bootloader hands off here with the
// initrd's mapped virtual address in a0 and its size in a1.

const std = @import("std");
const arch = @import("arch");
const kernel = @import("kernel");
const wdt = @import("board/esp32c6/wdt.zig");

// Without these the linker garbage-collects trap_entry.S symbols and
// the thread context-switch shims.
comptime {
    _ = arch.traps;
    _ = arch.thread;
}

pub var initrd_va: u32 = 0;
pub var initrd_size: u32 = 0;

extern var __bss_start: u8;
extern var __bss_end: u8;
extern const __stack_top: u8;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\ la sp, __stack_top
        \\ j  zigStart
    );
}

export fn zigStart(_initrd_va: u32, _initrd_size: u32) callconv(.c) noreturn {
    // Don't re-zero BSS here - the bootloader already did it. A second
    // memset would wipe the initrd globals we set on the next two lines.
    initrd_va = _initrd_va;
    initrd_size = _initrd_size;
    wdt.earlyInit();

    arch.traps.init();
    arch.pmp.configureRegionProtection();
    arch.apm.allowAllUmode();
    // CONF bit 0 selects the legacy register layout in both PLIC
    // instances (M-mode and U-mode).
    const PLIC_MX_CONF: *volatile u32 = @ptrFromInt(0x2000_13FC);
    const PLIC_UX_CONF: *volatile u32 = @ptrFromInt(0x2000_17FC);
    PLIC_MX_CONF.* |= 0x1;
    PLIC_UX_CONF.* |= 0x1;
    asm volatile ("csrw mideleg, zero");

    // The first ~1 s of output is lost while USB-Serial/JTAG enumerates,
    // so a few delayed beacons let the host attach before anything
    // important prints.
    var w: u32 = 0;
    while (w < 3) : (w +%= 1) {
        arch.uart.print("ferrite/esp32-c6 boot {d}\n", .{w});
        delay(2_000_000);
    }
    arch.uart.print("initrd: va=0x{x} size=0x{x}\n", .{ initrd_va, initrd_size });

    // Kernel TEXT lives in flash via XIP. In IRAM we only consume .data
    // + .bss + boot stack. The remainder of SRAM (including the
    // bootloader's region, which is one-shot and finished by now) is
    // free for the page allocator.
    const heap_start: u32 = @intFromPtr(&__stack_top);
    const sram_end: u32 = 0x4088_0000;
    if (sram_end > heap_start) {
        kernel.memory.register(heap_start, sram_end - heap_start, .usable);
        arch.uart.print("heap: 0x{x}..0x{x} ({d} KB)\n", .{ heap_start, sram_end, (sram_end - heap_start) / 1024 });
    }
    kernel.memory.init(0);

    if (initrd_size > 0) {
        const bytes: [*]const u8 = @ptrFromInt(initrd_va);
        kernel.initrd.init(bytes[0..initrd_size]) catch |e| {
            arch.uart.print("[start] initrd.init: {s}\n", .{@errorName(e)});
        };
    }

    kernel.kmain();
}

fn delay(loops: u32) void {
    var i: u32 = 0;
    while (i < loops) : (i +%= 1) asm volatile ("nop");
}

pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, _: ?usize) noreturn {
    arch.uart.write("\n[PANIC] ");
    arch.uart.write(msg);
    arch.uart.write("\n");
    while (true) arch.idle();
}
