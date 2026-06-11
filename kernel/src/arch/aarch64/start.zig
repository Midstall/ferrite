const std = @import("std");
const kernel = @import("kernel");
const arch = @import("arch");

fn parseUint(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

extern var __bss_start: u8;
extern var __bss_end: u8;
extern const __stack_top: u8;
extern const __kernel_start: u8;
extern const __kernel_end: u8;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
    // ARM64 Linux Image header (Documentation/arm64/booting.rst).
    // Magic 'ARM\x64' at offset 0x38 tells QEMU virt to set x0 = DTB pointer.
        \\ b 4f
        \\ .long 0
        \\ .quad 0
        \\ .quad 0
        \\ .quad 0
        \\ .quad 0
        \\ .quad 0
        \\ .quad 0
        \\ .long 0x644D5241
        \\ .long 0
        \\4:
        \\ // x0 = DTB pointer on entry; preserve in x19.
        \\ mov x19, x0
        \\ mrs x20, mpidr_el1
        \\ and x20, x20, #0xff
        \\ cbz x20, 1f
        \\0: wfe
        \\   b 0b
        \\1:
        \\ // Primary CPU. In hyp mode (qemu virtualization=on) firmware enters us
        \\ // at EL2; drop to EL1 so the host kernel runs where it expects. A normal
        \\ // raw boot enters at EL1 and skips this. (The resident EL2 hypervisor
        \\ // stub is installed later, in S2; single-core boot does no hvc.)
        \\1: mrs  x0, CurrentEL
        \\   lsr  x0, x0, #2
        \\   and  x0, x0, #3
        \\   cmp  x0, #2
        \\   b.ne 3f
        \\   movz x0, #0x8000, lsl #16   // HCR_EL2.RW = 1: EL1 is AArch64
        \\   msr  hcr_el2, x0
        \\   movz x0, #0x0800            // SCTLR_EL1 reset value (RES1, MMU off)
        \\   movk x0, #0x30d0, lsl #16
        \\   msr  sctlr_el1, x0
        \\   mrs  x0, cnthctl_el2        // let EL1 reach the phys timer/counter
        \\   orr  x0, x0, #3
        \\   msr  cnthctl_el2, x0
        \\   msr  cntvoff_el2, xzr
        \\   mrs  x0, mpidr_el1          // mirror identity regs to EL1 reads
        \\   msr  vmpidr_el2, x0
        \\   mrs  x0, midr_el1
        \\   msr  vpidr_el2, x0
        \\   // Install the resident EL2 hyp stub: EL2 stack + vectors, mark hyp on.
        \\   adrp x0, hyp_stack
        \\   add  x0, x0, :lo12:hyp_stack
        \\   add  x0, x0, #16384         // top of the 16 KiB EL2 stack
        \\   mov  sp, x0                 // SP_EL2
        \\   adrp x0, hypVectors
        \\   add  x0, x0, :lo12:hypVectors
        \\   msr  vbar_el2, x0
        \\   adrp x0, hyp_active
        \\   add  x0, x0, :lo12:hyp_active
        \\   mov  w1, #1
        \\   str  w1, [x0]               // hyp_active lives in .data (survives bss-zero)
        \\   adrp x0, hyp_cpu            // TPIDR_EL2 = &hyp_cpu (EL2 per-cpu scratch)
        \\   add  x0, x0, :lo12:hyp_cpu
        \\   msr  tpidr_el2, x0
        \\   movz x0, #0x3558            // VTCR_EL2: 4K, 40-bit IPA, SL0=1, WB/IS
        \\   movk x0, #0x8002, lsl #16   //   = 0x80023558
        \\   msr  S3_4_C2_C1_2, x0       // VTCR_EL2 (assembler lacks the name)
        \\   isb
        \\   movz x0, #0x3c5             // SPSR_EL2 = EL1h, DAIF masked
        \\   msr  spsr_el2, x0
        \\   adr  x0, 3f
        \\   msr  elr_el2, x0
        \\   eret
        \\ // CPACR_EL1.FPEN = 0b11 enables FP/SIMD at EL1 for std.fmt q-loads.
        \\3: mov  x2, #(3 << 20)
        \\   msr  cpacr_el1, x2
        \\   isb
        \\   adrp x1, __stack_top
        \\   add  x1, x1, :lo12:__stack_top
        \\   mov  sp, x1
        \\   mov  x0, x19
        \\   bl zigStart
        \\2: wfe
        \\   b 2b
    );
}

// EL2 hyp stub (split-mode hypervisor). Installed during the EL2 boot phase
// above; the host then runs at EL1 and calls in via HVC. See ferrite-microvm.
export var hyp_stack: [16384]u8 align(16) = undefined;
// Defined in hyp.zig (so non-raw boots without start.zig still link it). The
// EL2 entry asm below references it by symbol; this extern wires up the Zig
// reads. In .data so the EL2 write survives zigStart's bss-zero.
extern var hyp_active: u32;

// EL2 per-CPU scratch (TPIDR_EL2 points here). Layout used by the world-switch
// asm: 0x00 x19..x30 (6 pairs), 0x60 host sp_el1, 0x68 host ELR_EL2 (hvc
// return), 0x70 host SPSR_EL2, 0x78 host SCTLR_EL1, 0x80 in_guest, 0x88 vcpu ptr.
export var hyp_cpu: [256]u8 align(16) = undefined;

// VBAR_EL2 vector table: 16 entries x 0x80 bytes, 0x800-aligned. S2a only
// handles "lower EL AArch64 sync" (HVC from EL1); the rest spin.
export fn hypVectors() align(2048) callconv(.naked) noreturn {
    asm volatile (
        \\ .balign 0x80
        \\ b 9f
        \\ .balign 0x80
        \\ b 9f
        \\ .balign 0x80
        \\ b 9f
        \\ .balign 0x80
        \\ b 9f
        \\ .balign 0x80
        \\ b 9f
        \\ .balign 0x80
        \\ b 9f
        \\ .balign 0x80
        \\ b 9f
        \\ .balign 0x80
        \\ b 9f
        \\ .balign 0x80
        \\ b hypSyncLowerEl   // 0x400: lower EL AArch64 synchronous (HVC)
        \\ .balign 0x80
        \\ b hypIrqLowerEl    // 0x480: lower EL AArch64 IRQ
        \\ .balign 0x80
        \\ b 9f
        \\ .balign 0x80
        \\ b 9f
        \\ .balign 0x80
        \\ b 9f
        \\ .balign 0x80
        \\ b 9f
        \\ .balign 0x80
        \\ b 9f
        \\ .balign 0x80
        \\ b 9f
        \\9: b 9b
    );
}

