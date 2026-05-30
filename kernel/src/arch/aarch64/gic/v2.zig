// GICv2 driver. QEMU virt uses this at -smp <= 8.
//   Distributor    GICD_BASE = 0x0800_0000  (8 KB)
//   CPU interface  GICC_BASE = 0x0801_0000  (8 KB, banked per CPU)

const mmio = @import("../mmio.zig");

const GICD_BASE: usize = 0x0800_0000;
const GICC_BASE: usize = 0x0801_0000;

const Reg = struct {
    const D_CTLR: usize = GICD_BASE + 0x000;
    const D_TYPER: usize = GICD_BASE + 0x004;
    const D_ISENABLER0: usize = GICD_BASE + 0x100;
    const D_ICENABLER0: usize = GICD_BASE + 0x180;
    const D_IPRIORITYR0: usize = GICD_BASE + 0x400;
    const D_ITARGETSR0: usize = GICD_BASE + 0x800;
    const D_ICFGR0: usize = GICD_BASE + 0xC00;

    const C_CTLR: usize = GICC_BASE + 0x000;
    const C_PMR: usize = GICC_BASE + 0x004;
    const C_BPR: usize = GICC_BASE + 0x008;
    const C_IAR: usize = GICC_BASE + 0x00C;
    const C_EOIR: usize = GICC_BASE + 0x010;
};

pub fn init() void {
    // Distributor is global; only the boot CPU enables it.
    mmio.write(u32, Reg.D_CTLR, 0);
    mmio.write(u32, Reg.D_CTLR, 1);
    initCpu(0);
}

// The GICv2 CPU interface (GICC_*) is banked: every CPU sees its own copy at
// the same MMIO address, so each CPU must run this itself. cpu_index is unused
// (the banking is implicit in which CPU issues the access).
pub fn initCpu(_: u32) void {
    mmio.write(u32, Reg.C_PMR, 0xff);
    mmio.write(u32, Reg.C_BPR, 0);
    mmio.write(u32, Reg.C_CTLR, 1);
}

pub fn enableIrq(irq: u32) void {
    // SPIs need an explicit CPU target. QEMU virt with -smp > 1 zeros ITARGETSR.
    if (irq >= 32) {
        const reg = Reg.D_ITARGETSR0 + (irq / 4) * 4;
        const shift: u5 = @intCast((irq % 4) * 8);
        var v = mmio.read(u32, reg);
        v &= ~(@as(u32, 0xff) << shift);
        v |= @as(u32, 0x01) << shift;
        mmio.write(u32, reg, v);
    }
    const en_reg = Reg.D_ISENABLER0 + (irq / 32) * 4;
    const bit: u32 = @as(u32, 1) << @intCast(irq % 32);
    mmio.write(u32, en_reg, bit);
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
    const reg = Reg.D_ICENABLER0 + (irq / 32) * 4;
    const bit: u32 = @as(u32, 1) << @intCast(irq % 32);
    mmio.write(u32, reg, bit);
}

pub fn setPriority(irq: u32, prio: u8) void {
    const reg = Reg.D_IPRIORITYR0 + (irq / 4) * 4;
    const shift: u5 = @intCast((irq % 4) * 8);
    var v = mmio.read(u32, reg);
    v &= ~(@as(u32, 0xff) << shift);
    v |= @as(u32, prio) << shift;
    mmio.write(u32, reg, v);
}

pub fn acknowledge() u32 {
    return mmio.read(u32, Reg.C_IAR);
}

pub fn endOfInterrupt(iar: u32) void {
    mmio.write(u32, Reg.C_EOIR, iar);
}
