// RISC-V H-extension microVM (S1). Ferrite's riscv kernel runs in M-mode, so it
// drives virtualization directly: set mstatus.MPV + MPP=S and `mret` into a
// VS-mode guest, with hgatp as the G-stage (guest-physical -> physical, the
// "stage-2" equivalent). Guest traps land back in M-mode (mtvec). This is
// single-level virt on bare QEMU (misa.H is present), so no nested-virt wall.
//
// The world-switch is a setjmp/longjmp via the trap: hypRunVcpu saves the host
// context + return address, mrets into the guest; the guest's trap handler
// (hypTrapVec) restores the host and `ret`s back to hypRunVcpu's caller.
const uart = @import("uart_ns16550.zig");
const clint = @import("clint.zig");

// CSR helpers (named or numeric CSR via a comptime string).
inline fn csrRead(comptime csr: []const u8) u64 {
    return asm volatile ("csrr %[r], " ++ csr
        : [r] "=r" (-> u64),
    );
}
inline fn csrWrite(comptime csr: []const u8, v: u64) void {
    asm volatile ("csrw " ++ csr ++ ", %[v]"
        :
        : [v] "r" (v),
    );
}
inline fn csrSwap(comptime csr: []const u8, v: u64) u64 {
    return asm volatile ("csrrw %[old], " ++ csr ++ ", %[v]"
        : [old] "=r" (-> u64),
        : [v] "r" (v),
    );
}
inline fn csrSet(comptime csr: []const u8, v: u64) void {
    asm volatile ("csrrs zero, " ++ csr ++ ", %[v]"
        :
        : [v] "r" (v),
    );
}
inline fn csrClear(comptime csr: []const u8, v: u64) void {
    asm volatile ("csrrc zero, " ++ csr ++ ", %[v]"
        :
        : [v] "r" (v),
    );
}

const MIE_MTIE: u64 = 1 << 7; // machine timer interrupt enable
const HVIP_VSTIP: u64 = 1 << 6; // VS-mode timer interrupt pending (inject)
const CAUSE_MTI: u64 = 7; // machine timer interrupt (mcause low bits)
const SBI_EID_TIME: u64 = 0x5449_4D45; // "TIME" extension
const MTIMECMP_OFF: u64 = ~@as(u64, 0); // far-future = disabled

// Numeric CSRs the baseline assembler doesn't know by name.
const CSR_HVIP = "0x645"; // hypervisor virtual interrupt pending
const CSR_HTIMEDELTA = "0x605"; // guest time = mtime + htimedelta
const CSR_MCOUNTEREN = "0x306"; // M lets lower privs read counters (time/cycle/...)
const CSR_HCOUNTEREN = "0x606"; // HS lets VS read counters
const CSR_HIDELEG = "0x603"; // delegate interrupts to VS-mode
const CSR_HIE = "0x604"; // HS-level enable for VS interrupts
const HIDELEG_VS = 0x444; // VSSIP(2) | VSTIP(6) | VSEIP(10)
const HIE_VSTIE = 1 << 6; // VS-mode timer interrupt enable

// Guest vCPU state. Offsets are load-bearing (referenced by the asm below).
const VCpu = extern struct {
    regs: [32]u64 = @splat(0), // 0x000  x0..x31
    pc: u64 = 0, //               0x100  guest PC (mepc)
    mcause: u64 = 0, //           0x108  exit cause
    mtval: u64 = 0, //            0x110  exit trap value
    htval: u64 = 0, //            0x118  guest-physical fault addr (>>2)
    hgatp: u64 = 0, //            0x120  G-stage root | mode | VMID
    // Guest privilege at mret, read by the world-switch: 0 = VS-mode (a guest
    // kernel), 1 = VU-mode (a sandboxed userspace program, whose ecall traps to
    // the M-mode host as ECALL-from-U). 0x128.
    mode: u64 = 0,
};

// Host context saved across a world-switch so hypTrapVec can return to the
// hypRunVcpu caller. 0x00 ra/sp/gp/tp, 0x20 s0..s11, 0x80 mtvec, 0x88 mstatus,
// 0x90 vcpu ptr, 0x98 scratch.
export var hyp_host_save: [20]u64 align(16) = @splat(0);

