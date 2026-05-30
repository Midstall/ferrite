// ESP32-C6 SYSTIMER + INT_MATRIX + PLIC wiring for a periodic timer
// interrupt. References (all from esp-idf v5.1 headers):
//   - systimer_reg.h          : SYSTIMER @ 0x6001F000
//   - interrupt_matrix_reg.h  : INT_MATRIX @ 0x60010000
//   - plic_reg.h              : PLIC_MX  @ 0x20001000
//
// Boot flow per esp-hal-rs `set_interrupt_priority`/`map_raw`:
//   1. Wire systimer target0 -> CPU IRQ N via INT_MATRIX.
//   2. Set kind (level) + priority + enable bit in PLIC_MX.
//   3. Configure systimer target0 in periodic mode with desired period.
//   4. Caller sets mstatus.MIE to globally enable interrupts.

inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

const SYSTIMER_BASE: usize = 0x6000_A000;
const SYSTIMER_CONF_REG = SYSTIMER_BASE + 0x00;
const SYSTIMER_TARGET0_CONF_REG = SYSTIMER_BASE + 0x34;
const SYSTIMER_COMP0_LOAD_REG = SYSTIMER_BASE + 0x50;
const SYSTIMER_INT_ENA_REG = SYSTIMER_BASE + 0x64;
const SYSTIMER_INT_CLR_REG = SYSTIMER_BASE + 0x6C;

const SYSTIMER_CLK_EN: u32 = 1 << 31;
const SYSTIMER_TIMER_UNIT0_WORK_EN: u32 = 1 << 30;
// Comparator (target0) has its own enable in CONF_REG bit 24. Missing this
// means counter runs but the comparator never asserts -> no interrupt.
const SYSTIMER_TARGET0_WORK_EN: u32 = 1 << 24;
const SYSTIMER_TARGET0_PERIOD_MODE: u32 = 1 << 30;
const SYSTIMER_TARGET0_INT_BIT: u32 = 1 << 0; // bit 0 for target0 in INT_ENA/CLR/RAW

const INT_MATRIX_BASE: usize = 0x6001_0000;
// Per esp-idf interrupt_matrix_reg.h, systimer target0's MAP reg is +0xE4.
const INTMTX_CORE0_SYSTIMER_TARGET0_INTR_MAP_REG = INT_MATRIX_BASE + 0xE4;

const PLIC_MX_BASE: usize = 0x2000_1000;
const PLIC_MXINT_ENABLE_REG = PLIC_MX_BASE + 0x00;
const PLIC_MXINT_TYPE_REG = PLIC_MX_BASE + 0x04;
const PLIC_MXINT_CLEAR_REG = PLIC_MX_BASE + 0x08;
const PLIC_EMIP_STATUS_REG = PLIC_MX_BASE + 0x0C;
const PLIC_MXINT0_PRI_REG = PLIC_MX_BASE + 0x10;
const PLIC_MXINT_THRESH_REG = PLIC_MX_BASE + 0x90;
const PLIC_MXINT_CLAIM_REG = PLIC_MX_BASE + 0x94;
const PLIC_MXINT_CONF_REG: usize = 0x2000_13FC;

const INTMTX_CORE0_INT_STATUS_REG_0 = INT_MATRIX_BASE + 0x134;
const INTMTX_CORE0_INT_STATUS_REG_1 = INT_MATRIX_BASE + 0x138;

// Pick CPU IRQ 5 - arbitrary, must be 1..=31 (0 means "unmapped").
pub const CPU_IRQ_SYSTIMER: u32 = 5;
const CPU_IRQ_PRIORITY: u32 = 1;

// systimer counts at ~16 MHz on default ROM clock config. 16_000_000 ticks
// ~ 1 second.
pub const TICKS_PER_SECOND: u32 = 16_000_000;

pub fn init(period_ticks: u32) void {
    // 1. INT_MATRIX: route systimer.target0 -> CPU IRQ N.
    reg(INTMTX_CORE0_SYSTIMER_TARGET0_INTR_MAP_REG).* = CPU_IRQ_SYSTIMER;

    // 2. PLIC_MX: level-triggered, priority 1, threshold 0, enabled.
    var t = reg(PLIC_MXINT_TYPE_REG).*;
    t &= ~(@as(u32, 1) << @intCast(CPU_IRQ_SYSTIMER));
    reg(PLIC_MXINT_TYPE_REG).* = t;
    reg(PLIC_MXINT0_PRI_REG + 4 * CPU_IRQ_SYSTIMER).* = CPU_IRQ_PRIORITY;
    reg(PLIC_MXINT_THRESH_REG).* = 0;
    var en = reg(PLIC_MXINT_ENABLE_REG).*;
    en |= (@as(u32, 1) << @intCast(CPU_IRQ_SYSTIMER));
    reg(PLIC_MXINT_ENABLE_REG).* = en;

    // 3. Systimer: clock + unit on, but leave target0 DISABLED until period
    //    is loaded. Otherwise the comparator wakes against the default
    //    (zero) target, fires a stale event, and never re-arms cleanly.
    var conf = reg(SYSTIMER_CONF_REG).*;
    conf &= ~SYSTIMER_TARGET0_WORK_EN;
    conf |= SYSTIMER_CLK_EN | SYSTIMER_TIMER_UNIT0_WORK_EN;
    reg(SYSTIMER_CONF_REG).* = conf;

    // Configure target0 against UNIT0 with the period, then toggle
    // PERIOD_MODE (clear -> set) to re-arm the comparator (esp-hal does
    // this; without the toggle the periodic mode latch can be stale).
    reg(SYSTIMER_TARGET0_CONF_REG).* = period_ticks & 0x03FF_FFFF; // unit_sel=0, period_mode=0
    reg(SYSTIMER_TARGET0_CONF_REG).* = SYSTIMER_TARGET0_PERIOD_MODE | (period_ticks & 0x03FF_FFFF);
    reg(SYSTIMER_COMP0_LOAD_REG).* = 1;

    // Clear any pending IRQ, then enable + start the comparator.
    reg(SYSTIMER_INT_CLR_REG).* = SYSTIMER_TARGET0_INT_BIT;
    var ena = reg(SYSTIMER_INT_ENA_REG).*;
    ena |= SYSTIMER_TARGET0_INT_BIT;
    reg(SYSTIMER_INT_ENA_REG).* = ena;

    conf = reg(SYSTIMER_CONF_REG).*;
    conf |= SYSTIMER_TARGET0_WORK_EN;
    reg(SYSTIMER_CONF_REG).* = conf;
}

