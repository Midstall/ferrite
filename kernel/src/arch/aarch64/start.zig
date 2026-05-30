const std = @import("std");
const kernel = @import("kernel");
const arch = @import("arch");

fn parseUint(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

extern var __bss_start: u8;
extern var __bss_end: u8;
extern const __stack_top: u8;
extern const __kernel_start: u8;
extern const __kernel_end: u8;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
    // ARM64 Linux Image header (Documentation/arm64/booting.rst).
    // Magic 'ARM\x64' at offset 0x38 tells QEMU virt to set x0 = DTB pointer.
        \\ b 4f
        \\ .long 0
        \\ .quad 0
        \\ .quad 0
        \\ .quad 0
        \\ .quad 0
        \\ .quad 0
        \\ .quad 0
        \\ .long 0x644D5241
        \\ .long 0
        \\4:
        \\ // x0 = DTB pointer on entry; preserve in x19.
        \\ mov x19, x0
        \\ mrs x20, mpidr_el1
        \\ and x20, x20, #0xff
        \\ cbz x20, 1f
        \\0: wfe
        \\   b 0b
        \\ // CPACR_EL1.FPEN = 0b11 enables FP/SIMD at EL1 for std.fmt q-loads.
        \\1: mov  x2, #(3 << 20)
        \\   msr  cpacr_el1, x2
        \\   isb
        \\   adrp x1, __stack_top
        \\   add  x1, x1, :lo12:__stack_top
        \\   mov  sp, x1
        \\   mov  x0, x19
        \\   bl zigStart
        \\2: wfe
        \\   b 2b
    );
}

export fn zigStart(dtb_ptr: u64) noreturn {
    // TPIDR_EL1 (per-CPU pointer) resets to an UNKNOWN value on real hardware;
    // the scheduler's pre-setThisCpu guards assume it reads 0 (TCG does, KVM
    // does not). Zero it before any IRQ can call schedTick/maybePreempt.
    asm volatile ("msr tpidr_el1, xzr");

    const bss_start: [*]u8 = @ptrCast(&__bss_start);
    const bss_end: [*]u8 = @ptrCast(&__bss_end);
    const len = @intFromPtr(bss_end) - @intFromPtr(bss_start);
    @memset(bss_start[0..len], 0);

    kernel.dtb.dtb_phys = dtb_ptr;

    // MMU on with identity-mapped Normal memory; without it RAM is Device-nGnRnE
    // and strict alignment breaks compiler-rt memcpy paths.
    arch.mmu.init();

    if (!kernel.dtb.parseMemory(dtb_ptr)) {
        kernel.memory.register(0x4000_0000, 0x0800_0000, .usable);
    }
    const k_start = @intFromPtr(&__kernel_start);
    const k_end = @intFromPtr(&__kernel_end);
    kernel.memory.register(k_start, k_end - k_start, .reserved);

    // Bootargs parsed before memory.init so a `pagesize=N` can rebuild the MMU
    // at the new granule first.
    if (kernel.dtb.parseBootargs(dtb_ptr)) |bytes| {
        kernel.cmdline.init(bytes);
        if (kernel.cmdline.getValue("pagesize")) |val| {
            if (parseUint(val)) |n| {
                if (n != kernel.memory.pageSize() and arch.mmu.pickGranule(n)) {
                    kernel.memory.setPageSize(n);
                    arch.mmu.init();
                    arch.uart.print("[boot] mmu reinit at pagesize={d}\n", .{n});
                }
            }
        }
    }

    kernel.memory.init(0);

    arch.mmu.configureWalker(.{
        .hhdm_offset = 0,
        .alloc_page = &kernel.memory.allocPage,
        .free_page = &kernel.memory.freePage,
    });
    arch.mmu.captureKernelTtbr0();

    // Install exception vectors before any trapping instruction (PSCI HVC, etc.).
    arch.traps.init();

    bringUpSecondaries(dtb_ptr);

    if (kernel.dtb.parseInitrd(dtb_ptr)) |bytes| {
        kernel.initrd.init(bytes) catch {};
        kernel.memory.register(@intFromPtr(bytes.ptr), bytes.len, .reserved);
    }

    kernel.kmain();
}

fn bringUpSecondaries(dtb_ptr: u64) void {
    var mpidrs: [kernel.cpu.MAX_CPUS]u64 = @splat(0);
    const found = kernel.dtb.parseCpus(dtb_ptr, &mpidrs);
    if (found == 0) {
        kernel.cpu.init(1);
        return;
    }

    const bsp_mpidr: u64 = arch.cpu.cpuId();

    // Pass 1: pre-allocate each secondary's kernel stack + bootstrap/idle thread
    // on the (still single-threaded) boot CPU, so the secondaries never touch the
    // heap before their per-CPU pointer is live. Don't start any CPU yet.
    var target_mpidr: [kernel.cpu.MAX_CPUS]u64 = @splat(0);
    var next_id: u32 = 1;
    var i: usize = 0;
    while (i < found and next_id < kernel.cpu.MAX_CPUS) : (i += 1) {
        if (mpidrs[i] == bsp_mpidr) continue;
        const stack_phys = kernel.memory.allocPage() orelse break;
        const boot_t = kernel.thread.Thread.initBootstrap() catch {
            kernel.memory.freePage(stack_phys);
            break;
        };
        kernel.cpu.cpus[next_id].bootstrap = boot_t;
        kernel.cpu.cpus[next_id].current = boot_t;
        arch.smp.inits[next_id] = .{
            .stack_top = stack_phys + kernel.memory.pageSize(),
            .cpu_id = next_id,
        };
        target_mpidr[next_id] = mpidrs[i];
        next_id += 1;
    }
    // Publish the CPU count before starting any secondary (stealFromOthers /
    // sched.remove iterate cpus[0..num_cpus]; offline entries are skipped).
    kernel.cpu.init(next_id);

    // Hand the target MPIDRs to arch.smp; kmain calls arch.smp.startSecondaries()
    // to PSCI them only AFTER the kernel is fully initialized. Starting them here
    // (mid-boot) hangs: a secondary would run the scheduler/kernel timer before
    // kmain has initialized them.
    var id: u32 = 1;
    while (id < next_id) : (id += 1) arch.smp.pending_mpidr[id] = target_mpidr[id];
    arch.smp.pending_count = next_id - 1;
}

pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, ra: ?usize) noreturn {
    @branchHint(.cold);
    arch.uart.write("\n[PANIC] ");
    arch.uart.write(msg);
    if (ra) |addr| {
        var buf: [32]u8 = undefined;
        arch.uart.write(std.fmt.bufPrint(&buf, " ra=0x{x}", .{addr}) catch "");
    }
    arch.uart.write("\n");
    while (true) asm volatile ("wfe");
}