// A guest VM's G-stage (Sv39x4) address space. The page-table pages come from a
// caller-supplied page allocator (hyp.zig is in the arch module and can't reach
// kernel.memory directly), so one allocator backs many VMs. `alloc(n)` returns
// the physical base of n contiguous zeroed pages, or null. M-mode runs paging
// off, so physical == the linker/allocator address.
pub const Vm = struct {
    root: u64, // physical base of the 16 KiB-aligned Sv39x4 root
    alloc: *const fn (usize) ?u64,
    p2v: *const fn (u64) usize, // physical -> kernel-virtual (identity in M-mode, but be explicit)

    // Leaf PTE bits for normal guest RAM: V|R|W|X|U|A|D. The arch-neutral VMM
    // (vmm.zig) maps guest RAM with this.
    pub const ram_leaf: u64 = 0xDF;

    fn zero(self: *const Vm, pa: u64, len: usize) void {
        @memset(@as([*]u8, @ptrFromInt(self.p2v(pa)))[0..len], 0);
    }

    pub fn init(alloc: *const fn (usize) ?u64, p2v: *const fn (u64) usize) ?Vm {
        // The Sv39x4 root is 4 pages and must be 16 KiB-aligned; over-allocate 8
        // and align up.
        const base = alloc(8) orelse return null;
        const root = (base + 0x3fff) & ~@as(u64, 0x3fff);
        const self: Vm = .{ .root = root, .alloc = alloc, .p2v = p2v };
        self.zero(root, 0x4000);
        return self;
    }

    // Resolve (creating if needed) the next-level table under table[idx].
    fn ensure(self: *Vm, tbl: u64, idx: usize) ?u64 {
        const t: [*]u64 = @ptrFromInt(self.p2v(tbl));
        if (t[idx] & 1 != 0) return (t[idx] >> 10) << 12; // existing table PTE
        const page = self.alloc(1) orelse return null;
        self.zero(page, 4096);
        t[idx] = ((page >> 12) << 10) | 1; // V, non-leaf -> pointer
        return page;
    }

    // Map one 4 KiB guest-physical page to a host-physical page. flags is the
    // leaf PTE permission set (e.g. 0xDF = V|R|W|X|U|A|D).
    pub fn mapPage(self: *Vm, gpa: u64, hpa: u64, flags: u64) bool {
        const l1 = self.ensure(self.root, (gpa >> 30) & 0x7ff) orelse return false;
        const l0 = self.ensure(l1, (gpa >> 21) & 0x1ff) orelse return false;
        @as([*]u64, @ptrFromInt(self.p2v(l0)))[(gpa >> 12) & 0x1ff] = ((hpa >> 12) << 10) | flags;
        return true;
    }

    pub fn hgatp(self: *const Vm) u64 {
        return (@as(u64, 8) << 60) | (self.root >> 12); // Sv39x4, VMID 0
    }

    // Arch-neutral name for "the value the vCPU's translation-base register
    // should hold" (hgatp here, VTTBR_EL2 on aarch64). Used by vmm.zig.
    pub fn tableBase(self: *const Vm) u64 {
        return self.hgatp();
    }
};

// VS-mode guest payload: prints a string through SBI legacy console_putchar
// (a7=1), each char trapping out to the host as an ECALL-from-VS, then asks the
// SEE to shut the VM down (a7=8). Position-independent (PC-relative la).
export fn hypGuestBlob() callconv(.naked) noreturn {
    asm volatile (
        \\ la    t0, 5f            // t0 = &msg (PC-relative)
        \\4: lb   a0, 0(t0)        // next char
        \\ beqz  a0, 6f            // NUL -> done
        \\ li    a7, 1             // SBI legacy console_putchar
        \\ ecall                   // -> traps to the host (mcause 10)
        \\ addi  t0, t0, 1
        \\ j     4b
        \\6: li   a7, 8            // SBI legacy shutdown
        \\ ecall
        \\7: j    7b
        \\5: .asciz "hello from the RISC-V VS-mode guest\n"
    );
}