pub fn ack() void {
    reg(SYSTIMER_INT_CLR_REG).* = SYSTIMER_TARGET0_INT_BIT;
}

const SYSTIMER_UNIT0_VALUE_LO_REG = SYSTIMER_BASE + 0x44;
const SYSTIMER_UNIT0_VALUE_HI_REG = SYSTIMER_BASE + 0x40;
const SYSTIMER_UNIT0_OP_REG = SYSTIMER_BASE + 0x04;
const SYSTIMER_INT_RAW_REG = SYSTIMER_BASE + 0x68; // per esp-idf systimer_reg.h
const SYSTIMER_INT_ST_REG = SYSTIMER_BASE + 0x70;

const TIMER_UNIT0_UPDATE: u32 = 1 << 30; // request snapshot to VALUE_HI/LO

pub fn snapshot() u64 {
    reg(SYSTIMER_UNIT0_OP_REG).* = TIMER_UNIT0_UPDATE;
    // Counter snapshot is valid when bit 29 (TIMER_UNIT0_VALUE_VALID) is set.
    while ((reg(SYSTIMER_UNIT0_OP_REG).* & (1 << 29)) == 0) {}
    const lo = reg(SYSTIMER_UNIT0_VALUE_LO_REG).*;
    const hi = reg(SYSTIMER_UNIT0_VALUE_HI_REG).*;
    return (@as(u64, hi) << 32) | lo;
}

pub fn debugDump(uart: anytype) void {
    uart.print("  SYSTIMER_CONF = 0x{x}\n", .{reg(SYSTIMER_CONF_REG).*});
    uart.print("  TARGET0_CONF  = 0x{x}\n", .{reg(SYSTIMER_TARGET0_CONF_REG).*});
    uart.print("  INT_ENA       = 0x{x}\n", .{reg(SYSTIMER_INT_ENA_REG).*});
    uart.print("  INT_RAW       = 0x{x}\n", .{reg(SYSTIMER_INT_RAW_REG).*});
    uart.print("  INT_ST        = 0x{x}\n", .{reg(SYSTIMER_INT_ST_REG).*});
    uart.print("  unit0 counter = {d}\n", .{snapshot()});
    uart.print("  PLIC CONF     = 0x{x}\n", .{reg(PLIC_MXINT_CONF_REG).*});
    uart.print("  PLIC EN       = 0x{x}\n", .{reg(PLIC_MXINT_ENABLE_REG).*});
    uart.print("  PLIC TYPE     = 0x{x}\n", .{reg(PLIC_MXINT_TYPE_REG).*});
    uart.print("  PLIC PRI5     = 0x{x}\n", .{reg(PLIC_MXINT0_PRI_REG + 4 * CPU_IRQ_SYSTIMER).*});
    uart.print("  PLIC THRESH   = 0x{x}\n", .{reg(PLIC_MXINT_THRESH_REG).*});
    uart.print("  PLIC EMIP_ST  = 0x{x}\n", .{reg(PLIC_EMIP_STATUS_REG).*});
    uart.print("  INTMTX systimer.target0 = 0x{x}\n", .{reg(INTMTX_CORE0_SYSTIMER_TARGET0_INTR_MAP_REG).*});
    uart.print("  INTMTX status[0:1] = 0x{x} 0x{x}\n", .{ reg(INTMTX_CORE0_INT_STATUS_REG_0).*, reg(INTMTX_CORE0_INT_STATUS_REG_1).* });
}

/// Read the PLIC claim register; returns the highest-priority pending CPU
/// IRQ number, or 0 if none.
pub fn plicClaim() u32 {
    return reg(PLIC_MXINT_CLAIM_REG).*;
}

/// Acknowledge a CPU IRQ in PLIC by writing its number to the claim reg.
pub fn plicComplete(irq: u32) void {
    reg(PLIC_MXINT_CLAIM_REG).* = irq;
}
