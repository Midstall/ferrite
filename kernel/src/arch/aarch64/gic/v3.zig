// GICv3 driver. QEMU virt uses this at -smp >= 9.
//   Distributor       GICD_BASE = 0x0800_0000   (64 KB)
//   Redistributors    GICR_BASE = 0x080A_0000   (128 KB per CPU)
// CPU interface is via system registers (ICC_*_EL1), not MMIO.
//
// MMIO (distributor + per-CPU redistributor) goes through conduit's `Mmio` seam
// over discovered bases; the CPU interface stays as ICC_* sysreg access. As with
// v2, conduit's `driver.gicv3` is single-CPU firmware-grade, so Ferrite keeps its
// per-CPU redistributor + affinity-routing logic and only borrows the seam.

const conduit = @import("conduit");
const mmio = @import("../mmio.zig");

const DEFAULT_GICD: usize = 0x0800_0000;
const DEFAULT_GICR: usize = 0x080A_0000;
const GICR_STRIDE: usize = 0x20000;

var gicd_base: usize = DEFAULT_GICD;
var gicr_base: usize = DEFAULT_GICR;

/// Point the distributor / redistributor windows at discovered bases (DT order:
/// reg[0] = GICD, reg[1] = GICR). Called before init.
pub fn setBases(dist_base: usize, redist_base: usize) void {
    gicd_base = dist_base;
    gicr_base = redist_base;
}

const Dist = struct {
    const CTLR: usize = 0x0000;
    const TYPER: usize = 0x0004;
    const IGROUPR0: usize = 0x0080;
    const ISENABLER0: usize = 0x0100;
    const ICENABLER0: usize = 0x0180;
    const IPRIORITYR0: usize = 0x0400;
    const ICFGR0: usize = 0x0C00;
    const IROUTER0: usize = 0x6000;

    const CTLR_EnableGrp1NS: u32 = 1 << 1;
    const CTLR_ARE_NS: u32 = 1 << 4;
};

const Redist = struct {
    const RD_WAKER: usize = 0x0014;
    const SGI_BASE: usize = 0x10000;
    const SGI_IGROUPR0: usize = SGI_BASE + 0x0080;
    const SGI_ISENABLER0: usize = SGI_BASE + 0x0100;
    const SGI_ICENABLER0: usize = SGI_BASE + 0x0180;
    const SGI_IPRIORITYR0: usize = SGI_BASE + 0x0400;

    const WAKER_ProcessorSleep: u32 = 1 << 1;
    const WAKER_ChildrenAsleep: u32 = 1 << 2;
};

inline fn dist() conduit.Mmio {
    return conduit.Mmio.direct(gicd_base + mmio.offset);
}

// The per-CPU redistributor window for `cpu_index` (stride-spaced from the base).
inline fn redist(cpu_index: u32) conduit.Mmio {
    return conduit.Mmio.direct(gicr_base + @as(usize, cpu_index) * GICR_STRIDE + mmio.offset);
}

pub fn init() void {
    // Distributor is global; only the boot CPU programs it.
    dist().write(u32, Dist.CTLR, 0);
    dist().write(u32, Dist.CTLR, Dist.CTLR_ARE_NS);
    dist().write(u32, Dist.CTLR, Dist.CTLR_ARE_NS | Dist.CTLR_EnableGrp1NS);

    initCpu(0);
}

