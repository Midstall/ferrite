const std = @import("std");
const kernel = @import("kernel");
const arch = @import("arch");

extern var __bss_start: u8;
extern var __bss_end: u8;
extern const __stack_top: u8;
extern const __kernel_start: u8;
extern const __kernel_end: u8;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\ csrr  t0, mhartid
        \\ bnez  t0, 0f
        // QEMU passes the DTB pointer in a1 on entry. Move it to a0 so it's the
        // first arg to zigStart per the riscv ELF psABI.
        \\ la    sp, __stack_top
        \\ mv    a0, a1
        \\ call  zigStart
        \\0: wfi
        \\   j 0b
    );
}

export fn zigStart(dtb_ptr: u64) noreturn {
    const bss_start: [*]u8 = @ptrCast(&__bss_start);
    const bss_end: [*]u8 = @ptrCast(&__bss_end);
    const len = @intFromPtr(bss_end) - @intFromPtr(bss_start);
    @memset(bss_start[0..len], 0);

    kernel.dtb.dtb_phys = dtb_ptr;

    if (!kernel.dtb.parseMemory(dtb_ptr)) {
        kernel.memory.register(0x8000_0000, 0x0800_0000, .usable);
    }
    // M-mode kernel runs paging-off (satp=Bare), so PA == VA for linker symbols.
    const k_start = @intFromPtr(&__kernel_start);
    const k_end = @intFromPtr(&__kernel_end);
    kernel.memory.register(k_start, k_end - k_start, .reserved);

    // Initrd MUST be registered as reserved BEFORE memory.init carves the
    // usable ranges, otherwise the page allocator hands out initrd PAs to
    // user-page mappings and signature.verify sees corrupted bytes.
    if (kernel.dtb.parseInitrd(dtb_ptr)) |bytes| {
        kernel.initrd.init(bytes) catch {};
        kernel.memory.register(@intFromPtr(bytes.ptr), bytes.len, .reserved);
    }

    kernel.memory.init(0);

    arch.mmu.init(.{
        .alloc_page = &kernel.memory.allocPage,
        .free_page = &kernel.memory.freePage,
    });

    if (kernel.dtb.parseTimebaseFrequency(dtb_ptr)) |hz| arch.timer.setTimebaseFreq(hz);
    if (kernel.dtb.parseBootargs(dtb_ptr)) |bytes| kernel.cmdline.init(bytes);

    kernel.kmain();
}

pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    arch.uart.write("\n[PANIC] ");
    arch.uart.write(msg);
    arch.uart.write("\n");
    while (true) asm volatile ("wfi");
}