// Enter the guest (a0 = *VCpu). Does not return normally; hypTrapVec returns to
// our caller after the guest traps out.
export fn hypRunVcpu() callconv(.naked) noreturn {
    asm volatile (
        \\ la    t0, hyp_host_save
        \\ sd    ra, 0(t0)
        \\ sd    sp, 8(t0)
        \\ sd    gp, 16(t0)
        \\ sd    tp, 24(t0)
        \\ sd    s0, 32(t0)
        \\ sd    s1, 40(t0)
        \\ sd    s2, 48(t0)
        \\ sd    s3, 56(t0)
        \\ sd    s4, 64(t0)
        \\ sd    s5, 72(t0)
        \\ sd    s6, 80(t0)
        \\ sd    s7, 88(t0)
        \\ sd    s8, 96(t0)
        \\ sd    s9, 104(t0)
        \\ sd    s10, 112(t0)
        \\ sd    s11, 120(t0)
        \\ csrr  t1, mtvec
        \\ sd    t1, 128(t0)
        \\ csrr  t1, mstatus
        \\ sd    t1, 136(t0)
        \\ sd    a0, 144(t0)            // vcpu ptr
        \\ csrw  mscratch, t0           // mscratch = &hyp_host_save
        \\ la    t1, hypTrapVec
        \\ csrw  mtvec, t1
        \\ ld    t1, 288(a0)            // vcpu.hgatp
        \\ csrw  0x680, t1              // hgatp
        \\ csrw  0x280, zero            // vsatp = Bare
        \\ li    t1, 0x200000000        // hstatus.VSXL = 2 (64-bit VS)
        \\ csrw  0x600, t1              // hstatus
        \\ csrr  t1, mstatus
        \\ li    t2, 0x1800             // MPP mask
        \\ not   t2, t2
        \\ and   t1, t1, t2             // clear MPP (-> U = 00)
        \\ ld    t3, 296(a0)            // vcpu.mode (0 = VS guest, 1 = VU sandbox)
        \\ bnez  t3, 1f                 // VU: leave MPP = U
        \\ li    t2, 0x800              // MPP = S (VS guest)
        \\ or    t1, t1, t2
        \\1:
        \\ li    t2, 0x8000000000       // MPV = 1 (enter virtualized on mret)
        \\ or    t1, t1, t2
        \\ csrw  mstatus, t1
        \\ ld    t1, 256(a0)            // vcpu.pc -> mepc
        \\ csrw  mepc, t1
        // load guest GPRs (a0 = vcpu base; load a0 last)
        \\ ld    ra, 8(a0)
        \\ ld    sp, 16(a0)
        \\ ld    gp, 24(a0)
        \\ ld    tp, 32(a0)
        \\ ld    t0, 40(a0)
        \\ ld    t1, 48(a0)
        \\ ld    t2, 56(a0)
        \\ ld    s0, 64(a0)
        \\ ld    s1, 72(a0)
        \\ ld    a1, 88(a0)
        \\ ld    a2, 96(a0)
        \\ ld    a3, 104(a0)
        \\ ld    a4, 112(a0)
        \\ ld    a5, 120(a0)
        \\ ld    a6, 128(a0)
        \\ ld    a7, 136(a0)
        \\ ld    s2, 144(a0)
        \\ ld    s3, 152(a0)
        \\ ld    s4, 160(a0)
        \\ ld    s5, 168(a0)
        \\ ld    s6, 176(a0)
        \\ ld    s7, 184(a0)
        \\ ld    s8, 192(a0)
        \\ ld    s9, 200(a0)
        \\ ld    s10, 208(a0)
        \\ ld    s11, 216(a0)
        \\ ld    t3, 224(a0)
        \\ ld    t4, 232(a0)
        \\ ld    t5, 240(a0)
        \\ ld    t6, 248(a0)
        \\ ld    a0, 80(a0)
        \\ mret
    );
}