// The redistributor (per-CPU at redist(idx)) and the CPU interface system
// registers (ICC_*_EL1) are per-CPU, so every CPU must run this on itself.
pub fn initCpu(cpu_index: u32) void {
    // ICC_SRE_EL1.SRE=1. Without this ICC_* sysreg accesses UNDEF.
    asm volatile (
        \\mrs x0, S3_0_C12_C12_5
        \\orr x0, x0, #1
        \\msr S3_0_C12_C12_5, x0
        \\isb
        ::: .{ .x0 = true });

    wakeRedistributor(cpu_index);

    // ICC_PMR_EL1
    asm volatile ("msr S3_0_C4_C6_0, %[v]"
        :
        : [v] "r" (@as(u64, 0xff)),
    );
    // ICC_BPR1_EL1
    asm volatile ("msr S3_0_C12_C12_3, %[v]"
        :
        : [v] "r" (@as(u64, 0)),
    );
    // ICC_IGRPEN1_EL1
    asm volatile (
        \\msr S3_0_C12_C12_7, %[v]
        \\isb
        :
        : [v] "r" (@as(u64, 1)),
    );
}

pub fn wakeRedistributor(cpu_index: u32) void {
    const rd = redist(cpu_index);
    var v = rd.read(u32, Redist.RD_WAKER);
    v &= ~Redist.WAKER_ProcessorSleep;
    rd.write(u32, Redist.RD_WAKER, v);
    while ((rd.read(u32, Redist.RD_WAKER) & Redist.WAKER_ChildrenAsleep) != 0) {}
}

pub fn enableIrq(irq: u32) void {
    enableIrqCpu(0, irq);
}

// PPIs/SGIs (irq < 32) live in each CPU's own redistributor at redist(cpu_index);
// SPIs are global distributor state (cpu_index ignored).
pub fn enableIrqCpu(cpu_index: u32, irq: u32) void {
    const bit: u32 = @as(u32, 1) << @intCast(irq % 32);
    if (irq < 32) {
        const rd = redist(cpu_index);
        const grp = Redist.SGI_IGROUPR0 + (irq / 32) * 4;
        const en = Redist.SGI_ISENABLER0 + (irq / 32) * 4;
        rd.write(u32, grp, rd.read(u32, grp) | bit);
        rd.write(u32, en, bit);
    } else {
        const grp = Dist.IGROUPR0 + (irq / 32) * 4;
        const en = Dist.ISENABLER0 + (irq / 32) * 4;
        dist().write(u32, grp, dist().read(u32, grp) | bit);
        dist().write(u64, Dist.IROUTER0 + @as(usize, irq) * 8, 0);
        dist().write(u32, en, bit);
    }
}

pub fn disableIrq(irq: u32) void {
    const bit: u32 = @as(u32, 1) << @intCast(irq % 32);
    if (irq < 32) {
        redist(0).write(u32, Redist.SGI_ICENABLER0 + (irq / 32) * 4, bit);
    } else {
        dist().write(u32, Dist.ICENABLER0 + (irq / 32) * 4, bit);
    }
}

pub fn setPriority(irq: u32, prio: u8) void {
    setPriorityCpu(0, irq, prio);
}

pub fn setPriorityCpu(cpu_index: u32, irq: u32, prio: u8) void {
    const shift: u5 = @intCast((irq % 4) * 8);
    if (irq < 32) {
        const rd = redist(cpu_index);
        const reg = Redist.SGI_IPRIORITYR0 + (irq / 4) * 4;
        var v = rd.read(u32, reg);
        v &= ~(@as(u32, 0xff) << shift);
        v |= @as(u32, prio) << shift;
        rd.write(u32, reg, v);
    } else {
        const reg = Dist.IPRIORITYR0 + (irq / 4) * 4;
        var v = dist().read(u32, reg);
        v &= ~(@as(u32, 0xff) << shift);
        v |= @as(u32, prio) << shift;
        dist().write(u32, reg, v);
    }
}

pub fn acknowledge() u32 {
    // ICC_IAR1_EL1
    var iar: u64 = undefined;
    asm volatile ("mrs %[r], S3_0_C12_C12_0"
        : [r] "=r" (iar),
    );
    return @truncate(iar);
}

pub fn endOfInterrupt(iar: u32) void {
    // ICC_EOIR1_EL1
    asm volatile ("msr S3_0_C12_C12_1, %[v]"
        :
        : [v] "r" (@as(u64, iar)),
    );
}
