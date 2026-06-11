// GICv2 driver. QEMU virt uses this at -smp <= 8.
//   Distributor    GICD_BASE = 0x0800_0000  (8 KB)
//   CPU interface  GICC_BASE = 0x0801_0000  (8 KB, banked per CPU)
//
// Register access goes through conduit's `Mmio` seam over discovered bases.
// conduit's own `driver.gicv2` is firmware-grade (single hart, no per-CPU/SPI
// routing), so Ferrite keeps its SMP-aware logic here and only borrows the seam
// + discovery, rather than the conduit driver itself.

const conduit = @import("conduit");
const mmio = @import("../mmio.zig");

const DEFAULT_GICD: usize = 0x0800_0000;
const DEFAULT_GICC: usize = 0x0801_0000;

var gicd_base: usize = DEFAULT_GICD;
var gicc_base: usize = DEFAULT_GICC;

/// Point the distributor / CPU-interface windows at discovered bases (DT order:
/// reg[0] = GICD, reg[1] = GICC). Called before init.
pub fn setBases(dist_base: usize, cpu_base: usize) void {
    gicd_base = dist_base;
    gicc_base = cpu_base;
}

// Distributor / CPU-interface register offsets.
const D_CTLR: usize = 0x000;
const D_TYPER: usize = 0x004;
const D_ISENABLER0: usize = 0x100;
const D_ICENABLER0: usize = 0x180;
const D_IPRIORITYR0: usize = 0x400;
const D_ITARGETSR0: usize = 0x800;
const D_ICFGR0: usize = 0xC00;

const C_CTLR: usize = 0x000;
const C_PMR: usize = 0x004;
const C_BPR: usize = 0x008;
const C_IAR: usize = 0x00C;
const C_EOIR: usize = 0x010;

inline fn dist() conduit.Mmio {
    return conduit.Mmio.direct(gicd_base + mmio.offset);
}

inline fn cpuif() conduit.Mmio {
    return conduit.Mmio.direct(gicc_base + mmio.offset);
}

pub fn init() void {
    // Distributor is global; only the boot CPU enables it.
    dist().write(u32, D_CTLR, 0);
    dist().write(u32, D_CTLR, 1);
    initCpu(0);
}

// The GICv2 CPU interface (GICC_*) is banked: every CPU sees its own copy at
// the same MMIO address, so each CPU must run this itself. cpu_index is unused
// (the banking is implicit in which CPU issues the access).
pub fn initCpu(_: u32) void {
    cpuif().write(u32, C_PMR, 0xff);
    cpuif().write(u32, C_BPR, 0);
    cpuif().write(u32, C_CTLR, 1);
}

pub fn enableIrq(irq: u32) void {
    // SPIs need an explicit CPU target. QEMU virt with -smp > 1 zeros ITARGETSR.
    if (irq >= 32) {
        const reg = D_ITARGETSR0 + (irq / 4) * 4;
        const shift: u5 = @intCast((irq % 4) * 8);
        var v = dist().read(u32, reg);
        v &= ~(@as(u32, 0xff) << shift);
        v |= @as(u32, 0x01) << shift;
        dist().write(u32, reg, v);
    }
    const en_reg = D_ISENABLER0 + (irq / 32) * 4;
    const bit: u32 = @as(u32, 1) << @intCast(irq % 32);
    dist().write(u32, en_reg, bit);
}

// PPI/SGI enable + priority registers (irq < 32) are banked per-CPU, so the
// CPU that runs this enables its own copy; cpu_index is unused. SPIs (irq >= 32)
// are global distributor state.
pub fn enableIrqCpu(_: u32, irq: u32) void {
    enableIrq(irq);
}

pub fn setPriorityCpu(_: u32, irq: u32, prio: u8) void {
    setPriority(irq, prio);
}

pub fn disableIrq(irq: u32) void {
    const reg = D_ICENABLER0 + (irq / 32) * 4;
    const bit: u32 = @as(u32, 1) << @intCast(irq % 32);
    dist().write(u32, reg, bit);
}

pub fn setPriority(irq: u32, prio: u8) void {
    const reg = D_IPRIORITYR0 + (irq / 4) * 4;
    const shift: u5 = @intCast((irq % 4) * 8);
    var v = dist().read(u32, reg);
    v &= ~(@as(u32, 0xff) << shift);
    v |= @as(u32, prio) << shift;
    dist().write(u32, reg, v);
}

pub fn acknowledge() u32 {
    return cpuif().read(u32, C_IAR);
}

pub fn endOfInterrupt(iar: u32) void {
    cpuif().write(u32, C_EOIR, iar);
}
