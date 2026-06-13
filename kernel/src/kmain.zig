const arch = @import("arch");
const kernel_options = @import("kernel-options");

pub const memory = @import("memory.zig");
pub const heap = @import("heap.zig");
pub const acpi = @import("acpi.zig");
pub const dtb = @import("dtb.zig");
pub const thread = @import("thread.zig");
pub const sched = @import("sched.zig");
pub const aspace = @import("aspace.zig");
pub const ipc = @import("ipc.zig");
pub const cap = @import("cap.zig");
pub const ns = @import("ns.zig");
pub const irq = @import("irq.zig");
pub const process = @import("process.zig");
pub const syscall = @import("syscall.zig");
pub const console = @import("console.zig");
pub const cpu = @import("cpu.zig");
pub const cpufeatures = @import("cpufeatures.zig");
pub const sync = @import("sync.zig");
pub const initrd = @import("initrd.zig");
pub const cmdline = @import("cmdline.zig");
pub const signature = @import("signature.zig");
pub const macho = @import("macho.zig");
pub const loader = @import("loader.zig");
pub const limine_proto = @import("limine_proto.zig");
pub const timer = @import("timer.zig");
pub const vmm = @import("vmm.zig");

var smp_status_printed: bool = false;

/// Bind the arch's leaf device drivers (UART, timer/CLINT, interrupt
/// controller) to MMIO bases discovered from the device tree through conduit's
/// Registry, instead of compiled-in constants. Each driver keeps a sensible
/// default, so a board with no FDT, or a device conduit cannot match, simply
/// keeps that default. Compiled only on boards that wire conduit
/// (kernel_options.have_conduit); each branch is `@hasDecl`-gated so an arch
/// that has not grown a `setBase`/`setBases` seam is skipped.
fn discoverDevices() void {
    const cb = @import("conduit_backend.zig");

    if (@hasDecl(arch.uart, "setBase")) {
        // Match only specific UART compatibles. The generic "arm,primecell" ID is
        // carried by every PrimeCell peripheral (RTC, GPIO, SPI), so matching it
        // would bind the console to whichever PrimeCell device the DTB lists first.
        if (cb.findBase(.uart, &.{
            "ns16550a", "ns16550", "snps,dw-apb-uart", "arm,pl011",
        })) |base| arch.uart.setBase(base);
    }

    if (@hasDecl(arch, "clint") and @hasDecl(arch.clint, "setBase")) {
        if (cb.findBase(.timer, &.{ "riscv,clint0", "sifive,clint0" })) |base|
            arch.clint.setBase(base);
    }

    if (@hasDecl(arch, "gic") and @hasDecl(arch.gic, "setBases")) {
        const bs = cb.findBases(.intc, &.{
            "arm,gic-v3", "arm,gic-v3-its", "arm,gic-400", "arm,cortex-a15-gic", "arm,gic-v2",
        });
        if (bs.len > 0) arch.gic.setBases(bs.items[0..bs.len]);
    }
}

fn schedTick() void {
    // Timer may fire before boot CPU installs tpidr_el1 (bringUpBoot runs after enableIrq).
    if (arch.cpu.thisCpuPtr() == 0) return;
    @atomicStore(u32, &cpu.thisCpu().needs_resched, 1, .release);
    timer.tick();

    // Once, after boot settles, the boot CPU reports per-CPU online state.
    if (!smp_status_printed and cpu.num_cpus > 1 and cpu.thisCpu().id == 0 and arch.timer.ticks() > 500) {
        smp_status_printed = true;
        var i: u32 = 0;
        while (i < cpu.num_cpus) : (i += 1) {
            const c = &cpu.cpus[i];
            arch.uart.print("[smp] cpu{d} online={d}\n", .{ i, c.online });
        }
    }
}

pub export fn secondaryStart(cpu_id: u64) callconv(.c) noreturn {
    const idx: usize = @intCast(cpu_id);
    const c = &cpu.cpus[idx];

    // Point the per-CPU register at our Cpu BEFORE anything that could allocate
    // or take a sleeping lock (those read thisCpu()/current()).
    arch.cpu.setThisCpu(c);

    // The boot CPU pre-allocated our bootstrap/idle thread (so no heap alloc
    // races here). Fall back to allocating if a boot path didn't (TPIDR is set,
    // so the heap mutex is usable, and we're the only user this early).
    if (c.bootstrap == null) {
        c.bootstrap = thread.Thread.initBootstrap() catch @panic("smp: bootstrap thread alloc failed");
    }
    c.current = c.bootstrap;

    // Per-CPU trap + GIC interface + timer (not the global distributor).
    if (@hasDecl(arch.traps, "initCpu")) arch.traps.initCpu(@intCast(cpu_id)) else arch.traps.init();
    arch.usermode.init();
    if (@hasDecl(arch.timer, "initCpu")) arch.timer.initCpu(@intCast(cpu_id));

    arch.cpu.enableIrq();
    @atomicStore(u32, &c.online, 1, .release);
    arch.uart.print("[smpsec] cpu {d} entering idle\n", .{cpu_id});

    sched.idleLoop();
}

