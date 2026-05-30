// riscv64 M-mode → U-mode userspace entry. Mirrors usermode_smode.zig
// but uses the M-mode CSRs (mstatus/mepc/mscratch) and ends with `mret`.

pub fn init() void {}

pub fn enterUser(user_pc: u64, user_sp: u64) noreturn {
    // PMP: lower privilege modes need an explicit grant for memory access.
    // Without this, the first `mret` to U-mode traps with mcause=1
    // (inst-access-fault) on the user's first instruction fetch. TOR
    // covering 0..0x10_0000_0000 (64 GB) RWX is plenty for QEMU virt;
    // Sv39 satp still gates U-mode to mapped pages. M-mode is unaffected
    // because mstatus.MPRV=0. Inline with the mret-setup so we don't add
    // PMP writes to the boot path (signature.init runs before this).
    asm volatile (
    // PMP entry 0: TOR covering 0..0x10_0000_0000, RWX.
        \\ li    t0, 0x40000000
        \\ csrw  pmpaddr0, t0
        \\ li    t0, 0x0F
        \\ csrw  pmpcfg0, t0
        // Clear MPP (bits 12:11 = 00 → return to U-mode), set MPIE.
        \\ csrr  t0, mstatus
        \\ li    t1, 0x1800        // MPP mask
        \\ not   t1, t1
        \\ and   t0, t0, t1        // clear MPP → 00 (U-mode)
        \\ li    t1, 0x80           // MPIE (bit 7)
        \\ or    t0, t0, t1
        \\ csrw  mstatus, t0
        \\ csrw  mepc, %[pc]
        \\ csrw  mscratch, sp       // kernel sp for the next U→M trap
        \\ mv    sp, %[sp]
        \\ mret
        :
        : [pc] "r" (user_pc),
          [sp] "r" (user_sp),
        : .{ .t0 = true, .t1 = true, .memory = true });
    unreachable;
}