// EL2 sync-from-lower-EL handler = the world-switch dispatcher. Distinguishes a
// host hyp-call (in_guest==0) from a guest exit (in_guest==1) via hyp_cpu. Host
// calls: id 1 = RUN_VCPU (x1 = *VCpu), anything else returns 0xABCD (the S2a
// round-trip probe). VCpu layout: 0x000 x0..x30, 0x0F8 sp_el1, 0x100 pc(ELR),
// 0x108 pstate(SPSR), 0x110 esr, 0x118 vttbr, 0x120 hpfar, 0x128 far. On guest
// exit the full GP set + ESR/HPFAR/FAR are saved so the host can emulate MMIO.
export fn hypSyncLowerEl() callconv(.naked) noreturn {
    asm volatile (
        \\ stp  x0, x1, [sp, #-16]!     // stash scratch (and guest x0/x1 on exit)
        \\ mrs  x0, tpidr_el2           // x0 = &hyp_cpu
        \\ ldr  x1, [x0, #0x80]         // in_guest?
        \\ cbnz x1, 1f                  // -> guest exit
        \\ // host hyp-call (in_guest == 0)
        \\ ldp  x0, x1, [sp], #16       // x0 = id, x1 = arg
        \\ cmp  x0, #1
        \\ b.eq 3f                      // RUN_VCPU
        \\ movz x0, #0xABCD             // probe/other: just return a magic
        \\ eret
        \\3: // RUN_VCPU: x1 = *VCpu. Save host context into hyp_cpu, enter guest.
        \\ mrs  x2, tpidr_el2
        \\ stp  x19, x20, [x2, #0x00]
        \\ stp  x21, x22, [x2, #0x10]
        \\ stp  x23, x24, [x2, #0x20]
        \\ stp  x25, x26, [x2, #0x30]
        \\ stp  x27, x28, [x2, #0x40]
        \\ stp  x29, x30, [x2, #0x50]
        \\ mrs  x3, sp_el1
        \\ str  x3, [x2, #0x60]
        \\ mrs  x3, elr_el2             // host return (instr after the hvc)
        \\ str  x3, [x2, #0x68]
        \\ mrs  x3, spsr_el2            // host pstate
        \\ str  x3, [x2, #0x70]
        \\ mrs  x3, sctlr_el1           // host stage-1 state
        \\ str  x3, [x2, #0x78]
        \\ str  x1, [x2, #0x88]         // vcpu ptr
        \\ mov  x3, #1
        \\ str  x3, [x2, #0x80]         // in_guest = 1
        \\ ldr  x3, [x1, #0x118]        // stage-2 base | VMID
        \\ msr  S3_4_C2_C1_0, x3        // VTTBR_EL2 (assembler lacks the name)
        \\ ldr  x4, [x1, #0x140]        // entry mode (0 = EL1 guest, 1 = EL0+TGE sandbox)
        \\ mrs  x3, hcr_el2
        \\ orr  x3, x3, #1              // HCR_EL2.VM = 1 (enable stage-2)
        \\ orr  x3, x3, #0x80000        // HCR_EL2.TSC = 1 (trap guest SMC -> PSCI)
        \\ orr  x3, x3, #0x10           // HCR_EL2.IMO = 1 (route IRQ to EL2 + enable vIRQ)
        \\ cbz  x4, 4f                  // EL1 guest: leave TGE clear
        \\ orr  x3, x3, #0x8000000      // HCR_EL2.TGE = 1: route EL0 svc/aborts to EL2
        \\4:
        \\ msr  hcr_el2, x3             // NB: TWI left clear so the guest's WFI really waits
        \\ msr  sctlr_el1, xzr          // guest stage-1 off -> flat IPA
        \\ ldr  x3, [x1, #0x100]        // guest PC
        \\ msr  elr_el2, x3
        \\ ldr  x3, [x1, #0x108]        // guest PSTATE
        \\ msr  spsr_el2, x3
        \\ ldr  x3, [x1, #0x0F8]        // guest SP (SP_EL1; also SP_EL0 in sandbox mode)
        \\ msr  sp_el1, x3
        \\ cbz  x4, 5f                  // EL1 guest: no SP_EL0 to set
        \\ msr  sp_el0, x3              // sandbox: the EL0 program's stack
        \\5:
        \\ // Load full guest GP set (x1 = vcpu base; load x0/x1 last).
        \\ ldp  x2, x3, [x1, #0x10]
        \\ ldp  x4, x5, [x1, #0x20]
        \\ ldp  x6, x7, [x1, #0x30]
        \\ ldp  x8, x9, [x1, #0x40]
        \\ ldp  x10, x11, [x1, #0x50]
        \\ ldp  x12, x13, [x1, #0x60]
        \\ ldp  x14, x15, [x1, #0x70]
        \\ ldp  x16, x17, [x1, #0x80]
        \\ ldp  x18, x19, [x1, #0x90]
        \\ ldp  x20, x21, [x1, #0xA0]
        \\ ldp  x22, x23, [x1, #0xB0]
        \\ ldp  x24, x25, [x1, #0xC0]
        \\ ldp  x26, x27, [x1, #0xD0]
        \\ ldp  x28, x29, [x1, #0xE0]
        \\ ldr  x30, [x1, #0xF0]
        \\ ldr  x0, [x1, #0x00]
        \\ ldr  x1, [x1, #0x08]
        \\ isb
        \\ eret                         // -> guest at EL1
        \\1: // guest exit (in_guest == 1): x0 = &hyp_cpu; guest x0/x1 on stack.
        \\ ldr  x1, [x0, #0x88]         // x1 = vcpu ptr
        \\ stp  x2, x3, [x1, #0x10]     // save guest x2..x30
        \\ stp  x4, x5, [x1, #0x20]
        \\ stp  x6, x7, [x1, #0x30]
        \\ stp  x8, x9, [x1, #0x40]
        \\ stp  x10, x11, [x1, #0x50]
        \\ stp  x12, x13, [x1, #0x60]
        \\ stp  x14, x15, [x1, #0x70]
        \\ stp  x16, x17, [x1, #0x80]
        \\ stp  x18, x19, [x1, #0x90]
        \\ stp  x20, x21, [x1, #0xA0]
        \\ stp  x22, x23, [x1, #0xB0]
        \\ stp  x24, x25, [x1, #0xC0]
        \\ stp  x26, x27, [x1, #0xD0]
        \\ stp  x28, x29, [x1, #0xE0]
        \\ str  x30, [x1, #0xF0]
        \\ ldp  x2, x3, [sp], #16       // guest x0, x1 (stashed at vector entry)
        \\ stp  x2, x3, [x1, #0x00]
        \\ mrs  x2, elr_el2
        \\ str  x2, [x1, #0x100]        // guest PC at exit
        \\ mrs  x2, spsr_el2
        \\ str  x2, [x1, #0x108]
        \\ mrs  x2, esr_el2
        \\ str  x2, [x1, #0x110]        // exit syndrome
        \\ mrs  x2, far_el2
        \\ str  x2, [x1, #0x128]        // faulting VA (page offset)
        \\ mrs  x2, S3_4_C6_C0_4        // HPFAR_EL2 (faulting IPA[47:12])
        \\ str  x2, [x1, #0x120]
        \\ // shared host-restore tail; the IRQ handler branches here too.
        \\ .global hypExitCommon
        \\hypExitCommon:
        \\ ldr  x3, [x1, #0x140]        // entry mode (0 = EL1, 1 = EL0+TGE sandbox)
        \\ cbz  x3, 6f
        \\ mrs  x2, sp_el0             // sandbox: the guest's SP is SP_EL0
        \\ b    7f
        \\6:
        \\ mrs  x2, sp_el1
        \\7:
        \\ str  x2, [x1, #0x0F8]
        \\ str  xzr, [x0, #0x80]        // in_guest = 0
        \\ mrs  x2, hcr_el2
        \\ bic  x2, x2, #1              // HCR_EL2.VM = 0 (host runs untranslated)
        \\ bic  x2, x2, #0x2000         // clear TWI: host WFIs must not trap
        \\ bic  x2, x2, #0x80000        // clear TSC
        \\ bic  x2, x2, #0x10           // clear IMO: host IRQs route to EL1 again
        \\ bic  x2, x2, #0x8000000      // clear TGE (harmless if it was not set)
        \\ msr  hcr_el2, x2
        \\ ldr  x2, [x0, #0x78]         // restore host stage-1
        \\ msr  sctlr_el1, x2
        \\ ldr  x2, [x0, #0x60]
        \\ msr  sp_el1, x2
        \\ ldr  x2, [x0, #0x68]
        \\ msr  elr_el2, x2             // host hvc return
        \\ ldr  x2, [x0, #0x70]
        \\ msr  spsr_el2, x2
        \\ ldp  x19, x20, [x0, #0x00]
        \\ ldp  x21, x22, [x0, #0x10]
        \\ ldp  x23, x24, [x0, #0x20]
        \\ ldp  x25, x26, [x0, #0x30]
        \\ ldp  x27, x28, [x0, #0x40]
        \\ ldp  x29, x30, [x0, #0x50]
        \\ isb
        \\ eret                         // -> host runVcpu
    );
}

// EL2 IRQ-from-lower-EL handler. With HCR.IMO set, a physical IRQ that arrives
// while the guest runs traps here. We don't service it at EL2; we exit to the
// host with a sentinel ESR (EC=0x3F) so it re-enters the guest, and the host
// services the now-EL1-routed IRQ in the gap (IMO is cleared on the way out).
export fn hypIrqLowerEl() callconv(.naked) noreturn {
    asm volatile (
        \\ stp  x0, x1, [sp, #-16]!     // stash guest x0/x1
        \\ mrs  x0, tpidr_el2           // x0 = &hyp_cpu
        \\ ldr  x1, [x0, #0x88]         // x1 = vcpu ptr
        \\ stp  x2, x3, [x1, #0x10]     // save guest x2..x30
        \\ stp  x4, x5, [x1, #0x20]
        \\ stp  x6, x7, [x1, #0x30]
        \\ stp  x8, x9, [x1, #0x40]
        \\ stp  x10, x11, [x1, #0x50]
        \\ stp  x12, x13, [x1, #0x60]
        \\ stp  x14, x15, [x1, #0x70]
        \\ stp  x16, x17, [x1, #0x80]
        \\ stp  x18, x19, [x1, #0x90]
        \\ stp  x20, x21, [x1, #0xA0]
        \\ stp  x22, x23, [x1, #0xB0]
        \\ stp  x24, x25, [x1, #0xC0]
        \\ stp  x26, x27, [x1, #0xD0]
        \\ stp  x28, x29, [x1, #0xE0]
        \\ str  x30, [x1, #0xF0]
        \\ ldp  x2, x3, [sp], #16       // guest x0, x1
        \\ stp  x2, x3, [x1, #0x00]
        \\ mrs  x2, elr_el2
        \\ str  x2, [x1, #0x100]
        \\ mrs  x2, spsr_el2
        \\ str  x2, [x1, #0x108]
        \\ movz x2, #0xFC00, lsl #16    // sentinel ESR: EC=0x3F (physical IRQ)
        \\ str  x2, [x1, #0x110]
        \\ b    hypExitCommon           // shared restore tail (clears IMO etc.)
    );
}

// In hyp mode, prove the EL1 -> EL2 -> EL1 path once at boot.
pub fn hypProbe() void {
    if (hyp_active == 0) return;
    const r = asm volatile ("hvc #0"
        : [r] "={x0}" (-> u64),
        : [in] "{x0}" (@as(u64, 0)),
        : .{ .x0 = true, .memory = true });
    arch.uart.print("[hyp] EL2 stub live; hvc round-trip = 0x{x}\n", .{r});
}

// vCPU state shared with the world-switch asm. Field offsets are load-bearing.
const VCpu = extern struct {
    regs: [31]u64 = @splat(0), // x0..x30  (0x000)
    sp_el1: u64 = 0, //              0x0F8
    pc: u64 = 0, //   guest PC ->    0x100 (ELR_EL2)
    pstate: u64 = 0, // guest PSTATE 0x108 (SPSR_EL2)
    esr: u64 = 0, //  exit syndrome  0x110
    vttbr: u64 = 0, // stage-2 base  0x118 (| VMID)
    hpfar: u64 = 0, // faulting IPA  0x120 (HPFAR_EL2: IPA[47:12] in bits[39:4])
    far: u64 = 0, //  faulting VA    0x128 (FAR_EL2: page offset)
    // Pad to match hyp.zig's VCpu so the stub can read `mode` at 0x140 without
    // running off the end of this (EL1-only) demo struct. The demo never sets a
    // non-zero mode, so the stub takes the unchanged EL1 path.
    cntv_ctl: u64 = 0, //  0x130
    cntv_cval: u64 = 0, // 0x138
    mode: u64 = 0, //      0x140 (0 = EL1)
};

fn runVcpu(vcpu: *VCpu) void {
    asm volatile ("hvc #0"
        :
        : [id] "{x0}" (@as(u64, 1)),
          [v] "{x1}" (@intFromPtr(vcpu)),
        : .{ .x0 = true, .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .x18 = true, .memory = true });
}

// S4 guest payload: a tiny kernel that follows the aarch64 Linux boot protocol.
// Entered (via the Image header's code0 branch) with x0 = DTB IPA, MMU off. It
// verifies the FDT magic the host handed it, then prints via the PL011 the host
// emulates (poll UARTFR, write UARTDR). Position-independent (immediates +
// PC-relative adr), so it copies into guest RAM and runs at any IPA.
export fn guestKernel() callconv(.naked) noreturn {
    asm volatile (
        \\ mov  x4, x0                  // x4 = DTB IPA (boot protocol: x0 holds it)
        \\ movz x1, #0x0900, lsl #16    // x1 = PL011 base (a real kernel reads this from the DTB)
        \\ ldr  w5, [x4]                // DTB magic, little-endian view of BE 0xd00dfeed
        \\ movz w6, #0x0dd0
        \\ movk w6, #0xedfe, lsl #16    // w6 = 0xedfe0dd0
        \\ cmp  w5, w6
        \\ b.ne 1f
        \\ adr  x2, 2f                  // magic verified
        \\ b    3f
        \\1: adr  x2, 4f                // magic mismatch
        \\3: ldrb w0, [x2], #1          // print loop
        \\ cbz  w0, 5f
        \\6: ldr  w3, [x1, #0x18]       // poll UARTFR (read trap)
        \\ tbnz w3, #5, 6b              // TXFF set? wait
        \\ strb w0, [x1]                // write UARTDR (write trap)
        \\ b    3b
        \\5: // set up to receive a virtual timer IRQ through the vGIC
        \\ movz x9, #0x4000, lsl #16
        \\ movk x9, #0x4000             // x9 = 0x40004000 (vector table IPA, 0x800-aligned)
        \\ msr  vbar_el1, x9
        \\ movz x15, #0x0800, lsl #16   // x15 = 0x08000000 (GICD; unmapped -> host emulates)
        \\ ldr  w16, [x15, #0x04]       // read GICD_TYPER (sizes the IRQ space)
        \\ mov  w16, #1
        \\ str  w16, [x15, #0x00]       // GICD_CTLR = 1 (enable the distributor)
        \\ movz w16, #0x0800, lsl #16   // bit 27 = PPI 27 (the virtual timer)
        \\ str  w16, [x15, #0x100]      // GICD_ISENABLER0 |= 1<<27
        \\ movz x10, #0x0801, lsl #16   // x10 = 0x08010000 (guest GICC -> GICV via stage-2)
        \\ mov  w11, #0xff
        \\ str  w11, [x10, #0x04]       // GICC_PMR = 0xff (allow all priorities)
        \\ mov  w11, #1
        \\ str  w11, [x10, #0x00]       // GICC_CTLR = 1 (enable the CPU interface)
        \\ isb
        \\ movz x13, #0x4, lsl #16      // 0x40000 virtual-timer cycles (~4 ms at 62.5 MHz)
        \\ msr  cntv_tval_el0, x13      // arm the virtual timer deadline
        \\ mov  x13, #1
        \\ msr  cntv_ctl_el0, x13       // CNTV_CTL.ENABLE = 1 (IMASK = 0)
        \\ isb
        \\ msr  daifclr, #2             // unmask IRQs
        \\8: wfi                        // really wait; CNTV fires -> PPI27 -> EL2 -> host injects vIRQ
        \\ b    8b                      // safety net; the IRQ handler powers the VM off
        \\2: .asciz "guest kernel booted via Image header; DTB magic verified\n"
        \\4: .asciz "guest kernel booted; DTB MAGIC MISMATCH\n"
    );
}

// Guest EL1 vector table + IRQ handler, copied to a 0x800-aligned guest IPA.
// The guest runs at EL1h (SPx), so the IRQ it takes vectors at offset 0x280.
// The handler acknowledges via the GIC CPU interface (GICC_IAR/EOIR, which
// stage-2 routes to the hardware GICV), prints, then powers off via PSCI.
export fn guestVectors() align(2048) callconv(.naked) noreturn {
    asm volatile (
        \\ .space 0x280                 // entries 0x000..0x200 unused by this guest
        \\ b 1f                         // 0x280: Current EL (SPx) IRQ
        \\ .balign 0x800                // pad out the rest of the 16-entry table
        \\1: // IRQ handler
        \\ movz x10, #0x0801, lsl #16   // guest GICC base (-> GICV)
        \\ ldr  w12, [x10, #0x0C]       // GICC_IAR: acknowledge, returns the vINTID
        \\ movz x1, #0x0900, lsl #16    // UART
        \\ adr  x2, 2f
        \\3: ldrb w3, [x2], #1
        \\ cbz  w3, 4f
        \\5: ldr  w6, [x1, #0x18]
        \\ tbnz w6, #5, 5b
        \\ strb w3, [x1]
        \\ b    3b
        \\4: str  w12, [x10, #0x10]     // GICC_EOIR: complete the interrupt
        \\ movz x0, #0x0008
        \\ movk x0, #0x8400, lsl #16    // PSCI SYSTEM_OFF
        \\ .inst 0xd4000003             // smc -> host ends the VM
        \\7: b 7b
        \\2: .asciz "guest: virtual timer fired -> took IRQ via vGIC, acked + EOI sent\n"
    );
}

// Minimal PL011 device model for the guest's console. Only what a boot console
// driver touches: TX through the data register, and a flag register that always
// reports "ready to transmit, nothing to receive". off = register offset within
// the UART page, is_write = store vs load, srt = transfer register number.
fn pl011Emulate(vcpu: *VCpu, off: u64, is_write: bool, srt: u32) void {
    if (is_write) {
        switch (off) {
            0x00 => arch.uart.print("{c}", .{@as(u8, @truncate(vcpu.regs[srt & 0x1f]))}), // UARTDR: TX
            else => {}, // UARTCR/LCR_H/IMSC/baud etc: accept and ignore
        }
        return;
    }
    // Reads. srt == 31 is a load to xzr (discard); regs only holds x0..x30.
    if (srt >= 31) return;
    vcpu.regs[srt] = switch (off) {
        0x18 => 0x90, // UARTFR: TXFE(1<<7)|RXFE(1<<4) -> TXFF clear, never busy
        else => 0, // other regs read as zero
    };
}

// Minimal GICv2 distributor (GICD) model for the guest. A real kernel reads
// TYPER to size the IRQ space and writes CTLR/ISENABLER/IPRIORITYR/ICFGR during
// GIC init; we accept the writes and return sane reads. LR-injected vIRQs bypass
// the virtual distributor, so this only has to keep the guest's GIC probe happy.
fn gicdEmulate(vcpu: *VCpu, off: u64, is_write: bool, srt: u32) void {
    if (is_write) return; // accept + ignore distributor configuration writes
    if (srt >= 31) return;
    vcpu.regs[srt] = switch (off) {
        0x004 => 0x0000_0001, // GICD_TYPER: ITLinesNumber=1 (64 INTIDs), 1 CPU
        else => 0, // GICD_CTLR / IIDR / ISENABLER readback / etc.
    };
}

// What the host should do after a guest SMC/PSCI call.
const PsciAction = enum { cont, poweroff, reset };

// Minimal PSCI emulation for the guest's SMC calls (x0 = function id). Boot
// kernels use this to query the version and to power off / reset the machine;
// secondary-CPU bring-up (CPU_ON) lands here too once we run SMP guests.
fn psciHandle(vcpu: *VCpu) PsciAction {
    const fid = vcpu.regs[0];
    switch (fid) {
        0x8400_0008 => return .poweroff, // SYSTEM_OFF
        0x8400_0009 => return .reset, // SYSTEM_RESET
        0x8400_0000 => vcpu.regs[0] = 0x1_0000, // PSCI_VERSION -> 1.0
        0x8400_000A => vcpu.regs[0] = 0, // PSCI_FEATURES -> "supported"
        else => vcpu.regs[0] = @bitCast(@as(i64, -1)), // NOT_SUPPORTED
    }
    return .cont;
}

// Minimal flattened device tree (FDT v17) for the guest: a root with a memory
// node, a chosen node (stdout-path), and the pl011 the host emulates. Built
// big-endian per spec. Returns the total size written into buf.
fn buildGuestDtb(buf: [*]u8, ram_base: u64, ram_size: u64) usize {
    // Strings block: property names, NUL-terminated, at fixed offsets.
    const STR = "#address-cells\x00#size-cells\x00compatible\x00device_type\x00reg\x00stdout-path\x00bootargs\x00";
    const OFF_ADDR_CELLS: u32 = 0;
    const OFF_SIZE_CELLS: u32 = 15;
    const OFF_COMPATIBLE: u32 = 27;
    const OFF_DEVICE_TYPE: u32 = 38;
    const OFF_REG: u32 = 50;
    const OFF_STDOUT: u32 = 54;
    const OFF_BOOTARGS: u32 = 66;

    const B = struct {
        buf: [*]u8,
        pos: usize,
        fn put32(self: *@This(), v: u32) void {
            self.buf[self.pos] = @truncate(v >> 24);
            self.buf[self.pos + 1] = @truncate(v >> 16);
            self.buf[self.pos + 2] = @truncate(v >> 8);
            self.buf[self.pos + 3] = @truncate(v);
            self.pos += 4;
        }
        fn pad(self: *@This()) void {
            while (self.pos % 4 != 0) : (self.pos += 1) self.buf[self.pos] = 0;
        }
        fn beginNode(self: *@This(), name: []const u8) void {
            self.put32(1); // FDT_BEGIN_NODE
            for (name) |c| {
                self.buf[self.pos] = c;
                self.pos += 1;
            }
            self.buf[self.pos] = 0;
            self.pos += 1;
            self.pad();
        }
        fn endNode(self: *@This()) void {
            self.put32(2); // FDT_END_NODE
        }
        fn prop(self: *@This(), nameoff: u32, val: []const u8) void {
            self.put32(3); // FDT_PROP
            self.put32(@intCast(val.len));
            self.put32(nameoff);
            for (val) |c| {
                self.buf[self.pos] = c;
                self.pos += 1;
            }
            self.pad();
        }
        fn propU32(self: *@This(), nameoff: u32, v: u32) void {
            var tmp: [4]u8 = .{ @truncate(v >> 24), @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
            self.prop(nameoff, tmp[0..]);
        }
        // reg = <addr_hi addr_lo size_hi size_lo> (#address-cells=2, #size-cells=2)
        fn propReg(self: *@This(), nameoff: u32, addr: u64, size: u64) void {
            var tmp: [16]u8 = undefined;
            const cells = [4]u32{ @truncate(addr >> 32), @truncate(addr), @truncate(size >> 32), @truncate(size) };
            for (cells, 0..) |c, i| {
                tmp[i * 4] = @truncate(c >> 24);
                tmp[i * 4 + 1] = @truncate(c >> 16);
                tmp[i * 4 + 2] = @truncate(c >> 8);
                tmp[i * 4 + 3] = @truncate(c);
            }
            self.prop(nameoff, tmp[0..]);
        }
    };

    const off_struct: usize = 0x38; // header (0x28) + one empty rsvmap entry (0x10)
    var b = B{ .buf = buf, .pos = off_struct };

    b.beginNode(""); // root
    b.propU32(OFF_ADDR_CELLS, 2);
    b.propU32(OFF_SIZE_CELLS, 2);
    b.prop(OFF_COMPATIBLE, "linux,dummy-virt\x00");

    b.beginNode("memory@40000000");
    b.prop(OFF_DEVICE_TYPE, "memory\x00");
    b.propReg(OFF_REG, ram_base, ram_size);
    b.endNode();

    b.beginNode("chosen");
    b.prop(OFF_STDOUT, "/pl011@9000000\x00");
    b.prop(OFF_BOOTARGS, "\x00");
    b.endNode();

    b.beginNode("pl011@9000000");
    b.prop(OFF_COMPATIBLE, "arm,pl011\x00arm,primecell\x00");
    b.propReg(OFF_REG, 0x0900_0000, 0x1000);
    b.endNode();

    b.endNode(); // close root
    b.put32(9); // FDT_END
    const struct_size = b.pos - off_struct;

    const off_strings = b.pos;
    for (STR) |c| {
        buf[b.pos] = c;
        b.pos += 1;
    }
    const total = b.pos;

    // Header (big-endian u32 fields).
    var h = B{ .buf = buf, .pos = 0 };
    h.put32(0xd00dfeed); // magic
    h.put32(@intCast(total)); // totalsize
    h.put32(@intCast(off_struct)); // off_dt_struct
    h.put32(@intCast(off_strings)); // off_dt_strings
    h.put32(0x28); // off_mem_rsvmap
    h.put32(17); // version
    h.put32(16); // last_comp_version
    h.put32(0); // boot_cpuid_phys
    h.put32(@intCast(STR.len)); // size_dt_strings
    h.put32(@intCast(struct_size)); // size_dt_struct
    // 0x28..0x38: one terminating reserve-map entry (address=0, size=0) -> page
    // is pre-zeroed, nothing to write.
    return total;
}

// Run a configured vCPU to completion, emulating the devices it touches. Lends
// the host's CNTV to the guest (the host scheduler also uses CNTV/PPI27) and
// restores it on every exit path. Shared by the synthetic guest and a real
// loaded Image. The vcpu's pc/regs[0]/vttbr/pstate must already be set.
fn hypVcpuLoop(vcpu: *VCpu) void {
    const uart_base: u64 = 0x0900_0000;
    const GICH_BASE: u64 = 0x0803_0000;

    // The GIC isn't brought up until kmain (after this runs), so the guest's CNTV
    // interrupt (PPI 27) can't reach EL2 yet. Bring it up + enable PPI 27 here.
    arch.gic.init();
    arch.gic.setPriorityCpu(0, 27, 0xa0);
    arch.gic.enableIrqCpu(0, 27);

    const prior_daif = asm volatile ("mrs %[r], daif"
        : [r] "=r" (-> u64),
    );
    asm volatile ("msr daifset, #2"); // mask host IRQs while we borrow the timer
    const host_cntv_ctl = asm volatile ("mrs %[r], cntv_ctl_el0"
        : [r] "=r" (-> u64),
    );
    const host_cntv_cval = asm volatile ("mrs %[r], cntv_cval_el0"
        : [r] "=r" (-> u64),
    );
    asm volatile ("msr cntv_ctl_el0, xzr"); // disable host timer; the guest owns CNTV now
    defer {
        arch.gic.disableIrq(27); // undo our early bring-up so kmain re-inits clean
        asm volatile ("msr cntv_cval_el0, %[v]"
            :
            : [v] "r" (host_cntv_cval),
        );
        asm volatile ("msr cntv_ctl_el0, %[v]"
            :
            : [v] "r" (host_cntv_ctl),
        );
        asm volatile ("msr daif, %[v]"
            :
            : [v] "r" (prior_daif),
        );
    }

    var mmio_exits: u32 = 0;
    var timer_ticks: u32 = 0;
    var guard: u32 = 0;
    while (guard < 2_000_000) : (guard += 1) {
        runVcpu(vcpu);
        const ec = (vcpu.esr >> 26) & 0x3f;
        switch (ec) {
            0x16 => break, // HVC: guest finished (legacy exit)
            0x3f => { // physical IRQ at EL2: the guest's virtual timer (CNTV/PPI27) fired
                timer_ticks += 1;
                asm volatile ("msr cntv_ctl_el0, xzr"); // deassert the level-sensitive PPI
                @as(*volatile u32, @ptrFromInt(GICH_BASE + 0x00)).* = 1; // GICH_HCR.En
                @as(*volatile u32, @ptrFromInt(GICH_BASE + 0x100)).* = 0x1000_0000 | 27; // LR0 pending, vID 27
            },
            0x01 => vcpu.pc += 4, // stray WFI trap (TWI is off; not expected)
            0x17 => { // SMC -> PSCI. ELR already points past the SMC; no pc bump.
                switch (psciHandle(vcpu)) {
                    .cont => {},
                    .poweroff => {
                        arch.uart.print("\n[hyp] guest powered off via PSCI SYSTEM_OFF ({d} MMIO, {d} timer ticks)\n", .{ mmio_exits, timer_ticks });
                        return;
                    },
                    .reset => {
                        arch.uart.print("\n[hyp] guest requested PSCI SYSTEM_RESET\n", .{});
                        return;
                    },
                }
            },
            0x24 => { // data abort from a lower EL (stage-2 fault)
                const iss = vcpu.esr & 0x1ff_ffff;
                const isv = (iss >> 24) & 1;
                const wnr = (iss >> 6) & 1;
                const srt: u32 = @intCast((iss >> 16) & 0x1f);
                const fault_ipa = ((vcpu.hpfar >> 4) << 12) | (vcpu.far & 0xfff);
                const page = fault_ipa & ~@as(u64, 0xfff);
                if (isv == 1 and page == uart_base) {
                    pl011Emulate(vcpu, fault_ipa & 0xfff, wnr == 1, srt);
                } else if (isv == 1 and page == 0x0800_0000) {
                    gicdEmulate(vcpu, fault_ipa & 0xfff, wnr == 1, srt);
                } else {
                    arch.uart.print("\n[hyp] guest stage-2 fault ipa=0x{x} esr=0x{x} (not emulated; {d} MMIO {d} ticks)\n", .{ fault_ipa, vcpu.esr, mmio_exits, timer_ticks });
                    return;
                }
                vcpu.pc += 4;
                mmio_exits += 1;
            },
            else => {
                arch.uart.print("\n[hyp] guest unexpected exit esr=0x{x} ec=0x{x} far=0x{x} elr=0x{x}\n", .{ vcpu.esr, ec, vcpu.far, vcpu.pc });
                return;
            },
        }
    }
    arch.uart.print("\n[hyp] guest run loop hit the guard cap ({d} MMIO, {d} ticks)\n", .{ mmio_exits, timer_ticks });
}

// S4: build a multi-page guest VM, load a real aarch64 Image + a generated DTB,
// and boot it. Proves Image-header parse + DTB hand-off on top of the world-
// switch + stage-2 isolation + MMIO trap-and-emulate loop.
fn hypRunGuestDemo() void {
    if (hyp_active == 0) return;
    const ps = kernel.memory.pageSize();
    const ram_pages = 16; // 64 KiB guest RAM
    const l1 = kernel.memory.allocPage() orelse return;
    const l2 = kernel.memory.allocPage() orelse return;
    const l3 = kernel.memory.allocPage() orelse return;
    const l2_gic = kernel.memory.allocPage() orelse return; // stage-2 tables for the GIC IPA
    const l3_gic = kernel.memory.allocPage() orelse return;
    const ram = kernel.memory.allocPages(ram_pages) orelse return;
    @memset(@as([*]u8, @ptrFromInt(l1))[0..ps], 0);
    @memset(@as([*]u8, @ptrFromInt(l2))[0..ps], 0);
    @memset(@as([*]u8, @ptrFromInt(l3))[0..ps], 0);
    @memset(@as([*]u8, @ptrFromInt(l2_gic))[0..ps], 0);
    @memset(@as([*]u8, @ptrFromInt(l3_gic))[0..ps], 0);
    @memset(@as([*]u8, @ptrFromInt(ram))[0 .. ram_pages * ps], 0);

    const ram_base: u64 = 0x4000_0000; // guest RAM IPA (2 MiB-aligned)
    const l1t: [*]u64 = @ptrFromInt(l1);

    // GIC CPU interface (both paths): IPA 0x08010000 (guest GICC) -> PA 0x08040000
    // (the hardware GICV), Device memory.
    const gicc_ipa: u64 = 0x0801_0000;
    l1t[(gicc_ipa >> 30) & 0x1ff] = l2_gic | 0x3;
    @as([*]u64, @ptrFromInt(l2_gic))[(gicc_ipa >> 21) & 0x1ff] = l3_gic | 0x3;
    @as([*]u64, @ptrFromInt(l3_gic))[(gicc_ipa >> 12) & 0x1ff] = 0x0804_0000 | 0x4c3;

    var vcpu: VCpu = .{};
    vcpu.pc = ram_base;
    vcpu.pstate = 0x3c5; // EL1h, DAIF masked
    vcpu.vttbr = l1; // VMID 0

    // If qemu loaded a real aarch64 Image at PA 0x48000000 (the reserved guest
    // region), boot it (Ferrite-in-Ferrite); otherwise run the synthetic guest.
    const real_pa: u64 = 0x4E00_0000;
    if (@as([*]const u32, @ptrFromInt(real_pa))[0x38 / 4] == 0x644d_5241) {
        const ram_size: u64 = 16 * 1024 * 1024;
        const l2t: [*]u64 = @ptrFromInt(l2);
        l1t[(ram_base >> 30) & 0x1ff] = l2 | 0x3;
        var b: u64 = 0;
        while (b < ram_size / 0x20_0000) : (b += 1) {
            const ipa = ram_base + b * 0x20_0000;
            l2t[(ipa >> 21) & 0x1ff] = (real_pa + b * 0x20_0000) | 0x7fd; // 2 MiB block
        }
        const dtb_ipa = ram_base + 0xE0_0000; // 14 MiB in, past the kernel image
        _ = buildGuestDtb(@ptrFromInt(real_pa + 0xE0_0000), ram_base, ram_size);
        vcpu.regs[0] = dtb_ipa;
        arch.uart.print("[hyp] booting REAL guest Image (Ferrite-in-Ferrite); console follows:\n", .{});
    } else {
        // Synthetic guest: 16 pages, Image header + payload + vector table, per-page map.
        const dtb_off: u64 = 8 * ps;
        const img: [*]u8 = @ptrFromInt(ram);
        const hdr: [*]u32 = @ptrFromInt(ram);
        hdr[0] = 0x1400_0010; // code0: b #0x40
        hdr[0x38 / 4] = 0x644d_5241; // magic
        @memcpy(img[0x40 .. 0x40 + 512], @as([*]const u8, @ptrFromInt(@intFromPtr(&guestKernel)))[0..512]);
        @memcpy(@as([*]u8, @ptrFromInt(ram + 4 * ps))[0..ps], @as([*]const u8, @ptrFromInt(@intFromPtr(&guestVectors)))[0..ps]);
        _ = buildGuestDtb(@ptrFromInt(ram + dtb_off), ram_base, ram_pages * ps);
        const l2t: [*]u64 = @ptrFromInt(l2);
        const l3t: [*]u64 = @ptrFromInt(l3);
        l1t[(ram_base >> 30) & 0x1ff] = l2 | 0x3;
        l2t[(ram_base >> 21) & 0x1ff] = l3 | 0x3;
        var p: u64 = 0;
        while (p < ram_pages) : (p += 1) {
            l3t[((ram_base + p * ps) >> 12) & 0x1ff] = (ram + p * ps) | 0x7ff;
        }
        vcpu.regs[0] = ram_base + dtb_off;
        arch.uart.print("[hyp] booting synthetic guest Image; console follows:\n[guest] ", .{});
    }

    hypVcpuLoop(&vcpu);
}

export fn zigStart(dtb_ptr: u64) noreturn {
    // TPIDR_EL1 (per-CPU pointer) resets to an UNKNOWN value on real hardware;
    // the scheduler's pre-setThisCpu guards assume it reads 0 (TCG does, KVM
    // does not). Zero it before any IRQ can call schedTick/maybePreempt.
    asm volatile ("msr tpidr_el1, xzr");

    const bss_start: [*]u8 = @ptrCast(&__bss_start);
    const bss_end: [*]u8 = @ptrCast(&__bss_end);
    const len = @intFromPtr(bss_end) - @intFromPtr(bss_start);
    @memset(bss_start[0..len], 0);

    kernel.dtb.dtb_phys = dtb_ptr;

    // MMU on with identity-mapped Normal memory; without it RAM is Device-nGnRnE
    // and strict alignment breaks compiler-rt memcpy paths.
    arch.mmu.init();

    if (!kernel.dtb.parseMemory(dtb_ptr)) {
        kernel.memory.register(0x4000_0000, 0x0800_0000, .usable);
    }
    const k_start = @intFromPtr(&__kernel_start);
    const k_end = @intFromPtr(&__kernel_end);
    kernel.memory.register(k_start, k_end - k_start, .reserved);

    // In hyp mode, carve out a 16 MiB region at PA 0x48000000 for the guest VM
    // (qemu loads the guest Image there via -device loader). Reserving it before
    // memory.init keeps the page allocator from clobbering the loaded image.
    if (hyp_active != 0) {
        kernel.memory.register(0x4E00_0000, 16 * 1024 * 1024, .reserved);
    }

    // Bootargs parsed before memory.init so a `pagesize=N` can rebuild the MMU
    // at the new granule first.
    if (kernel.dtb.parseBootargs(dtb_ptr)) |bytes| {
        kernel.cmdline.init(bytes);
        if (kernel.cmdline.getValue("pagesize")) |val| {
            if (parseUint(val)) |n| {
                if (n != kernel.memory.pageSize() and arch.mmu.pickGranule(n)) {
                    kernel.memory.setPageSize(n);
                    arch.mmu.init();
                    arch.uart.print("[boot] mmu reinit at pagesize={d}\n", .{n});
                }
            }
        }
    }

    kernel.memory.init(0);

    arch.mmu.configureWalker(.{
        .hhdm_offset = 0,
        .alloc_page = &kernel.memory.allocPage,
        .free_page = &kernel.memory.freePage,
    });
    arch.mmu.captureKernelTtbr0();

    // Install exception vectors before any trapping instruction (PSCI HVC, etc.).
    arch.traps.init();

    hypProbe();
    hypRunGuestDemo();

    bringUpSecondaries(dtb_ptr);

    if (kernel.dtb.parseInitrd(dtb_ptr)) |bytes| {
        kernel.initrd.init(bytes) catch {};
        kernel.memory.register(@intFromPtr(bytes.ptr), bytes.len, .reserved);
    }

    kernel.kmain();
}

fn bringUpSecondaries(dtb_ptr: u64) void {
    var mpidrs: [kernel.cpu.MAX_CPUS]u64 = @splat(0);
    const found = kernel.dtb.parseCpus(dtb_ptr, &mpidrs);
    if (found == 0) {
        kernel.cpu.init(1);
        return;
    }

    const bsp_mpidr: u64 = arch.cpu.cpuId();

    // Pass 1: pre-allocate each secondary's kernel stack + bootstrap/idle thread
    // on the (still single-threaded) boot CPU, so the secondaries never touch the
    // heap before their per-CPU pointer is live. Don't start any CPU yet.
    var target_mpidr: [kernel.cpu.MAX_CPUS]u64 = @splat(0);
    var next_id: u32 = 1;
    var i: usize = 0;
    while (i < found and next_id < kernel.cpu.MAX_CPUS) : (i += 1) {
        if (mpidrs[i] == bsp_mpidr) continue;
        const stack_phys = kernel.memory.allocPage() orelse break;
        const boot_t = kernel.thread.Thread.initBootstrap() catch {
            kernel.memory.freePage(stack_phys);
            break;
        };
        kernel.cpu.cpus[next_id].bootstrap = boot_t;
        kernel.cpu.cpus[next_id].current = boot_t;
        arch.smp.inits[next_id] = .{
            .stack_top = stack_phys + kernel.memory.pageSize(),
            .cpu_id = next_id,
        };
        target_mpidr[next_id] = mpidrs[i];
        next_id += 1;
    }
    // Publish the CPU count before starting any secondary (stealFromOthers /
    // sched.remove iterate cpus[0..num_cpus]; offline entries are skipped).
    kernel.cpu.init(next_id);

    // Hand the target MPIDRs to arch.smp; kmain calls arch.smp.startSecondaries()
    // to PSCI them only AFTER the kernel is fully initialized. Starting them here
    // (mid-boot) hangs: a secondary would run the scheduler/kernel timer before
    // kmain has initialized them.
    var id: u32 = 1;
    while (id < next_id) : (id += 1) arch.smp.pending_mpidr[id] = target_mpidr[id];
    arch.smp.pending_count = next_id - 1;
}

pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, ra: ?usize) noreturn {
    @branchHint(.cold);
    arch.uart.write("\n[PANIC] ");
    arch.uart.write(msg);
    if (ra) |addr| {
        var buf: [32]u8 = undefined;
        arch.uart.write(std.fmt.bufPrint(&buf, " ra=0x{x}", .{addr}) catch "");
    }
    arch.uart.write("\n");
    while (true) asm volatile ("wfe");
}
