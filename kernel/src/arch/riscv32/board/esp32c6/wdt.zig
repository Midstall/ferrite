// ESP32-C6 early-boot peripheral access setup. Cross-referenced against
// esp-idf v5.1's `soc/esp32c6/include/soc/*_reg.h` and esp-hal's
// `esp-hal/src/soc/esp32c6/mod.rs::pre_init`.
//
// Two things have to happen before our main code can do anything useful:
//   1. Disable the APM (Access Permission Module) "TEE-only" filters.
//      ROM hands off in REE mode; with the filters at their default, any
//      MMIO write to a protected peripheral silently faults and the chip
//      enters an unrecoverable reset loop with no console output.
//   2. Disable the four watchdogs ROM leaves armed (TIMG0, TIMG1, RWDT,
//      Super WDT) before they reset us ~1 s in.

inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

// APM access filter regs (esp-idf v5.1 soc/esp32c6/include/soc/*_apm_reg.h).
const LP_APM_FUNC_CTRL: usize = 0x600B_3800 + 0xC4;
const LP_APM0_FUNC_CTRL: usize = 0x6009_9800 + 0xC4;
const HP_APM_FUNC_CTRL: usize = 0x6009_9000 + 0xC4;

// TIMG0/TIMG1 WDT (timer_group_reg.h).
const TIMG0_BASE: usize = 0x6000_8000;
const TIMG1_BASE: usize = 0x6000_9000;
const TIMG_WDTCONFIG0_OFF: usize = 0x48;
const TIMG_WDTWPROTECT_OFF: usize = 0x64;
const TIMG_WDT_WKEY: u32 = 0x50D8_3AA1;

// LP_WDT (lp_wdt_reg.h).
const LP_WDT_BASE: usize = 0x600B_1C00;
const LP_WDT_CONFIG0_OFF: usize = 0x00;
const LP_WDT_WPROTECT_OFF: usize = 0x18;
const LP_WDT_SWD_CONFIG_OFF: usize = 0x1C;
const LP_WDT_SWD_WPROTECT_OFF: usize = 0x20;
const LP_WDT_WKEY: u32 = 0x50D8_3AA1;
// SWD WKEY differs by chip family - c6 uses the same as LP_WDT, older
// chips use 0x8F1D_312A. See esp-hal rtc_cntl/mod.rs::Swd::set_write_protection.
const LP_WDT_SWD_WKEY: u32 = 0x50D8_3AA1;
const LP_WDT_SWD_AUTO_FEED_EN_BIT: u32 = 1 << 18;

fn disableApm() void {
    // Open all access filters so HP CPU (REE mode) can write peripherals.
    reg(LP_APM_FUNC_CTRL).* = 0;
    reg(LP_APM0_FUNC_CTRL).* = 0;
    reg(HP_APM_FUNC_CTRL).* = 0;
}

fn disableTimgWdt(base: usize) void {
    reg(base + TIMG_WDTWPROTECT_OFF).* = TIMG_WDT_WKEY;
    reg(base + TIMG_WDTCONFIG0_OFF).* = 0; // EN bit 31 + flashboot bit 14 both cleared.
    reg(base + TIMG_WDTWPROTECT_OFF).* = 0;
}

fn disableLpWdt() void {
    reg(LP_WDT_BASE + LP_WDT_WPROTECT_OFF).* = LP_WDT_WKEY;
    reg(LP_WDT_BASE + LP_WDT_CONFIG0_OFF).* = 0;
    reg(LP_WDT_BASE + LP_WDT_WPROTECT_OFF).* = 0;
}

fn disableSuperWdt() void {
    // SWD has no EN bit; set AUTO_FEED to keep it pacified.
    reg(LP_WDT_BASE + LP_WDT_SWD_WPROTECT_OFF).* = LP_WDT_SWD_WKEY;
    const cur = reg(LP_WDT_BASE + LP_WDT_SWD_CONFIG_OFF).*;
    reg(LP_WDT_BASE + LP_WDT_SWD_CONFIG_OFF).* = cur | LP_WDT_SWD_AUTO_FEED_EN_BIT;
    reg(LP_WDT_BASE + LP_WDT_SWD_WPROTECT_OFF).* = 0;
}

pub fn earlyInit() void {
    disableApm();
    disableTimgWdt(TIMG0_BASE);
    disableTimgWdt(TIMG1_BASE);
    disableLpWdt();
    disableSuperWdt();
}
