//! Bare S-mode boot entry for an SBI handoff (Weir, or any OpenSBI-style SBI).
//!
//! The SBI enters us in S-mode with a0 = boot hart id, a1 = the device-tree
//! physical address, and satp = Bare (paging off). Unlike the Limine entry, we
//! assume nothing about the platform: memory, UART, CLINT, PLIC, and the
//! timebase all come from the device tree in a1. The kernel runs paging-off
//! (satp = Bare, PA == VA) exactly like the M-mode raw path - so MMIO is reached
//! at the physical addresses discovery finds, with no hardcoded identity maps.
//! Per-process isolation uses per-user page tables (satp swaps on the way to
//! user mode), since PMP belongs to M-mode here and is owned by the SBI.

const std = @import("std");
const kernel = @import("kernel");
// The build wires "arch" to arch_smode.zig for this boot protocol, so every
// M-mode CSR access here routes through supervisor mode + SBI ecalls.
const arch = @import("arch");

extern var __bss_start: u8;
extern var __bss_end: u8;
extern const __kernel_start: u8;
extern const __kernel_end: u8;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
    // Only the boot hart proceeds; secondaries park until the kernel starts
    // them over SBI HSM. The SBI passes the hart id in a0.
        \\ bnez a0, 0f
        \\ la   sp, __stack_top
        // Install the S-mode trap vector before any MMIO can fault (a stray
        // fault with stvec unset would vector to 0).
        \\ la   t0, s_trap_entry
        \\ csrw stvec, t0
        // a0 = hartid, a1 = dtb are already the psABI args to zigStart.
        \\ call zigStart
        \\0: wfi
        \\   j 0b
    );
}

export fn zigStart(hartid: u64, dtb_ptr: u64) noreturn {
    // Zero .bss: the SBI does not guarantee it.
    const bss_start: [*]u8 = @ptrCast(&__bss_start);
    const bss_end: [*]u8 = @ptrCast(&__bss_end);
    @memset(bss_start[0 .. @intFromPtr(bss_end) - @intFromPtr(bss_start)], 0);

    arch.cpu.boot_hartid = @intCast(hartid);
    kernel.dtb.dtb_phys = dtb_ptr;

    // Memory comes from the device tree. An absent or malformed tree is a
    // recoverable runtime fault (untrusted external input), not a programmer
    // error: surface it and halt rather than fabricate a map and boot onto
    // memory that may not exist.
    if (!kernel.dtb.parseMemory(dtb_ptr)) {
        arch.uart.write("[sbi-boot] device tree has no usable memory; halting\n");
        arch.cpu.halt();
    }

    // The kernel image is reserved. Paging-off means PA == VA for linker symbols.
    const k_start = @intFromPtr(&__kernel_start);
    const k_end = @intFromPtr(&__kernel_end);
    kernel.memory.register(k_start, k_end - k_start, .reserved);

    // Reserve the initrd BEFORE memory.init carves usable ranges, else the page
    // allocator hands out initrd PAs and signature.verify sees corrupted bytes
    // (the same ordering the raw and Limine paths depend on).
    if (kernel.dtb.parseInitrd(dtb_ptr)) |bytes| {
        kernel.initrd.init(bytes) catch {};
        kernel.memory.register(@intFromPtr(bytes.ptr), bytes.len, .reserved);
    }

    kernel.memory.init(0);

    // Bare S-mode: identity, so the walker's higher-half offset is 0. Only user
    // page tables use satp; the kernel touches physical addresses directly.
    arch.mmu.configureWalker(.{
        .hhdm_offset = 0,
        .alloc_page = &kernel.memory.allocPage,
        .free_page = &kernel.memory.freePage,
    });
    arch.mmio.offset = 0;

    // Everything else - UART base, CLINT, PLIC - is discovered from the device
    // tree by kmain's device pass. Only the timebase and cmdline are needed this
    // early (the timer arms before the scheduler; the cmdline gates boot policy).
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
