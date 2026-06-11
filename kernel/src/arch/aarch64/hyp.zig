// aarch64 microVM facility: the reusable Vm/Vcpu/Exit objects behind the
// userspace VMM ([[ferrite-vmm-userspace]]), mirroring the riscv64 hyp.zig.
//
// The EL2 world-switch stub (hypVectors/hypSyncLowerEl/hypIrqLowerEl/
// hypExitCommon) and the standalone in-kernel demo live in start.zig; it is
// installed only when the kernel booted at EL2 (`-Dhyp`, hyp_active != 0). This
// module provides:
//   - VCpu: the guest register block the stub reads/writes (offsets are
//     load-bearing — shared with the asm in start.zig).
//   - runVcpu: one HVC into the stub (host hyp-call id=1 = RUN_VCPU).
//   - Vm: an allocator-backed 3-level (4 KiB granule) stage-2 page table.
//   - Vcpu: VCpu + run() that classifies the exit (HVC/SMC-PSCI/MMIO/IRQ).
//   - Exit/ExitReason: the cross-arch exit shape (same tags as riscv64).
//
// Arm guests have no SBI: their console is a trapped PL011 access, surfaced to
// userspace as an .mmio exit; PSCI SYSTEM_OFF/RESET surfaces as .poweroff.
const std = @import("std");
const builtin = @import("builtin");
const gic = @import("gic.zig");

// x18 is a reserved platform register on the uefi-msvc ABI: naming it in an asm
// clobber list is rejected there. The EL2 world-switch (runVcpu) clobbers it on
// raw boots but never runs under uefi (hyp is inactive), so we drop it from the
// clobber on that target. See runVcpu.
const x18_reserved = builtin.target.os.tag == .uefi;

// Set to 1 by start.zig's EL2 entry asm (raw boot, -Dhyp); stays 0 otherwise
// (e.g. limine boot has no EL2 stub). Lives in .data so the EL2 entry's write
// survives the later bss-zero. Defined here (always in the arch module) so
// non-raw boots that lack start.zig still link.
pub export var hyp_active: u32 linksection(".data") = 0;

/// True when the EL2 stub is live (kernel booted with -Dhyp). The VMM syscalls
/// gate on this at runtime, since without it runVcpu's HVC has no handler.
pub fn active() bool {
    return hyp_active != 0;
}

// vCPU state shared with the world-switch asm in start.zig. Field offsets are
// load-bearing; keep in sync with the stp/ldp offsets there.
pub const VCpu = extern struct {
    regs: [31]u64 = @splat(0), // x0..x30  (0x000)
    sp_el1: u64 = 0, //              0x0F8
    pc: u64 = 0, //   guest PC ->    0x100 (ELR_EL2)
    pstate: u64 = 0, // guest PSTATE 0x108 (SPSR_EL2)
    esr: u64 = 0, //  exit syndrome  0x110
    vttbr: u64 = 0, // stage-2 base  0x118 (| VMID)
    hpfar: u64 = 0, // faulting IPA  0x120 (HPFAR_EL2: IPA[47:12] in bits[39:4])
    far: u64 = 0, //  faulting VA    0x128 (FAR_EL2: page offset)
    // Guest virtual-timer state (managed by run(), not the stub). The host also
    // uses CNTV, so it is saved/restored around each run; these hold the guest's
    // CNTV across exits to userspace. Offsets past 0x128 are free (stub-unused).
    cntv_ctl: u64 = 0, //  0x130
    cntv_cval: u64 = 0, // 0x138
    // Guest privilege at entry, read by the world-switch stub: 0 = EL1 (a guest
    // kernel), 1 = EL0 + HCR_EL2.TGE (a sandboxed userspace program, whose svc
    // traps straight to EL2). 0x140.
    mode: u64 = 0,
};

// qemu virt GICv2 layout (the host stays on GICv2; the guest's GICC is routed
// to the hardware GICV via stage-2, and vIRQs are injected through GICH LRs).
const GICD_IPA: u64 = 0x0800_0000; // guest distributor (unmapped -> trap+emulate)
const GICC_IPA: u64 = 0x0801_0000; // guest CPU interface -> GICV
const GICV_PA: u64 = 0x0804_0000; // hardware virtual CPU interface
const GICH_BASE: u64 = 0x0803_0000; // hypervisor control (LR injection)
const VTIMER_PPI: u64 = 27; // CNTV interrupt (PPI 27)