// M-mode trap from the VS-mode guest. Saves guest state into the vcpu, restores
// the host, and `ret`s back into hypRunVcpu's caller (staying in M-mode).
export fn hypTrapVec() align(4) callconv(.naked) noreturn {
    asm volatile (
        \\ csrrw t6, mscratch, t6       // t6 = &hyp_host_save, mscratch = guest t6
        \\ sd    t5, 152(t6)            // stash guest t5 in host_save.scratch
        \\ ld    t5, 144(t6)            // t5 = vcpu ptr
        \\ sd    ra, 8(t5)
        \\ sd    sp, 16(t5)
        \\ sd    gp, 24(t5)
        \\ sd    tp, 32(t5)
        \\ sd    t0, 40(t5)
        \\ sd    t1, 48(t5)
        \\ sd    t2, 56(t5)
        \\ sd    s0, 64(t5)
        \\ sd    s1, 72(t5)
        \\ sd    a0, 80(t5)
        \\ sd    a1, 88(t5)
        \\ sd    a2, 96(t5)
        \\ sd    a3, 104(t5)
        \\ sd    a4, 112(t5)
        \\ sd    a5, 120(t5)
        \\ sd    a6, 128(t5)
        \\ sd    a7, 136(t5)
        \\ sd    s2, 144(t5)
        \\ sd    s3, 152(t5)
        \\ sd    s4, 160(t5)
        \\ sd    s5, 168(t5)
        \\ sd    s6, 176(t5)
        \\ sd    s7, 184(t5)
        \\ sd    s8, 192(t5)
        \\ sd    s9, 200(t5)
        \\ sd    s10, 208(t5)
        \\ sd    s11, 216(t5)
        \\ sd    t3, 224(t5)
        \\ sd    t4, 232(t5)
        \\ ld    t0, 152(t6)            // guest t5 (from scratch)
        \\ sd    t0, 240(t5)
        \\ csrr  t0, mscratch           // guest t6
        \\ sd    t0, 248(t5)
        \\ csrr  t0, mepc
        \\ sd    t0, 256(t5)
        \\ csrr  t0, mcause
        \\ sd    t0, 264(t5)
        \\ csrr  t0, mtval
        \\ sd    t0, 272(t5)
        \\ csrr  t0, 0x643              // htval
        \\ sd    t0, 280(t5)
        // restore host
        \\ csrw  0x680, zero            // hgatp = Bare
        \\ ld    t0, 128(t6)
        \\ csrw  mtvec, t0
        \\ ld    t0, 136(t6)
        \\ csrw  mstatus, t0
        \\ ld    ra, 0(t6)
        \\ ld    sp, 8(t6)
        \\ ld    gp, 16(t6)
        \\ ld    tp, 24(t6)
        \\ ld    s0, 32(t6)
        \\ ld    s1, 40(t6)
        \\ ld    s2, 48(t6)
        \\ ld    s3, 56(t6)
        \\ ld    s4, 64(t6)
        \\ ld    s5, 72(t6)
        \\ ld    s6, 80(t6)
        \\ ld    s7, 88(t6)
        \\ ld    s8, 96(t6)
        \\ ld    s9, 104(t6)
        \\ ld    s10, 112(t6)
        \\ ld    s11, 120(t6)
        \\ ret
    );
}

fn misaHasH() bool {
    const misa = asm volatile ("csrr %[r], misa"
        : [r] "=r" (-> u64),
    );
    return (misa >> ('H' - 'A')) & 1 != 0;
}

pub fn hasH() bool {
    return misaHasH();
}

// Why a guest run returned to the host. The VMM (the demo today, the syscall
// layer next) inspects this and the vcpu registers to service the exit.
// Cross-arch exit reason. Same tag set + integer values on every arch so the
// syscall layer can forward `@intFromEnum(reason)` to userspace unchanged.
// riscv only ever produces hypercall/fault/interrupt (guests talk SBI, not
// MMIO); mmio/poweroff exist for the aarch64 backend.
pub const ExitReason = enum(u8) {
    hypercall = 0, // SBI ecall (riscv) / HVC (aarch64); a7/a0 carry the call
    fault = 1, // a synchronous exception we don't handle (see mcause/mtval)
    interrupt = 2, // a host interrupt fired during the guest
    mmio = 3, // guest device access to be emulated in userspace (aarch64)
    poweroff = 4, // guest asked to power off (aarch64 PSCI)
};

pub const Exit = struct {
    reason: ExitReason,
    mcause: u64 = 0,
    mtval: u64 = 0,
    htval: u64 = 0, // guest-physical fault address >> 2 (for guest-page-faults)
    // MMIO detail (aarch64 only; zero on riscv).
    addr: u64 = 0,
    size: u64 = 0,
    is_write: bool = false,
    reg: u32 = 0,
    data: u64 = 0,
};

