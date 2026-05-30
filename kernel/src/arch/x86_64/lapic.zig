const mmu = @import("mmu.zig");
const pit = @import("pit.zig");

const APIC_BASE_MSR: u32 = 0x1B;

const Reg = struct {
    const SVR: u32 = 0xF0;
    const EOI: u32 = 0xB0;
    const LVT_TIMER: u32 = 0x320;
    const TIMER_INIT_COUNT: u32 = 0x380;
    const TIMER_CURRENT_COUNT: u32 = 0x390;
    const TIMER_DIVIDE: u32 = 0x3E0;
};

const DIVISOR_BY_16: u8 = 0x3;

var lapic_base: usize = 0;
var ticks_per_ms: u64 = 0;

inline fn rdmsr(reg: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [_] "={eax}" (lo),
          [_] "={edx}" (hi),
        : [reg] "{ecx}" (reg),
    );
    return (@as(u64, hi) << 32) | lo;
}

inline fn read(reg: u32) u32 {
    return @as(*volatile u32, @ptrFromInt(lapic_base + reg)).*;
}

inline fn write(reg: u32, val: u32) void {
    @as(*volatile u32, @ptrFromInt(lapic_base + reg)).* = val;
}

pub const InitError = error{
    MmuMapFailed,
};

pub fn init() InitError!void {
    const phys = rdmsr(APIC_BASE_MSR) & 0xFFFFF000;
    // Limine HHDM-maps the entire usable phys range as cacheable. LAPIC writes
    // need strong-uncacheable. mapMmio sets CACHE_DISABLE on the leaf and
    // is idempotent if the page is already present-as-2M.
    const virt = phys + mmu.hhdmOffset();
    mmu.mapMmio(virt, phys, 0x1000) catch return error.MmuMapFailed;

    lapic_base = @intCast(virt);
    write(Reg.SVR, 0x100 | 0xFF);
}

pub fn calibrate() void {
    const cal_ms: u32 = 10;

    write(Reg.TIMER_DIVIDE, DIVISOR_BY_16);
    write(Reg.LVT_TIMER, 1 << 16);

    pit.calibrationStart(cal_ms);
    write(Reg.TIMER_INIT_COUNT, 0xFFFF_FFFF);
    pit.calibrationWait();
    const current = read(Reg.TIMER_CURRENT_COUNT);
    write(Reg.TIMER_INIT_COUNT, 0);

    const elapsed: u64 = @as(u64, 0xFFFF_FFFF) - current;
    ticks_per_ms = elapsed / cal_ms;
}

pub fn enableTimerPeriodic(vector: u8, period_ns: u64) void {
    var init_count: u32 = @intCast((ticks_per_ms * period_ns) / 1_000_000);
    if (init_count == 0) init_count = 1;
    write(Reg.TIMER_DIVIDE, DIVISOR_BY_16);
    write(Reg.LVT_TIMER, @as(u32, vector) | (1 << 17));
    write(Reg.TIMER_INIT_COUNT, init_count);
}

pub fn endOfInterrupt() void {
    write(Reg.EOI, 0);
}

pub fn timerCurrentCount() u32 {
    return read(Reg.TIMER_CURRENT_COUNT);
}

pub fn ticksPerMs() u64 {
    return ticks_per_ms;
}