inline fn cntvCtl() u64 {
    return asm volatile ("mrs %[r], cntv_ctl_el0"
        : [r] "=r" (-> u64),
    );
}
inline fn setCntvCtl(v: u64) void {
    asm volatile ("msr cntv_ctl_el0, %[v]"
        :
        : [v] "r" (v),
    );
}
inline fn cntvCval() u64 {
    return asm volatile ("mrs %[r], cntv_cval_el0"
        : [r] "=r" (-> u64),
    );
}
inline fn setCntvCval(v: u64) void {
    asm volatile ("msr cntv_cval_el0, %[v]"
        :
        : [v] "r" (v),
    );
}
inline fn gich(off: u64, v: u32) void {
    @as(*volatile u32, @ptrFromInt(GICH_BASE + off)).* = v;
}

// Physical GICC (the hypervisor's own CPU interface; the guest's GICC IPA is a
// separate stage-2 mapping to GICV). Used to ack/EOI physical IRQs at EL2.
const GICC_PHYS: u64 = 0x0801_0000;
const C_IAR: u64 = 0x0c;
const C_EOIR: u64 = 0x10;
inline fn giccRd(off: u64) u32 {
    return @as(*volatile u32, @ptrFromInt(GICC_PHYS + off)).*;
}
inline fn giccWr(off: u64, v: u32) void {
    @as(*volatile u32, @ptrFromInt(GICC_PHYS + off)).* = v;
}

// One VM entry: HVC with x0=1 (RUN_VCPU), x1=&vcpu. Traps to the EL2 stub,
// which world-switches into the guest and returns here on the guest's next
// exit (vcpu.esr/pc/regs/etc populated).
fn runVcpu(vcpu: *VCpu) void {
    // x0..x17 are caller-saved and trashed by the world-switch; x18 too on raw
    // (Ferrite reserves nothing in it). On uefi-msvc x18 is reserved, and this
    // path is dead there (hyp never active), so drop x18 to let it compile.
    if (comptime x18_reserved) {
        asm volatile ("hvc #0"
            :
            : [id] "{x0}" (@as(u64, 1)),
              [v] "{x1}" (@intFromPtr(vcpu)),
            : .{ .x0 = true, .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .memory = true });
    } else {
        asm volatile ("hvc #0"
            :
            : [id] "{x0}" (@as(u64, 1)),
              [v] "{x1}" (@intFromPtr(vcpu)),
            : .{ .x0 = true, .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .x18 = true, .memory = true });
    }
}

// Cross-arch exit reason (identical tag set + values on every arch so the
// syscall layer forwards @intFromEnum unchanged).
pub const ExitReason = enum(u8) {
    hypercall = 0, // HVC / non-power SMC
    fault = 1, // synchronous exception we don't classify
    interrupt = 2, // physical IRQ took the guest out
    mmio = 3, // stage-2 fault on a device page (emulate in userspace)
    poweroff = 4, // PSCI SYSTEM_OFF / SYSTEM_RESET
};

pub const Exit = struct {
    reason: ExitReason,
    // unused diag fields kept name-compatible with riscv (zero on aarch64)
    mcause: u64 = 0,
    mtval: u64 = 0,
    htval: u64 = 0,
    // MMIO detail (valid when reason == .mmio).
    addr: u64 = 0,
    size: u64 = 0,
    is_write: bool = false,
    reg: u32 = 0,
    data: u64 = 0,
};