pub fn kmain() callconv(.c) noreturn {
    cpufeatures.init();
    // Bind leaf drivers (UART/CLINT/GIC) to FDT-discovered bases before anything
    // programs them: arch.traps.init() brings up the GIC, arch.timer.init() the
    // CLINT, console.init() the UART. Discovery only walks the device tree and
    // pokes module-level bases, so it is safe this early.
    if (comptime kernel_options.have_conduit) discoverDevices();
    arch.traps.init();
    arch.usermode.init();
    arch.traps.user_fault_handler = &userFault;
    arch.traps.sync_diag_hook = &syncDiag;
    // Catchable-signal delivery is arch-specific (frame surgery); only aarch64
    // traps exposes the hook + PendingSig today. Guard so other arches compile.
    if (@hasDecl(arch.traps, "take_signal_hook")) arch.traps.take_signal_hook = &takeSignal;
    syscall.init();
    signature.init();
    acpi.init();
    // Wire scheduler hooks before the first tick.
    arch.traps.preempt_hook = &sched.maybePreempt;
    arch.timer.tick_hook = &schedTick;
    // arch.timer.init MUST precede timer.init; the latter reads arch.timer.now() / freq_hz.
    arch.timer.init(10_000_000);
    timer.init();
    console.init();
    // -Dhyp: run the arch's microVM demo once at boot. aarch64's runs earlier
    // from the EL2 entry path (gated by hyp_active); riscv's H-extension demo
    // runs here (mtvec is installed, and the world-switch saves/restores it).
    if (kernel_options.hyp and @hasDecl(arch, "hypRiscvDemo")) arch.hypRiscvDemo(&memory.allocPages, &memory.physToVirtFn);
    // x86_64 AMD SVM: enable SVM + run the in-kernel guest demo. enable() leaves
    // the facility live for the userspace VMM afterward (no-ops on a CPU without
    // SVM, e.g. every TCG run).
    if (kernel_options.hyp and @hasDecl(arch, "hypX86Demo")) arch.hypX86Demo(&memory.allocPages, &memory.physToVirtFn);
    // Point the per-CPU register at the boot Cpu BEFORE enabling IRQs.
    // TPIDR_EL1's reset value is architecturally UNKNOWN (garbage under KVM),
    // and an early timer IRQ -> schedTick/maybePreempt would dereference it.
    // cpus[0] is statically valid + aligned and current is still null here, so
    // maybePreempt early-returns; bringUpBoot fills in the thread later. This
    // closes the window the `thisCpuPtr()==0` guard alone could not (it only
    // catches an exactly-zero TPIDR, not leftover garbage).
    if (cpu.num_cpus == 0) cpu.init(1);
    arch.cpu.setThisCpu(&cpu.cpus[0]);
    arch.cpu.enableIrq();

    runInit() catch |e| {
        arch.uart.print("[kmain] init: {s}. idling\n", .{@errorName(e)});
    };

    // Release the secondary CPUs now that the kernel is fully up (scheduler,
    // timers, heap, init all running). They were provisioned at boot but held
    // back to avoid running against half-initialized global state.
    if (@hasDecl(arch, "smp")) arch.smp.startSecondaries();

    sched.idleLoop();
}

fn runInit() !void {
    if (!initrd.isPresent()) return error.NoInitrd;
    const rec = (try initrd.find("bin/init")) orelse return error.InitNotFound;

    var root_proc = try process.Process.create();
    root_proc.authority = process.Authority.all;
    root_proc.setName("kernel");

    const boot_t = try thread.Thread.initBootstrap();
    cpu.bringUpBoot(boot_t);

    var argv_buf: [64][]const u8 = undefined;
    argv_buf[0] = "bin/init";
    var argc: usize = 1;
    var it = cmdline.tokens();
    while (it.next()) |tok| {
        if (argc >= argv_buf.len) break;
        argv_buf[argc] = tok;
        argc += 1;
    }

    const loaded = try loader.load(rec.data, root_proc, argv_buf[0..argc]);
    sched.add(loaded.thread); // loader no longer self-schedules

    sched.yield();
}

fn userFault() noreturn {
    // No current thread = fault happened before bringUpBoot; sched.exit
    // would deref null cpu.current and recurse into the trap handler.
    if (arch.cpu.thisCpuPtr() == 0 or cpu.current() == null) {
        arch.uart.write("[kmain] early fault (no thread), halting\n");
        while (true) arch.cpu.idle();
    }
    if (cpu.current()) |t| {
        if (process.fromThread(t)) |p| {
            arch.uart.print("[kmain] killing pid={d} {s}\n", .{ p.pid, p.nameSlice() });
        }
    }
    sched.exit();
}

// Called from the EL0 trap-return path (arch.traps): if the current thread has a
// pending caught signal, clear it and return its handler info for delivery.
fn takeSignal() callconv(.c) arch.traps.PendingSig {
    const t = cpu.current() orelse return .{};
    const pend = @atomicLoad(u32, &t.pending_sig, .acquire);
    if (pend == 0) return .{};
    const sig: u32 = @ctz(pend);
    if (sig == 0) return .{};
    const bit = @as(u32, 1) << @intCast(sig);
    _ = @atomicRmw(u32, &t.pending_sig, .And, ~bit, .release);
    const proc = process.fromThread(t) orelse return .{};
    const handler = if (sig < process.NSIG) proc.sig_handlers[sig] else 0;
    if (handler == 0) return .{};
    return .{ .sig = sig, .handler = handler, .restorer = proc.sig_restorer };
}

fn syncDiag() void {
    if (cpu.current()) |t| {
        if (process.fromThread(t)) |p| {
            arch.uart.print("[SYNC] thread=*0x{x} proc={s} pid={d}\n", .{ @intFromPtr(t), p.nameSlice(), p.pid });
        } else {
            arch.uart.print("[SYNC] thread=*0x{x} (kernel-only)\n", .{@intFromPtr(t)});
        }
    } else {
        arch.uart.write("[SYNC] (no current thread)\n");
    }
}