// A virtual hart: guest register state plus the run primitive. Reusable by any
// VMM (the in-kernel demo, or the userspace VMM via syscalls).
pub const Vcpu = struct {
    state: VCpu = .{},

    pub fn setEntry(self: *Vcpu, pc: u64, hgatp: u64) void {
        self.state.pc = pc;
        self.state.hgatp = hgatp;
    }
    // Enter the guest at VU-mode (sandbox a userspace program): its ecall traps
    // to the M-mode host as ECALL-from-U, so no SBI/guest-kernel is needed. `sp`
    // lands in x2; the program runs flat (vsatp stays Bare).
    pub fn setEl0Entry(self: *Vcpu, pc: u64, sp: u64, hgatp: u64) void {
        self.state.pc = pc;
        self.state.regs[2] = sp; // x2 = sp
        self.state.hgatp = hgatp;
        self.state.mode = 1; // VU-mode
    }
    pub fn reg(self: *const Vcpu, i: usize) u64 {
        return self.state.regs[i];
    }
    pub fn setReg(self: *Vcpu, i: usize, v: u64) void {
        self.state.regs[i] = v;
    }
    pub fn advancePc(self: *Vcpu, bytes: u64) void {
        self.state.pc +%= bytes;
    }

    // One VM entry. The PMP grant, mscratch, M-interrupt mask, machine timer
    // (CLINT mtimecmp) and htimedelta are lent across the switch and restored on
    // return, so the host kernel sees consistent CSRs between exits.
    //
    // The guest's virtual timer is serviced in-kernel (it needs M-mode CLINT +
    // hvip access): an SBI set_timer programs the CLINT, and when the machine
    // timer fires during the guest we inject a VS-mode timer interrupt
    // (hvip.VSTIP) and re-enter. Only other SBI calls / faults return to the
    // caller (the in-kernel demo or the userspace VMM).
    pub fn run(self: *Vcpu) Exit {
        const saved_pmpcfg0 = csrRead("pmpcfg0");
        const saved_pmpaddr0 = csrRead("pmpaddr0");
        // VS-mode needs a PMP grant to touch physical memory; [0,4 GiB) RWX.
        asm volatile (
            \\ li   t0, 0x40000000
            \\ csrw pmpaddr0, t0
            \\ li   t0, 0x0F
            \\ csrw pmpcfg0, t0
            ::: .{ .t0 = true });
        const saved_mscratch = csrRead("mscratch");
        // Enable ONLY the machine timer during the guest (so its vtimer can
        // fire + trap to us); mask the host's other M interrupts.
        const saved_mie = csrSwap("mie", MIE_MTIE);
        // Lend the machine timer: disable the host's pending tick, restore on
        // exit (an overdue host tick then fires immediately, catching up).
        const saved_mtimecmp = clint.readMtimecmp(0);
        clint.setMtimecmp(0, MTIMECMP_OFF);
        const saved_htimedelta = csrRead(CSR_HTIMEDELTA);
        csrWrite(CSR_HTIMEDELTA, 0); // guest `time` == mtime
        // Let the guest read `time`/counters (else VS-mode rdtime traps illegal).
        const saved_mcounteren = csrRead(CSR_MCOUNTEREN);
        const saved_hcounteren = csrRead(CSR_HCOUNTEREN);
        csrWrite(CSR_MCOUNTEREN, 0xffff_ffff);
        csrWrite(CSR_HCOUNTEREN, 0xffff_ffff);
        // Deliver injected VS interrupts to the guest: delegate them to VS-mode
        // and enable the VS timer at the HS level (the guest sets its own
        // vsie.STIE / vsstatus.SIE).
        const saved_hideleg = csrRead(CSR_HIDELEG);
        const saved_hie = csrRead(CSR_HIE);
        csrWrite(CSR_HIDELEG, saved_hideleg | HIDELEG_VS);
        csrWrite(CSR_HIE, saved_hie | HIE_VSTIE);

        defer {
            csrWrite(CSR_HIE, saved_hie);
            csrWrite(CSR_HIDELEG, saved_hideleg);
            csrWrite(CSR_MCOUNTEREN, saved_mcounteren);
            csrWrite(CSR_HCOUNTEREN, saved_hcounteren);
            csrWrite(CSR_HTIMEDELTA, saved_htimedelta);
            clint.setMtimecmp(0, saved_mtimecmp);
            csrWrite("mie", saved_mie);
            csrWrite("mscratch", saved_mscratch);
            csrWrite("pmpaddr0", saved_pmpaddr0);
            csrWrite("pmpcfg0", saved_pmpcfg0);
        }

        while (true) {
            asm volatile ("mv a0, %[v]\n call hypRunVcpu"
                :
                : [v] "r" (&self.state),
                : .{ .a0 = true, .a1 = true, .a2 = true, .a3 = true, .a4 = true, .a5 = true, .a6 = true, .a7 = true, .t0 = true, .t1 = true, .t2 = true, .t3 = true, .t4 = true, .t5 = true, .t6 = true, .ra = true, .memory = true });

            const mc = self.state.mcause;
            if ((mc >> 63) != 0) { // interrupt
                if ((mc & 0xff) == CAUSE_MTI) {
                    // The guest's armed deadline fired: inject its VS-mode timer
                    // interrupt and disarm the machine timer, then re-enter.
                    csrSet(CSR_HVIP, HVIP_VSTIP);
                    clint.setMtimecmp(0, MTIMECMP_OFF);
                    continue;
                }
                return .{ .reason = .interrupt, .mcause = mc, .mtval = self.state.mtval, .htval = self.state.htval };
            }
            if ((mc & 0xff) == 8) { // ECALL from VU-mode (a sandboxed program's syscall)
                self.state.pc +%= 4; // retire the ecall; the caller sets the return value
                return .{ .reason = .hypercall, .mcause = mc, .mtval = self.state.mtval, .htval = self.state.htval };
            }
            if ((mc & 0xff) == 10) { // ECALL from VS-mode (SBI)
                const a7 = self.state.regs[17];
                const a6 = self.state.regs[16];
                if (a7 == 0 or (a7 == SBI_EID_TIME and a6 == 0)) {
                    // SBI set_timer(a0): arm the machine timer for the guest and
                    // clear any pending injection (the guest just re-armed).
                    clint.setMtimecmp(0, self.state.regs[10]);
                    csrClear(CSR_HVIP, HVIP_VSTIP);
                    if (a7 == SBI_EID_TIME) {
                        self.state.regs[10] = 0; // SBI_SUCCESS
                        self.state.regs[11] = 0;
                    }
                    self.state.pc +%= 4;
                    continue; // handled in-kernel
                }
                self.state.pc +%= 4; // retire the ecall; caller sets the return value
                return .{ .reason = .hypercall, .mcause = mc, .mtval = self.state.mtval, .htval = self.state.htval };
            }
            return .{ .reason = .fault, .mcause = mc, .mtval = self.state.mtval, .htval = self.state.htval };
        }
    }
};