// Allocator-backed stage-2 translation table: 3 levels, 4 KiB granule, IPA
// bits [38:30]=L1, [29:21]=L2, [20:12]=L3. Matches the table shape the EL2
// boot path configures VTCR_EL2 for.
pub const Vm = struct {
    root: u64, // physical base of the L1 table (one page)
    alloc: *const fn (usize) ?u64,
    p2v: *const fn (u64) usize, // physical -> kernel-virtual (table pages aren't identity-mapped)

    // Stage-2 leaf bits for normal guest RAM (the demo's RAM page value):
    // valid + page + AF + inner-shareable normal-WB, S2AP=RW, XN=0.
    pub const ram_leaf: u64 = 0x7ff;

    fn table(self: *const Vm, pa: u64) [*]u64 {
        return @ptrFromInt(self.p2v(pa));
    }
    fn zero(self: *const Vm, pa: u64) void {
        @memset(@as([*]u8, @ptrFromInt(self.p2v(pa)))[0..4096], 0);
    }

    // Stage-2 leaf bits for a device page (the demo's GICC mapping value):
    // valid + page + AF + Device-nGnRE, S2AP=RW.
    pub const dev_leaf: u64 = 0x4c3;

    pub fn init(alloc: *const fn (usize) ?u64, p2v: *const fn (u64) usize) ?Vm {
        // VTCR has SL0=1 + 40-bit IPA, so the stage-2 start level is two
        // concatenated 4 KiB tables and VTTBR_EL2 must be 8 KiB-aligned (the
        // walker ignores bit 12). Over-allocate 3 pages and align up to 8 KiB.
        const base = alloc(3) orelse return null;
        const root = (base + 0x1fff) & ~@as(u64, 0x1fff);
        var self: Vm = .{ .root = root, .alloc = alloc, .p2v = p2v };
        @memset(@as([*]u8, @ptrFromInt(p2v(root)))[0..0x2000], 0); // both concatenated pages
        // Route the guest's GICC to the hardware GICV so the vGIC works (the
        // guest acks/EOIs vIRQs there). GICD stays unmapped -> trap + emulate.
        _ = self.mapPage(GICC_IPA, GICV_PA, dev_leaf);
        return self;
    }

    // Resolve (creating if needed) the next-level table under table[idx].
    fn ensure(self: *Vm, tbl: u64, idx: usize) ?u64 {
        const t = self.table(tbl);
        if (t[idx] & 1 != 0) return t[idx] & ~@as(u64, 0xfff); // existing table descriptor
        const page = self.alloc(1) orelse return null;
        self.zero(page);
        t[idx] = page | 0x3; // valid + table
        return page;
    }

    // Map one 4 KiB guest-physical (IPA) page to a host-physical page. `leaf` is
    // the L3 page-descriptor bit set (ram_leaf for RAM).
    pub fn mapPage(self: *Vm, ipa: u64, pa: u64, leaf: u64) bool {
        const l2 = self.ensure(self.root, (ipa >> 30) & 0x1ff) orelse return false;
        const l3 = self.ensure(l2, (ipa >> 21) & 0x1ff) orelse return false;
        self.table(l3)[(ipa >> 12) & 0x1ff] = pa | leaf;
        return true;
    }

    pub fn vttbr(self: *const Vm) u64 {
        // VMID 1: the in-kernel demo uses VMID 0, so a distinct VMID keeps the
        // stage-2 TLBs from aliasing (each VM should really get its own VMID).
        return self.root | (@as(u64, 1) << 48);
    }
    // Arch-neutral name used by vmm.zig.
    pub fn tableBase(self: *const Vm) u64 {
        return self.vttbr();
    }
};

