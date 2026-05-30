// GICv3 driver. QEMU virt uses this at -smp >= 9.
//   Distributor       GICD_BASE = 0x0800_0000   (64 KB)
//   Redistributors    GICR_BASE = 0x080A_0000   (128 KB per CPU)
// CPU interface is via system registers (ICC_*_EL1), not MMIO.

const mmio = @import("../mmio.zig");

const GICD_BASE: usize = 0x0800_0000;
const GICR_BASE: usize = 0x080A_0000;
const GICR_STRIDE: usize = 0x20000;

const Dist = struct {
    const CTLR: usize = GICD_BASE + 0x0000;
    const TYPER: usize = GICD_BASE + 0x0004;
    const IGROUPR0: usize = GICD_BASE + 0x0080;
    const ISENABLER0: usize = GICD_BASE + 0x0100;
    const ICENABLER0: usize = GICD_BASE + 0x0180;
    const IPRIORITYR0: usize = GICD_BASE + 0x0400;
    const ICFGR0: usize = GICD_BASE + 0x0C00;
    const IROUTER0: usize = GICD_BASE + 0x6000;

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

pub fn init() void {
    // Distributor is global; only the boot CPU programs it.
    mmio.write(u32, Dist.CTLR, 0);
    mmio.write(u32, Dist.CTLR, Dist.CTLR_ARE_NS);
    mmio.write(u32, Dist.CTLR, Dist.CTLR_ARE_NS | Dist.CTLR_EnableGrp1NS);

    initCpu(0);
}

// The redistributor (per-CPU at rdBase(idx)) and the CPU interface system
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

inline fn rdBase(cpu_index: u32) usize {
    return GICR_BASE + @as(usize, cpu_index) * GICR_STRIDE;
}

pub fn wakeRedistributor(cpu_index: u32) void {
    const waker = rdBase(cpu_index) + Redist.RD_WAKER;
    var v = mmio.read(u32, waker);
    v &= ~Redist.WAKER_ProcessorSleep;
    mmio.write(u32, waker, v);
    while ((mmio.read(u32, waker) & Redist.WAKER_ChildrenAsleep) != 0) {}
}

pub fn enableIrq(irq: u32) void {
    enableIrqCpu(0, irq);
}

// PPIs/SGIs (irq < 32) live in each CPU's own redistributor at rdBase(cpu_index);
// SPIs are global distributor state (cpu_index ignored).
pub fn enableIrqCpu(cpu_index: u32, irq: u32) void {
    const bit: u32 = @as(u32, 1) << @intCast(irq % 32);
    if (irq < 32) {
        const rd = rdBase(cpu_index);
        const grp = rd + Redist.SGI_IGROUPR0 + (irq / 32) * 4;
        const en = rd + Redist.SGI_ISENABLER0 + (irq / 32) * 4;
        mmio.write(u32, grp, mmio.read(u32, grp) | bit);
        mmio.write(u32, en, bit);
    } else {
        const grp = Dist.IGROUPR0 + (irq / 32) * 4;
        const en = Dist.ISENABLER0 + (irq / 32) * 4;
        mmio.write(u32, grp, mmio.read(u32, grp) | bit);
        mmio.write(u64, Dist.IROUTER0 + @as(usize, irq) * 8, 0);
        mmio.write(u32, en, bit);
    }
}

pub fn disableIrq(irq: u32) void {
    const bit: u32 = @as(u32, 1) << @intCast(irq % 32);
    if (irq < 32) {
        const rd = rdBase(0);
        const en = rd + Redist.SGI_ICENABLER0 + (irq / 32) * 4;
        mmio.write(u32, en, bit);
    } else {
        const en = Dist.ICENABLER0 + (irq / 32) * 4;
        mmio.write(u32, en, bit);
    }
}

pub fn setPriority(irq: u32, prio: u8) void {
    setPriorityCpu(0, irq, prio);
}

pub fn setPriorityCpu(cpu_index: u32, irq: u32, prio: u8) void {
    const reg = if (irq < 32)
        rdBase(cpu_index) + Redist.SGI_IPRIORITYR0 + (irq / 4) * 4
    else
        Dist.IPRIORITYR0 + (irq / 4) * 4;
    const shift: u5 = @intCast((irq % 4) * 8);
    var v = mmio.read(u32, reg);
    v &= ~(@as(u32, 0xff) << shift);
    v |= @as(u32, prio) << shift;
    mmio.write(u32, reg, v);
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