// Demo VMM: an isolated VS-mode guest that prints via SBI, now built on the
// allocator-backed Vm + the reusable Vcpu facility (a thin client of both).
// `alloc(n)` is the kernel page allocator, threaded in from kmain.
pub fn hypRunGuestDemo(alloc: *const fn (usize) ?u64, p2v: *const fn (u64) usize) void {
    if (!hasH()) return;

    var vm = Vm.init(alloc, p2v) orelse {
        uart.print("[hyp] VM init failed\n", .{});
        return;
    };
    const ram = alloc(1) orelse return; // one page of guest RAM
    @memcpy(@as([*]u8, @ptrFromInt(p2v(ram)))[0..256], @as([*]const u8, @ptrFromInt(@intFromPtr(&hypGuestBlob)))[0..256]);
    const gpa: u64 = 0x8000_0000;
    if (!vm.mapPage(gpa, ram, 0xDF)) { // V|R|W|X|U|A|D
        uart.print("[hyp] VM map failed\n", .{});
        return;
    }

    var vcpu: Vcpu = .{};
    vcpu.setEntry(gpa, vm.hgatp());

    uart.print("[hyp] booting riscv VS-mode guest; console follows:\n[guest] ", .{});
    var ecalls: u32 = 0;
    var guard: u32 = 0;
    while (guard < 100000) : (guard += 1) {
        const exit = vcpu.run();
        if (exit.reason == .hypercall) {
            ecalls += 1;
            switch (vcpu.reg(17)) { // a7 = SBI function (legacy)
                1 => uart.print("{c}", .{@as(u8, @truncate(vcpu.reg(10)))}), // console_putchar(a0)
                8 => { // shutdown
                    uart.print("\n[hyp] riscv guest SBI shutdown after {d} SBI calls\n", .{ecalls});
                    break;
                },
                else => vcpu.setReg(10, @bitCast(@as(i64, -2))), // SBI_ERR_NOT_SUPPORTED
            }
            continue; // run() already retired the ecall
        }
        uart.print("\n[hyp] riscv guest unexpected exit mcause=0x{x} mepc=0x{x} mtval=0x{x}\n", .{ exit.mcause, vcpu.state.pc, exit.mtval });
        break;
    }
}
