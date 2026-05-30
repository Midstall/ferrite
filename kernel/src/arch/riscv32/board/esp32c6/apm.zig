// ESP32-C6 Access Permission Module (APM) setup.
//
// APM has two sides:
//
//   TEE block @ 0x6009_8000 - per-master security mode CSRs. Bits[1:0]
//   of TEE_M{N}_MODE_CTRL_REG select the master's security mode:
//       0 = TEE     1 = REE0     2 = REE1     3 = REE2
//   Default after reset: 0 (TEE) for HP CPU (master 0).
//
//   HP_APM @ 0x6009_9000 - region filters. For each of 16 regions:
//       ADDR_START + ADDR_END define the address range,
//       PMS_ATTR has 4 x 3-bit XWR groups (one per security mode),
//       REGION_FILTER_EN bit N enables region N's check.
//   Per-master enable in FUNC_CTRL @ 0xC4 (M{N}_PMS_FUNC_EN).
//
// Default behaviour: REGION_FILTER_EN[0]=1, REGION0 = [0,0xFFFFFFFF],
// REGION0.PMS_ATTR = 0 (deny everything for every mode). Only the
// FUNC_CTRL=0 bypass we already do in wdt.earlyInit keeps M-mode alive.
// For U-mode access we have to actually program REGION0 to permit it.

inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

const TEE_BASE: usize = 0x6009_8000;
const TEE_M0_MODE_CTRL_REG = TEE_BASE + 0x00;

const HP_APM_BASE: usize = 0x6009_9000;
const HP_APM_REGION_FILTER_EN_REG = HP_APM_BASE + 0x00;
const HP_APM_REGION0_ADDR_START_REG = HP_APM_BASE + 0x04;
const HP_APM_REGION0_ADDR_END_REG = HP_APM_BASE + 0x08;
const HP_APM_REGION0_PMS_ATTR_REG = HP_APM_BASE + 0x0C;
const HP_APM_FUNC_CTRL_REG = HP_APM_BASE + 0xC4;

// PMS_ATTR bit layout: R0 XWR at [2:0], R1 at [6:4], R2 at [10:8], R3 at [14:12].
// Bit 3, 7, 11, 15 are spacers. All-RWX-everywhere = 0x7777.
const PMS_ATTR_FULL: u32 = 0x0000_7777;

/// Open HP_APM region 0 to cover the full address space with R/W/X for
/// every security mode (TEE + REE0/1/2). Keeps M-mode unaffected
/// (FUNC_CTRL.M0=0 still bypasses) while giving U-mode access whichever
/// security mode it ends up running in.
pub fn allowAllUmode() void {
    // Disable region 0 filter while reconfiguring it (so transient bad
    // states aren't applied to fetches in flight).
    var fen = reg(HP_APM_REGION_FILTER_EN_REG).*;
    fen &= ~@as(u32, 1 << 0);
    reg(HP_APM_REGION_FILTER_EN_REG).* = fen;

    reg(HP_APM_REGION0_ADDR_START_REG).* = 0;
    reg(HP_APM_REGION0_ADDR_END_REG).* = 0xFFFF_FFFF;
    reg(HP_APM_REGION0_PMS_ATTR_REG).* = PMS_ATTR_FULL;

    // Re-enable region 0 filter, disable all higher regions so nothing
    // else interferes.
    reg(HP_APM_REGION_FILTER_EN_REG).* = 1;

    // Set HP_CPU master mode explicitly to TEE (0). Doesn't matter much
    // since REGION0 is open to every mode, but keeps the state defined.
    reg(TEE_M0_MODE_CTRL_REG).* = 0;

    // Enable per-master APM filtering so HP CPU accesses ARE checked
    // against REGION0. With REGION0 = full address space with R0/1/2
    // each set to RWX, any priv mode passes through. (We previously
    // disabled all M{N}_PMS_FUNC_EN in wdt.earlyInit; flip M0 back on.)
    var fc = reg(HP_APM_FUNC_CTRL_REG).*;
    fc |= 1 << 0; // M0_PMS_FUNC_EN
    reg(HP_APM_FUNC_CTRL_REG).* = fc;
}

pub fn dump(uart: anytype) void {
    uart.print("APM: filter_en=0x{x} R0_start=0x{x} R0_end=0x{x} R0_pms=0x{x} func_ctrl=0x{x} tee_m0=0x{x}\n", .{
        reg(HP_APM_REGION_FILTER_EN_REG).*,
        reg(HP_APM_REGION0_ADDR_START_REG).*,
        reg(HP_APM_REGION0_ADDR_END_REG).*,
        reg(HP_APM_REGION0_PMS_ATTR_REG).*,
        reg(HP_APM_FUNC_CTRL_REG).*,
        reg(TEE_M0_MODE_CTRL_REG).*,
    });
}