// A virtual CPU: guest register state + the run primitive.
pub const Vcpu = struct {
    state: VCpu = .{},

    pub fn setEntry(self: *Vcpu, pc: u64, table_base: u64) void {
        self.state.pc = pc;
        self.state.pstate = 0x3c5; // EL1h, DAIF masked
        self.state.vttbr = table_base;
    }
    // Enter the guest at EL0 with HCR_EL2.TGE set (sandbox mode): the program's
    // svc/aborts trap straight to EL2, so no in-guest EL1 vector table is needed
    // (and the guest never writes VBAR_EL1/TTBR, which wedge QEMU TCG). `sp` is
    // the EL0 stack pointer; it rides in sp_el1 and the stub loads SP_EL0 from it.
    pub fn setEl0Entry(self: *Vcpu, pc: u64, sp: u64, table_base: u64) void {
        self.state.pc = pc;
        self.state.pstate = 0x3c0; // EL0t, DAIF masked
        self.state.sp_el1 = sp;
        self.state.vttbr = table_base;
        self.state.mode = 1;
    }
    pub fn reg(self: *const Vcpu, i: usize) u64 {
        return if (i >= 31) 0 else self.state.regs[i]; // x31 == xzr
    }
    pub fn setReg(self: *Vcpu, i: usize, v: u64) void {
        if (i < 31) self.state.regs[i] = v; // writes to xzr are dropped
    }
    pub fn advancePc(self: *Vcpu, bytes: u64) void {
        self.state.pc +%= bytes;
    }

    // Minimal in-kernel vGIC distributor model: a real guest reads TYPER to size
    // the IRQ space and writes CTLR/ISENABLER/priorities during GIC init. We
    // accept the writes and return sane reads; LR-injected vIRQs bypass the
    // virtual distributor, so this only has to keep the guest's GIC probe happy.
    fn gicdEmulate(self: *Vcpu, off: u64, is_write: bool, srt: u32) void {
        if (is_write or srt >= 31) return;
        self.state.regs[srt] = switch (off) {
            0x004 => 0x0000_0001, // GICD_TYPER: ITLinesNumber=1, 1 CPU
            else => 0,
        };
    }

    pub fn run(self: *Vcpu) Exit {
        // Lend the virtual timer to the guest: the host also uses CNTV, so save
        // its state, install the guest's (preserved across exits), and restore
        // on the way out. Enable GICH so we can inject vIRQs through its LRs.
        const host_ctl = cntvCtl();
        const host_cval = cntvCval();
        setCntvCtl(0); // quiesce while swapping
        setCntvCval(self.state.cntv_cval);
        setCntvCtl(self.state.cntv_ctl);
        gich(0x00, 1); // GICH_HCR.En
        // Make sure the virtual-timer PPI is enabled + has a priority the
        // physical CPU interface will deliver (the guest's vtimer comes through
        // here before we re-inject it as a vIRQ).
        gic.setPriorityCpu(0, @intCast(VTIMER_PPI), 0xa0);
        gic.enableIrqCpu(0, @intCast(VTIMER_PPI));

        const exit = self.runLoop();

        self.state.cntv_ctl = cntvCtl(); // save the guest's timer
        self.state.cntv_cval = cntvCval();
        setCntvCtl(0);
        setCntvCval(host_cval); // restore the host's
        setCntvCtl(host_ctl);
        return exit;
    }

    // The VM-entry loop: services events the guest owns (its virtual timer and
    // GIC distributor) in-kernel and re-enters; returns to the userspace VMM
    // only for device MMIO, hypercalls, power, or a host interrupt.
    fn runLoop(self: *Vcpu) Exit {
        while (true) {
            runVcpu(&self.state);
            const ec = (self.state.esr >> 26) & 0x3f;
            switch (ec) {
                0x15 => return .{ .reason = .hypercall }, // SVC from EL0 (TGE sandbox); ELR already past it
                0x16 => return .{ .reason = .hypercall }, // HVC from the guest
                0x17 => { // SMC -> PSCI (HCR_EL2.TSC traps it); ELR already past
                    const fid = self.state.regs[0];
                    return switch (fid) {
                        0x8400_0008, 0x8400_0009, 0x8400_0002 => .{ .reason = .poweroff }, // OFF/RESET/CPU_OFF
                        else => .{ .reason = .hypercall },
                    };
                },
                0x24 => { // data abort from a lower EL = stage-2 fault (MMIO)
                    const iss = self.state.esr & 0x1ff_ffff;
                    const isv = (iss >> 24) & 1;
                    const sas: u6 = @intCast((iss >> 22) & 3); // 0=B,1=H,2=W,3=D
                    const wnr = (iss >> 6) & 1;
                    const srt: u32 = @intCast((iss >> 16) & 0x1f);
                    const fault_ipa = ((self.state.hpfar >> 4) << 12) | (self.state.far & 0xfff);
                    self.state.pc +%= 4; // retire the faulting load/store
                    // The guest's GIC distributor is emulated in-kernel (part of
                    // the virtual platform); everything else (UART, ...) goes up
                    // to the userspace VMM.
                    if (isv == 1 and (fault_ipa & ~@as(u64, 0xfff)) == GICD_IPA) {
                        self.gicdEmulate(fault_ipa & 0xfff, wnr == 1, srt);
                        continue;
                    }
                    if (isv == 0) return .{ .reason = .fault, .addr = fault_ipa, .mtval = fault_ipa, .mcause = ec };
                    return .{
                        .reason = .mmio,
                        .addr = fault_ipa,
                        .size = @as(u64, 1) << sas,
                        .is_write = (wnr == 1),
                        .reg = srt,
                        .data = if (wnr == 1) self.reg(srt) else 0,
                    };
                },
                0x3f => { // physical IRQ took the guest out (HCR_EL2.IMO routes it to EL2)
                    // Acknowledge at the physical CPU interface so we own the
                    // PPI's active state (the host's CNTV is disabled while the
                    // guest runs, so it won't EOI a stray PPI 27 for us).
                    const iar = giccRd(C_IAR);
                    const intid = iar & 0x3ff;
                    if (intid == VTIMER_PPI) {
                        const ctl = cntvCtl();
                        if (ctl & 0b100 != 0) { // ISTATUS: the guest's virtual timer fired
                            setCntvCtl(ctl | 0b010); // IMASK to deassert the level
                            gich(0x100, 0x1000_0000 | VTIMER_PPI); // inject vINTID 27 via LR0
                        }
                        giccWr(C_EOIR, iar); // drop priority + deactivate the physical PPI
                        continue; // re-enter; the guest takes the vIRQ via GICV
                    }
                    if (intid >= 1020) continue; // spurious; nothing to EOI
                    // Another physical IRQ: EOI it (we can't cleanly forward
                    // mid-guest) and bounce to the host to re-evaluate.
                    giccWr(C_EOIR, iar);
                    return .{ .reason = .interrupt };
                },
                0x01 => { // trapped WFI/WFE (TWI is off, so not expected) -> nop
                    self.state.pc +%= 4;
                    continue;
                },
                else => {
                    const ipa = ((self.state.hpfar >> 4) << 12) | (self.state.far & 0xfff);
                    return .{ .reason = .fault, .addr = ipa, .mtval = ipa, .mcause = ec };
                },
            }
        }
    }
};
