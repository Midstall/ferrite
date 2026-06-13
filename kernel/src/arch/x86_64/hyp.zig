// x86_64 microVM facility: the reusable Vm/Vcpu/Exit objects behind the
// userspace VMM ([[ferrite-vmm-userspace]]), mirroring the riscv64 and aarch64
// hyp.zig. x86 has two vendor-specific hardware-virt ISAs, so this module hosts
// BOTH and dispatches on the CPU vendor at runtime:
//   - `Svm` (AMD SVM): VMCB + nested page tables (NPT), VMRUN world-switch.
//   - `Vmx` (Intel VT-x): VMCS + extended page tables (EPT), VMLAUNCH/VMRESUME.
// The public `Vm`/`Vcpu` are thin wrappers that forward to whichever backend
// `enable()` brought up. `Exit`/`ExitReason` are shared (same tags + values as
// every other arch, so the syscall layer forwards them unchanged).
//
// IMPORTANT: QEMU TCG emulates neither SVM nor VMX (no nested virt), and this
// dev host is ARM (no x86 KVM), so NEITHER backend can be executed or validated
// here. Both are written to the vendor manuals (AMD64 APM vol 2 ch 15 + app B;
// Intel SDM vol 3 ch 23-28) and are meant to run on real hardware with nested
// KVM (`-accel kvm -cpu host`).
const std = @import("std");
const uart = @import("x86").uart;

// shared CPU helpers
inline fn rdmsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [m] "{ecx}" (msr),
    );
    return (@as(u64, hi) << 32) | lo;
}
inline fn wrmsr(msr: u32, v: u64) void {
    asm volatile ("wrmsr"
        :
        : [lo] "{eax}" (@as(u32, @truncate(v))),
          [hi] "{edx}" (@as(u32, @truncate(v >> 32))),
          [m] "{ecx}" (msr),
    );
}
const CpuidResult = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };
inline fn cpuid(leaf: u32) CpuidResult {
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (@as(u32, 0)),
    );
    return .{ .eax = a, .ebx = b, .ecx = c, .edx = d };
}

const MSR_EFER: u32 = 0xC000_0080;
const MSR_FS_BASE: u32 = 0xC000_0100;
const MSR_GS_BASE: u32 = 0xC000_0101;
const EFER_SVME: u64 = 1 << 12;

// shared exit shape (cross-arch)
pub const ExitReason = enum(u8) {
    hypercall = 0, // VMMCALL/VMCALL or an intercepted sandbox trap (the guest's syscall path)
    fault = 1, // a #VMEXIT we don't classify (incl. nested/extended page faults)
    interrupt = 2, // a host physical interrupt took the guest out
    mmio = 3, // guest port I/O to emulate in userspace
    poweroff = 4, // HLT / SHUTDOWN / triple fault
};

pub const Exit = struct {
    reason: ExitReason,
    mcause: u64 = 0, // basic exit reason / exitcode
    mtval: u64 = 0, // exit qualification / exitinfo1
    htval: u64 = 0, // guest-physical fault address
    // MMIO/PIO detail (valid when reason == .mmio).
    addr: u64 = 0, // port number
    size: u64 = 0,
    is_write: bool = false,
    reg: u32 = 0,
    data: u64 = 0,
};

// vendor dispatch
const Vendor = enum { none, amd, intel };
var vendor: Vendor = .none;

// Allocator + phys->virt captured at enable() so a Vcpu (which only sees itself,
// not its Vm) can lazily allocate + access its hardware control block. The page
// allocator returns physical bases; virt structures are reached via p2v().
var g_alloc: ?*const fn (usize) ?u64 = null;
var g_p2v: ?*const fn (u64) usize = null;

inline fn zeroPage(pa: u64, len: usize) void {
    const p2v = g_p2v orelse return;
    @memset(@as([*]u8, @ptrFromInt(p2v(pa)))[0..len], 0);
}

fn detectVendor() Vendor {
    const c = cpuid(0);
    // Vendor string is in EBX, EDX, ECX. "AuthenticAMD" -> EBX="Auth"=0x68747541;
    // "GenuineIntel" -> EBX="Genu"=0x756e6547.
    if (c.ebx == 0x6874_7541) return .amd;
    if (c.ebx == 0x756e_6547) return .intel;
    return .none;
}

/// Enable hardware virtualization on the current CPU and bring up the matching
/// backend. No-ops (returns false) on a CPU without SVM/VMX, so a TCG guest just
/// leaves the facility inactive. Idempotent.
pub fn enable(alloc: *const fn (usize) ?u64, p2v: *const fn (u64) usize) bool {
    if (vendor != .none) return true;
    g_alloc = alloc;
    g_p2v = p2v;
    switch (detectVendor()) {
        .amd => if (Svm.enable()) {
            vendor = .amd;
            return true;
        },
        .intel => if (Vmx.enable()) {
            vendor = .intel;
            return true;
        },
        .none => {},
    }
    return false;
}

/// True once a backend is live. The VMM syscalls gate on this, so on a host
/// without SVM/VMX (every QEMU TCG run, including this ARM dev box) the VM
/// syscalls cleanly return .denied instead of executing an illegal VMRUN.
pub fn active() bool {
    return vendor != .none;
}

// Public stage-2 page table: forwards to the active backend. The `leaf` arg from
// vmm.zig is the neutral marker below; each backend substitutes its own RAM bits
// (NPT vs EPT have different leaf encodings).
pub const Vm = struct {
    svm: Svm.Npt = undefined,
    vmx: Vmx.Ept = undefined,

    pub const ram_leaf: u64 = 0; // neutral marker; the backend picks the real bits

    pub fn init(alloc: *const fn (usize) ?u64, p2v: *const fn (u64) usize) ?Vm {
        var self: Vm = .{};
        switch (vendor) {
            .amd => self.svm = Svm.Npt.init(alloc, p2v) orelse return null,
            .intel => self.vmx = Vmx.Ept.init(alloc, p2v) orelse return null,
            .none => return null,
        }
        return self;
    }
    pub fn mapPage(self: *Vm, gpa: u64, hpa: u64, leaf: u64) bool {
        _ = leaf;
        return switch (vendor) {
            .amd => self.svm.mapPage(gpa, hpa, Svm.Npt.ram_leaf),
            .intel => self.vmx.mapPage(gpa, hpa, Vmx.Ept.ram_leaf),
            .none => false,
        };
    }
    pub fn tableBase(self: *const Vm) u64 {
        return switch (vendor) {
            .amd => self.svm.tableBase(),
            .intel => self.vmx.tableBase(),
            .none => 0,
        };
    }
};

// Public virtual CPU: forwards to the active backend.
pub const Vcpu = struct {
    svm: Svm.Vp = .{},
    vmx: Vmx.Vp = .{},

    pub fn setEntry(self: *Vcpu, pc: u64, table_base: u64) void {
        switch (vendor) {
            .amd => self.svm.setEntry(pc, table_base),
            .intel => self.vmx.setEntry(pc, table_base),
            .none => {},
        }
    }
    pub fn setEl0Entry(self: *Vcpu, pc: u64, sp: u64, table_base: u64) void {
        switch (vendor) {
            .amd => self.svm.setEl0Entry(pc, sp, table_base),
            .intel => self.vmx.setEl0Entry(pc, sp, table_base),
            .none => {},
        }
    }
    pub fn reg(self: *const Vcpu, i: usize) u64 {
        return switch (vendor) {
            .amd => self.svm.reg(i),
            .intel => self.vmx.reg(i),
            .none => 0,
        };
    }
    pub fn setReg(self: *Vcpu, i: usize, v: u64) void {
        switch (vendor) {
            .amd => self.svm.setReg(i, v),
            .intel => self.vmx.setReg(i, v),
            .none => {},
        }
    }
    pub fn advancePc(self: *Vcpu, bytes: u64) void {
        switch (vendor) {
            .amd => self.svm.advancePc(bytes),
            .intel => self.vmx.advancePc(bytes),
            .none => {},
        }
    }
    pub fn run(self: *Vcpu) Exit {
        return switch (vendor) {
            .amd => self.svm.run(),
            .intel => self.vmx.run(),
            .none => .{ .reason = .fault },
        };
    }
};

// Shared guest register index map for both backends:
// 0=RAX 1=RBX 2=RCX 3=RDX 4=RSI 5=RDI 6=RBP 7=RSP 8..15 = R8..R15.
// The syscall layer reads the hypercall selector from reg(0) and arg from
// reg(1), so 0=RAX / 1=RBX. Index 16 is a pseudo-register: the userspace VMM
// writes the guest CR3 there (a GVA->GPA identity table it built in the guest
// window) before entering a long-mode CPL3 sandbox.
pub const REG_GUEST_CR3: usize = 16;

// x86 hardware ModRM register number -> our regs[] index (which is ordered
// rax,rbx,rcx,rdx,rsi,rdi,rbp,rsp,r8..r15, NOT the hardware rax,rcx,rdx,rbx,...).
const hw_reg_to_idx = [16]u32{ 0, 2, 3, 1, 7, 6, 4, 5, 8, 9, 10, 11, 12, 13, 14, 15 };

// A decoded memory-access instruction (the MOV forms a driver uses for MMIO).
const Decoded = struct {
    size: u64, // access width in bytes
    is_write: bool, // true = store to the device, false = load from it
    reg_idx: u32, // regs[] index of the GPR operand (dest for a load, src for a reg store)
    imm: ?u64, // set for an immediate store (no source register)
    len: u64, // instruction length, to advance RIP past it
};

fn rdLe(b: []const u8, off: usize, n: usize) u64 {
    var v: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) v |= @as(u64, b[off + i]) << @intCast(i * 8);
    return v;
}

// Minimal x86-64 decoder for the MOV forms that touch memory (the MMIO ops).
// x86 gives no decoded fault info, so on a nested/extended page fault we fetch
// the faulting instruction and parse it here. Returns null for anything that
// isn't a recognized memory MOV (the caller then reports a plain fault).
fn decodeMov(b: []const u8) ?Decoded {
    if (b.len == 0) return null;
    var i: usize = 0;
    var opsize16 = false;
    var rex_w = false;
    var rex_r = false;
    // Legacy prefixes, then an optional REX (which must be last before the opcode).
    while (i < b.len) {
        switch (b[i]) {
            0x66 => {
                opsize16 = true;
                i += 1;
            },
            0x67, 0xf0, 0xf2, 0xf3, 0x26, 0x2e, 0x36, 0x3e, 0x64, 0x65 => i += 1,
            0x40...0x4f => {
                rex_w = (b[i] & 0x8) != 0;
                rex_r = (b[i] & 0x4) != 0;
                i += 1;
                break;
            },
            else => break,
        }
    }
    if (i >= b.len) return null;
    var two_byte = false;
    var op = b[i];
    i += 1;
    if (op == 0x0f) {
        if (i >= b.len) return null;
        two_byte = true;
        op = b[i];
        i += 1;
    }
    var is_write: bool = undefined;
    var size: u64 = undefined;
    var has_imm = false;
    const wide: u64 = if (rex_w) 8 else if (opsize16) 2 else 4;
    if (!two_byte) {
        switch (op) {
            0x88 => {
                is_write = true;
                size = 1;
            },
            0x89 => {
                is_write = true;
                size = wide;
            },
            0x8a => {
                is_write = false;
                size = 1;
            },
            0x8b => {
                is_write = false;
                size = wide;
            },
            0xc6 => {
                is_write = true;
                size = 1;
                has_imm = true;
            },
            0xc7 => {
                is_write = true;
                size = wide;
                has_imm = true;
            },
            else => return null,
        }
    } else switch (op) {
        0xb6, 0xbe => { // MOVZX/MOVSX r, r/m8
            is_write = false;
            size = 1;
        },
        0xb7, 0xbf => { // MOVZX/MOVSX r, r/m16
            is_write = false;
            size = 2;
        },
        else => return null,
    }

    if (i >= b.len) return null;
    const modrm = b[i];
    i += 1;
    const mod = modrm >> 6;
    const reg = (modrm >> 3) & 7;
    const rm = modrm & 7;
    if (mod == 3) return null; // register-direct: not an MMIO access

    var has_sib = false;
    var sib_base: u8 = 0;
    if (rm == 4) {
        if (i >= b.len) return null;
        sib_base = b[i] & 7;
        has_sib = true;
        i += 1;
    }
    var disp_len: usize = 0;
    if (mod == 0) {
        if (rm == 5 or (has_sib and sib_base == 5)) disp_len = 4; // RIP-rel / SIB no-base
    } else if (mod == 1) {
        disp_len = 1;
    } else {
        disp_len = 4;
    }
    i += disp_len;

    var imm: ?u64 = null;
    if (has_imm) {
        const isz: usize = if (size == 1) 1 else if (opsize16) 2 else 4; // imm is 4 even for size 8
        if (i + isz > b.len) return null;
        imm = rdLe(b, i, isz);
        i += isz;
    }
    return .{
        .size = size,
        .is_write = is_write,
        .reg_idx = hw_reg_to_idx[reg | (@as(u32, if (rex_r) 8 else 0))],
        .imm = imm,
        .len = i,
    };
}

inline fn sizeMask(size: u64) u64 {
    return if (size >= 8) ~@as(u64, 0) else (@as(u64, 1) << @intCast(size * 8)) - 1;
}

// AMD SVM backend (Npt = nested page table, Vp = virtual processor).
const Svm = struct {
    const MSR_VM_CR: u32 = 0xC001_0114;
    const MSR_VM_HSAVE_PA: u32 = 0xC001_0117;
    const VM_CR_SVMDIS: u64 = 1 << 4;

    var host_vmcb_pa: u64 = 0; // host segment/MSR save area (VMSAVE/VMLOAD around VMRUN)
    var iopm_pa: u64 = 0; // 12 KiB I/O permission bitmap (all-ones: intercept every port)

    fn hasSvm() bool {
        return (cpuid(0x8000_0001).ecx & (1 << 2)) != 0;
    }

    fn enable() bool {
        if (!hasSvm()) return false;
        const alloc = g_alloc.?;
        const p2v = g_p2v.?;
        var vm_cr = rdmsr(MSR_VM_CR);
        if (vm_cr & VM_CR_SVMDIS != 0) {
            if (cpuid(0x8000_000A).edx & (1 << 2) != 0) return false; // locked off
            vm_cr &= ~VM_CR_SVMDIS;
            wrmsr(MSR_VM_CR, vm_cr);
        }
        const hsave = alloc(1) orelse return false;
        zeroPage(hsave, 0x1000);
        wrmsr(MSR_VM_HSAVE_PA, hsave);
        host_vmcb_pa = alloc(1) orelse return false;
        zeroPage(host_vmcb_pa, 0x1000);
        iopm_pa = alloc(3) orelse return false; // allocPages(3) is contiguous
        @memset(@as([*]u8, @ptrFromInt(p2v(iopm_pa)))[0 .. 3 * 0x1000], 0xff);
        wrmsr(MSR_EFER, rdmsr(MSR_EFER) | EFER_SVME);
        return true;
    }

    // NPT (the stage-2): same descriptor format as ordinary x86_64 paging.
    const Npt = struct {
        root: u64,
        alloc: *const fn (usize) ?u64,
        p2v: *const fn (u64) usize,

        pub const ram_leaf: u64 = 0x1 | 0x2 | 0x4 | 0x20 | 0x40; // P|RW|US|A|D
        const table_bits: u64 = 0x1 | 0x2 | 0x4; // P|RW|US
        const addr_mask: u64 = 0x000f_ffff_ffff_f000;

        fn table(self: *const Npt, pa: u64) [*]u64 {
            return @ptrFromInt(self.p2v(pa));
        }
        fn zero(self: *const Npt, pa: u64) void {
            @memset(@as([*]u8, @ptrFromInt(self.p2v(pa)))[0..0x1000], 0);
        }
        fn init(alloc: *const fn (usize) ?u64, p2v: *const fn (u64) usize) ?Npt {
            const root = alloc(1) orelse return null;
            const self: Npt = .{ .root = root, .alloc = alloc, .p2v = p2v };
            self.zero(root);
            return self;
        }
        fn ensure(self: *Npt, tbl: u64, idx: usize) ?u64 {
            const t = self.table(tbl);
            if (t[idx] & 1 != 0) return t[idx] & addr_mask;
            const page = self.alloc(1) orelse return null;
            self.zero(page);
            t[idx] = (page & addr_mask) | table_bits;
            return page;
        }
        fn mapPage(self: *Npt, gpa: u64, hpa: u64, leaf: u64) bool {
            const pdpt = self.ensure(self.root, (gpa >> 39) & 0x1ff) orelse return false;
            const pd = self.ensure(pdpt, (gpa >> 30) & 0x1ff) orelse return false;
            const pt = self.ensure(pd, (gpa >> 21) & 0x1ff) orelse return false;
            self.table(pt)[(gpa >> 12) & 0x1ff] = (hpa & addr_mask) | leaf;
            return true;
        }
        fn tableBase(self: *const Npt) u64 {
            return self.root; // N_CR3
        }
    };

    // VMCB field offsets (AMD64 APM vol 2, appendix B).
    const C_EXCEPTION: usize = 0x008; // intercept exception vector (bit per #vector)
    const C_INTERCEPT3: usize = 0x00c;
    const C_INTERCEPT4: usize = 0x010;
    const C_IOPM_BASE: usize = 0x040;
    const C_ASID: usize = 0x058;
    const C_TLB_CTL: usize = 0x05c;
    const C_EXITCODE: usize = 0x070;
    const C_EXITINFO1: usize = 0x078;
    const C_EXITINFO2: usize = 0x080;
    const C_NP_ENABLE: usize = 0x090;
    const C_N_CR3: usize = 0x0b0;
    const C_NRIP: usize = 0x0c8;
    const S_ES: usize = 0x400;
    const S_CS: usize = 0x410;
    const S_SS: usize = 0x420;
    const S_DS: usize = 0x430;
    const S_FS: usize = 0x440;
    const S_GS: usize = 0x450;
    const S_GDTR: usize = 0x460;
    const S_LDTR: usize = 0x470;
    const S_IDTR: usize = 0x480;
    const S_TR: usize = 0x490;
    const S_CPL: usize = 0x4cb;
    const S_EFER: usize = 0x4d0;
    const S_CR4: usize = 0x548;
    const S_CR3: usize = 0x550;
    const S_CR0: usize = 0x558;
    const S_RFLAGS: usize = 0x570;
    const S_RIP: usize = 0x578;
    const S_RSP: usize = 0x5d8;
    const S_RAX: usize = 0x5f8;
    const S_GPAT: usize = 0x668;

    const INT3_INTR: u32 = 1 << 0;
    const INT3_INTn: u32 = 1 << 21;
    const INT3_HLT: u32 = 1 << 24;
    const INT3_IOIO: u32 = 1 << 27;
    const INT3_SHUTDOWN: u32 = 1 << 31;
    const INT4_VMRUN: u32 = 1 << 0;
    const INT4_VMMCALL: u32 = 1 << 1;

    const EXIT_INTR: u64 = 0x060;
    const EXIT_HLT: u64 = 0x078;
    const EXIT_IOIO: u64 = 0x07b;
    const EXIT_SHUTDOWN: u64 = 0x07f;
    const EXIT_EXCP_UD: u64 = 0x046; // #VMEXIT(EXCP base 0x040 + vector 6 = #UD)
    const EXIT_VMMCALL: u64 = 0x081;
    const EXIT_NPF: u64 = 0x400;
    const EXIT_INVALID: u64 = 0xffff_ffff_ffff_ffff;

    // 12-bit segment attrib (low byte = descriptor byte 5, high nibble = flags).
    const ATTR_CODE32_R0: u16 = 0xc9b;
    const ATTR_DATA32_R0: u16 = 0xc93;
    const ATTR_CODE32_R3: u16 = 0xcfb;
    const ATTR_DATA32_R3: u16 = 0xcf3;
    const ATTR_CODE64_R3: u16 = 0xafb; // 64-bit code (L=1, D=0), DPL=3
    const ATTR_TSS32: u16 = 0x08b;
    const EFER_LONG: u64 = (1 << 8) | (1 << 10) | EFER_SVME; // LME | LMA | SVME

    const Vp = struct {
        regs: [16]u64 = @splat(0),
        rip: u64 = 0,
        rflags: u64 = 0x2,
        ncr3: u64 = 0,
        cpl: u8 = 0,
        exitcode: u64 = 0,
        exitinfo1: u64 = 0,
        exitinfo2: u64 = 0,
        nrip: u64 = 0,
        guest_cr3: u64 = 0, // guest CR3 for the long-mode CPL3 sandbox (reg index 16)
        vmcb_pa: u64 = 0,

        fn setEntry(self: *Vp, pc: u64, table_base: u64) void {
            self.rip = pc;
            self.ncr3 = table_base;
            self.cpl = 0;
        }
        // Sandbox a 64-bit program at CPL3 in long mode. `sp` lands in RSP; the
        // guest CR3 (an identity GVA->GPA table built by the userspace VMM) is
        // set separately via setReg(REG_GUEST_CR3=16) before entry.
        fn setEl0Entry(self: *Vp, pc: u64, sp: u64, table_base: u64) void {
            self.rip = pc;
            self.regs[7] = sp;
            self.ncr3 = table_base;
            self.cpl = 3;
        }
        fn reg(self: *const Vp, i: usize) u64 {
            return if (i >= 16) 0 else self.regs[i];
        }
        fn setReg(self: *Vp, i: usize, v: u64) void {
            if (i == REG_GUEST_CR3) {
                self.guest_cr3 = v;
            } else if (i < 16) {
                self.regs[i] = v;
            }
        }
        fn advancePc(self: *Vp, bytes: u64) void {
            self.rip +%= bytes;
        }

        fn vmcb(self: *const Vp) [*]u8 {
            return @ptrFromInt(g_p2v.?(self.vmcb_pa));
        }
        fn w8(self: *const Vp, off: usize, v: u8) void {
            self.vmcb()[off] = v;
        }
        fn w16(self: *const Vp, off: usize, v: u16) void {
            @as(*align(1) u16, @ptrCast(&self.vmcb()[off])).* = v;
        }
        fn w32(self: *const Vp, off: usize, v: u32) void {
            @as(*align(1) u32, @ptrCast(&self.vmcb()[off])).* = v;
        }
        fn w64(self: *const Vp, off: usize, v: u64) void {
            @as(*align(1) u64, @ptrCast(&self.vmcb()[off])).* = v;
        }
        fn r64(self: *const Vp, off: usize) u64 {
            return @as(*align(1) u64, @ptrCast(&self.vmcb()[off])).*;
        }
        fn seg(self: *const Vp, off: usize, sel: u16, attrib: u16, limit: u32, base: u64) void {
            self.w16(off + 0, sel);
            self.w16(off + 2, attrib);
            self.w32(off + 4, limit);
            self.w64(off + 8, base);
        }

        fn marshal(self: *Vp) void {
            @memset(self.vmcb()[0..0x1000], 0);
            var int3: u32 = INT3_HLT | INT3_IOIO | INT3_INTR | INT3_SHUTDOWN;
            if (self.cpl == 3) int3 |= INT3_INTn;
            self.w32(C_INTERCEPT3, int3);
            self.w32(C_INTERCEPT4, INT4_VMRUN | INT4_VMMCALL);
            // Sandbox: trap #UD so the program's `syscall` (no EFER.SCE -> #UD)
            // surfaces as a hypercall.
            if (self.cpl == 3) self.w32(C_EXCEPTION, 1 << 6);
            self.w64(C_IOPM_BASE, iopm_pa);
            self.w32(C_ASID, 1);
            self.w32(C_TLB_CTL, 1);
            self.w64(C_NP_ENABLE, 1);
            self.w64(C_N_CR3, self.ncr3);

            const ring3 = self.cpl == 3;
            if (ring3) {
                // 64-bit long mode (guest paging on; CR3 = identity GVA->GPA table).
                self.w64(S_CR0, 0x8000_0011); // PG | PE | ET
                self.w64(S_CR3, self.guest_cr3);
                self.w64(S_CR4, 0x20); // PAE
                self.w64(S_EFER, EFER_LONG); // LME | LMA | SVME
            } else {
                // Flat 32-bit protected mode (paging off, NPT-translated).
                self.w64(S_CR0, 0x0000_0011); // PE | ET
                self.w64(S_CR3, 0);
                self.w64(S_CR4, 0);
                self.w64(S_EFER, EFER_SVME); // SVME required for VMRUN
            }
            self.w64(S_GPAT, 0x0007_0406_0007_0406);
            self.w64(S_RFLAGS, self.rflags);
            self.w64(S_RIP, self.rip);
            self.w64(S_RSP, self.regs[7]);
            self.w64(S_RAX, self.regs[0]);

            const cs_sel: u16 = if (ring3) 0x1b else 0x08;
            const ds_sel: u16 = if (ring3) 0x23 else 0x10;
            const cs_attr: u16 = if (ring3) ATTR_CODE64_R3 else ATTR_CODE32_R0;
            const ds_attr: u16 = if (ring3) ATTR_DATA32_R3 else ATTR_DATA32_R0;
            self.seg(S_CS, cs_sel, cs_attr, 0xf_ffff, 0);
            self.seg(S_SS, ds_sel, ds_attr, 0xf_ffff, 0);
            self.seg(S_DS, ds_sel, ds_attr, 0xf_ffff, 0);
            self.seg(S_ES, ds_sel, ds_attr, 0xf_ffff, 0);
            self.seg(S_FS, ds_sel, ds_attr, 0xf_ffff, 0);
            self.seg(S_GS, ds_sel, ds_attr, 0xf_ffff, 0);
            self.seg(S_GDTR, 0, 0, 0xffff, 0);
            self.seg(S_IDTR, 0, 0, 0xffff, 0);
            self.seg(S_LDTR, 0, 0, 0, 0);
            self.seg(S_TR, 0x18, ATTR_TSS32, 0x67, 0);
            self.w8(S_CPL, self.cpl);
        }

        fn unmarshal(self: *Vp) void {
            self.regs[0] = self.r64(S_RAX);
            self.regs[7] = self.r64(S_RSP);
            self.rip = self.r64(S_RIP);
            self.rflags = self.r64(S_RFLAGS);
            self.exitcode = self.r64(C_EXITCODE);
            self.exitinfo1 = self.r64(C_EXITINFO1);
            self.exitinfo2 = self.r64(C_EXITINFO2);
            self.nrip = self.r64(C_NRIP);
        }

        // Walk the NPT (stage-2) to translate a guest-physical to host-physical,
        // honoring 1 GiB/2 MiB large pages. Present = bit 0.
        fn gpaToHpa(self: *const Vp, gpa: u64) ?u64 {
            const p2v = g_p2v.?;
            const AM: u64 = 0x000f_ffff_ffff_f000;
            var t = self.ncr3 & AM;
            var e = @as([*]u64, @ptrFromInt(p2v(t)))[(gpa >> 39) & 0x1ff];
            if (e & 1 == 0) return null;
            t = e & AM;
            e = @as([*]u64, @ptrFromInt(p2v(t)))[(gpa >> 30) & 0x1ff];
            if (e & 1 == 0) return null;
            if (e & 0x80 != 0) return (e & 0x000f_ffff_c000_0000) | (gpa & 0x3fff_ffff);
            t = e & AM;
            e = @as([*]u64, @ptrFromInt(p2v(t)))[(gpa >> 21) & 0x1ff];
            if (e & 1 == 0) return null;
            if (e & 0x80 != 0) return (e & 0x000f_ffff_ffe0_0000) | (gpa & 0x1f_ffff);
            t = e & AM;
            e = @as([*]u64, @ptrFromInt(p2v(t)))[(gpa >> 12) & 0x1ff];
            if (e & 1 == 0) return null;
            return (e & AM) | (gpa & 0xfff);
        }
        // Up to 15 instruction bytes at the faulting RIP: prefer AMD decode
        // assists (VMCB 0xD0 = count, 0xD1.. = bytes), else read guest memory
        // (RIP == GPA for our flat/identity guests).
        fn fetchInsn(self: *const Vp, buf: *[15]u8) usize {
            const n: usize = self.vmcb()[0xd0];
            if (n > 0 and n <= 15) {
                var k: usize = 0;
                while (k < n) : (k += 1) buf[k] = self.vmcb()[0xd1 + k];
                return n;
            }
            const hpa = self.gpaToHpa(self.rip) orelse return 0;
            const off = self.rip & 0xfff;
            const cnt: usize = @intCast(@min(@as(u64, 15), 0x1000 - off));
            const src = @as([*]const u8, @ptrFromInt(g_p2v.?(hpa)));
            var k: usize = 0;
            while (k < cnt) : (k += 1) buf[k] = src[k];
            return cnt;
        }
        fn npf(self: *Vp) Exit {
            var ib: [15]u8 = undefined;
            const n = self.fetchInsn(&ib);
            if (decodeMov(ib[0..n])) |d| {
                const mask = sizeMask(d.size);
                const data = if (d.imm) |im| im & mask else self.regs[d.reg_idx] & mask;
                self.rip +%= d.len;
                return .{ .reason = .mmio, .addr = self.exitinfo2, .size = d.size, .is_write = d.is_write, .reg = d.reg_idx, .data = data, .mcause = EXIT_NPF, .htval = self.exitinfo2 };
            }
            return .{ .reason = .fault, .mcause = EXIT_NPF, .mtval = self.exitinfo1, .htval = self.exitinfo2, .addr = self.exitinfo2 };
        }

        fn run(self: *Vp) Exit {
            if (self.vmcb_pa == 0) {
                self.vmcb_pa = (g_alloc.?)(1) orelse return .{ .reason = .fault };
            }
            while (true) {
                self.marshal();
                svmEnter(&self.regs, self.vmcb_pa, host_vmcb_pa);
                self.unmarshal();
                switch (self.exitcode) {
                    EXIT_VMMCALL => {
                        self.rip = if (self.nrip != 0) self.nrip else self.rip + 3;
                        return .{ .reason = .hypercall, .mcause = self.exitcode };
                    },
                    0x075 => { // SWINT: intercepted INT n from a CPL3 sandbox
                        self.rip = if (self.nrip != 0) self.nrip else self.rip + 2;
                        return .{ .reason = .hypercall, .mcause = self.exitcode };
                    },
                    EXIT_EXCP_UD => { // #UD: the sandbox's `syscall` (2 bytes: 0F 05)
                        self.rip +%= 2;
                        return .{ .reason = .hypercall, .mcause = self.exitcode };
                    },
                    EXIT_HLT, EXIT_SHUTDOWN, EXIT_INVALID => return .{ .reason = .poweroff, .mcause = self.exitcode, .mtval = self.exitinfo1 },
                    EXIT_INTR => return .{ .reason = .interrupt, .mcause = self.exitcode },
                    EXIT_IOIO => {
                        const info1 = self.exitinfo1;
                        const is_in = (info1 & 1) != 0;
                        const port: u64 = (info1 >> 16) & 0xffff;
                        const size: u64 = if (info1 & (1 << 4) != 0) 1 else if (info1 & (1 << 5) != 0) 2 else 4;
                        self.rip = self.exitinfo2;
                        return .{
                            .reason = .mmio,
                            .addr = port,
                            .size = size,
                            .is_write = !is_in,
                            .reg = 0,
                            .data = if (!is_in) (self.regs[0] & ((@as(u64, 1) << @intCast(size * 8)) - 1)) else 0,
                            .mcause = self.exitcode,
                        };
                    },
                    EXIT_NPF => return self.npf(), // decode the faulting MOV -> .mmio, else .fault
                    else => return .{ .reason = .fault, .mcause = self.exitcode, .mtval = self.exitinfo1, .htval = self.exitinfo2 },
                }
            }
        }
    };

    fn demo(alloc: *const fn (usize) ?u64, p2v: *const fn (u64) usize) void {
        var vm = Npt.init(alloc, p2v) orelse {
            uart.print("[hyp] x86 SVM VM init failed\n", .{});
            return;
        };
        const ram = alloc(1) orelse return;
        @memcpy(@as([*]u8, @ptrFromInt(p2v(ram)))[0..demo_blob.len], &demo_blob);
        const gpa: u64 = 0x10_0000;
        if (!vm.mapPage(gpa, ram, Npt.ram_leaf)) {
            uart.print("[hyp] x86 SVM VM map failed\n", .{});
            return;
        }
        var vcpu: Vp = .{};
        vcpu.setEntry(gpa, vm.tableBase());
        vcpu.regs[7] = gpa + 0xff0;
        runDemo(&vcpu, "SVM");
    }
};

// One AMD VMRUN. Pins the args into the SysV registers svmVmrun expects
// (rdi/rsi/rdx) via inline asm, so it works regardless of the kernel's target
// ABI (the UEFI build is Win64). svmVmrun preserves rbx/rbp/r12-r15 itself.
inline fn svmEnter(regs: [*]u64, guest_vmcb_pa: u64, host_vmcb_pa_: u64) void {
    asm volatile ("call svmVmrun"
        :
        : [r] "{rdi}" (regs),
          [g] "{rsi}" (guest_vmcb_pa),
          [h] "{rdx}" (host_vmcb_pa_),
        : .{ .rax = true, .rcx = true, .rdx = true, .rsi = true, .rdi = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .memory = true });
}

export fn svmVmrun() callconv(.naked) noreturn {
    asm volatile (
        \\ push %rbp
        \\ push %rbx
        \\ push %r12
        \\ push %r13
        \\ push %r14
        \\ push %r15
        \\ push %rdx                 // [rsp+8]  host_vmcb_pa
        \\ push %rdi                 // [rsp+0]  regs ptr
        \\ clgi
        \\ movq %rdx, %rax
        \\ vmsave %rax               // save host FS/GS/TR/LDTR/syscall MSRs
        \\ movq %rsi, %rax           // rax = guest_vmcb_pa
        \\ vmload %rax               // load guest segment state
        \\ movq 0x08(%rdi), %rbx
        \\ movq 0x10(%rdi), %rcx
        \\ movq 0x18(%rdi), %rdx
        \\ movq 0x30(%rdi), %rbp
        \\ movq 0x40(%rdi), %r8
        \\ movq 0x48(%rdi), %r9
        \\ movq 0x50(%rdi), %r10
        \\ movq 0x58(%rdi), %r11
        \\ movq 0x60(%rdi), %r12
        \\ movq 0x68(%rdi), %r13
        \\ movq 0x70(%rdi), %r14
        \\ movq 0x78(%rdi), %r15
        \\ movq 0x20(%rdi), %rsi
        \\ movq 0x28(%rdi), %rdi
        \\ vmrun %rax                // rax = guest_vmcb_pa
        \\ vmsave %rax               // save guest segment state back
        \\ push %rax                 // stash guest_vmcb_pa
        \\ movq 8(%rsp), %rax        // rax = regs ptr
        \\ movq %rbx, 0x08(%rax)
        \\ movq %rcx, 0x10(%rax)
        \\ movq %rdx, 0x18(%rax)
        \\ movq %rsi, 0x20(%rax)
        \\ movq %rdi, 0x28(%rax)
        \\ movq %rbp, 0x30(%rax)
        \\ movq %r8,  0x40(%rax)
        \\ movq %r9,  0x48(%rax)
        \\ movq %r10, 0x50(%rax)
        \\ movq %r11, 0x58(%rax)
        \\ movq %r12, 0x60(%rax)
        \\ movq %r13, 0x68(%rax)
        \\ movq %r14, 0x70(%rax)
        \\ movq %r15, 0x78(%rax)
        \\ pop %rax                  // discard stashed guest_vmcb_pa
        \\ pop %rdi                  // discard regs ptr
        \\ pop %rax                  // rax = host_vmcb_pa
        \\ vmload %rax               // restore host FS/GS/TR/LDTR/syscall MSRs
        \\ stgi
        \\ pop %r15
        \\ pop %r14
        \\ pop %r13
        \\ pop %r12
        \\ pop %rbx
        \\ pop %rbp
        \\ ret
    );
}

// Intel VT-x (VMX) backend (Ept = extended page table, Vp = virtual processor).
const Vmx = struct {
    const MSR_FEATURE_CONTROL: u32 = 0x3a;
    const MSR_VMX_BASIC: u32 = 0x480;
    const MSR_VMX_PINBASED_CTLS: u32 = 0x481;
    const MSR_VMX_PROCBASED_CTLS: u32 = 0x482;
    const MSR_VMX_EXIT_CTLS: u32 = 0x483;
    const MSR_VMX_ENTRY_CTLS: u32 = 0x484;
    const MSR_VMX_PROCBASED_CTLS2: u32 = 0x48b;
    const MSR_VMX_TRUE_PINBASED_CTLS: u32 = 0x48d;
    const MSR_VMX_TRUE_PROCBASED_CTLS: u32 = 0x48e;
    const MSR_VMX_TRUE_EXIT_CTLS: u32 = 0x48f;
    const MSR_VMX_TRUE_ENTRY_CTLS: u32 = 0x490;
    const MSR_VMX_CR0_FIXED0: u32 = 0x486;
    const MSR_VMX_CR0_FIXED1: u32 = 0x487;
    const MSR_VMX_CR4_FIXED0: u32 = 0x488;
    const MSR_VMX_CR4_FIXED1: u32 = 0x489;

    var vmxon_pa: u64 = 0;
    var vmx_rev: u32 = 0;
    var use_true: bool = false;

    fn hasVmx() bool {
        return (cpuid(1).ecx & (1 << 5)) != 0;
    }

    inline fn readCr0() u64 {
        return asm volatile ("mov %%cr0, %[o]"
            : [o] "=r" (-> u64),
        );
    }
    inline fn readCr3() u64 {
        return asm volatile ("mov %%cr3, %[o]"
            : [o] "=r" (-> u64),
        );
    }
    inline fn readCr4() u64 {
        return asm volatile ("mov %%cr4, %[o]"
            : [o] "=r" (-> u64),
        );
    }
    inline fn writeCr0(v: u64) void {
        asm volatile ("mov %[v], %%cr0"
            :
            : [v] "r" (v),
        );
    }
    inline fn writeCr4(v: u64) void {
        asm volatile ("mov %[v], %%cr4"
            :
            : [v] "r" (v),
        );
    }
    inline fn readCs() u16 {
        return asm volatile ("mov %%cs, %[o]"
            : [o] "=r" (-> u16),
        );
    }
    inline fn readSs() u16 {
        return asm volatile ("mov %%ss, %[o]"
            : [o] "=r" (-> u16),
        );
    }
    inline fn readDs() u16 {
        return asm volatile ("mov %%ds, %[o]"
            : [o] "=r" (-> u16),
        );
    }
    inline fn readEs() u16 {
        return asm volatile ("mov %%es, %[o]"
            : [o] "=r" (-> u16),
        );
    }
    inline fn readFs() u16 {
        return asm volatile ("mov %%fs, %[o]"
            : [o] "=r" (-> u16),
        );
    }
    inline fn readGs() u16 {
        return asm volatile ("mov %%gs, %[o]"
            : [o] "=r" (-> u16),
        );
    }
    inline fn readTr() u16 {
        return asm volatile ("str %[o]"
            : [o] "=r" (-> u16),
        );
    }
    inline fn sgdtBase() u64 {
        var buf: [10]u8 align(2) = undefined;
        asm volatile ("sgdt %[m]"
            : [m] "=m" (buf),
        );
        return @as(*align(1) u64, @ptrCast(&buf[2])).*;
    }
    inline fn sidtBase() u64 {
        var buf: [10]u8 align(2) = undefined;
        asm volatile ("sidt %[m]"
            : [m] "=m" (buf),
        );
        return @as(*align(1) u64, @ptrCast(&buf[2])).*;
    }
    // Long-mode system descriptor (TSS) base: 16-byte descriptor in the GDT.
    fn descBase(gdt_base: u64, sel: u16) u64 {
        const d: [*]u8 = @ptrFromInt(gdt_base + (sel & 0xfff8));
        const low: u64 = @as(u64, d[2]) | (@as(u64, d[3]) << 8) | (@as(u64, d[4]) << 16) | (@as(u64, d[7]) << 24);
        const high: u64 = @as(u64, @as(*align(1) u32, @ptrCast(&d[8])).*) << 32;
        return low | high;
    }

    // VMREAD/VMWRITE/VMCLEAR/VMPTRLD/VMXON. Failures (CF/ZF) are ignored here
    // (unverifiable without hardware); run() reports a fault if entry fails.
    inline fn vmwrite(field: u64, val: u64) void {
        asm volatile ("vmwrite %[v], %[f]"
            :
            : [v] "r" (val),
              [f] "r" (field),
            : .{ .cc = true, .memory = true });
    }
    inline fn vmread(field: u64) u64 {
        return asm volatile ("vmread %[f], %[o]"
            : [o] "=r" (-> u64),
            : [f] "r" (field),
            : .{ .cc = true });
    }
    fn vmclear(pa: u64) void {
        const p = pa;
        asm volatile ("vmclear %[m]"
            :
            : [m] "m" (p),
            : .{ .cc = true, .memory = true });
    }
    fn vmptrld(pa: u64) void {
        const p = pa;
        asm volatile ("vmptrld %[m]"
            :
            : [m] "m" (p),
            : .{ .cc = true, .memory = true });
    }
    fn vmxonExec(pa: u64) bool {
        const p = pa;
        var ok: u8 = undefined;
        asm volatile ("vmxon %[m]; seta %[o]"
            : [o] "=r" (ok),
            : [m] "m" (p),
            : .{ .cc = true, .memory = true });
        return ok != 0;
    }

    fn adjustCtl(msr: u32, desired: u32) u32 {
        const v = rdmsr(msr);
        const allowed0: u32 = @truncate(v); // must-be-1
        const allowed1: u32 = @truncate(v >> 32); // may-be-1
        return (desired | allowed0) & allowed1;
    }

    fn enable() bool {
        if (!hasVmx()) return false;
        const alloc = g_alloc.?;
        const p2v = g_p2v.?;
        var fc = rdmsr(MSR_FEATURE_CONTROL);
        if (fc & 1 == 0) {
            fc |= 1 | (1 << 2); // lock + enable VMX outside SMX
            wrmsr(MSR_FEATURE_CONTROL, fc);
        } else if (fc & (1 << 2) == 0) {
            return false; // locked without VMX enabled
        }
        // CR0/CR4 must satisfy the fixed bits before VMXON.
        writeCr0((readCr0() | rdmsr(MSR_VMX_CR0_FIXED0)) & rdmsr(MSR_VMX_CR0_FIXED1));
        writeCr4((readCr4() | (1 << 13)) | rdmsr(MSR_VMX_CR4_FIXED0)); // VMXE + fixed
        const basic = rdmsr(MSR_VMX_BASIC);
        vmx_rev = @truncate(basic & 0x7fff_ffff);
        use_true = (basic & (@as(u64, 1) << 55)) != 0;
        vmxon_pa = alloc(1) orelse return false;
        zeroPage(vmxon_pa, 0x1000);
        @as(*align(1) u32, @ptrFromInt(p2v(vmxon_pa))).* = vmx_rev;
        return vmxonExec(vmxon_pa);
    }

    // EPT (the stage-2). Leaf bits differ from NPT: R|W|X + memory type.
    const Ept = struct {
        root: u64,
        alloc: *const fn (usize) ?u64,
        p2v: *const fn (u64) usize,

        pub const ram_leaf: u64 = 0x1 | 0x2 | 0x4 | (6 << 3); // R|W|X|WB
        const table_bits: u64 = 0x1 | 0x2 | 0x4; // R|W|X
        const addr_mask: u64 = 0x000f_ffff_ffff_f000;

        fn table(self: *const Ept, pa: u64) [*]u64 {
            return @ptrFromInt(self.p2v(pa));
        }
        fn zero(self: *const Ept, pa: u64) void {
            @memset(@as([*]u8, @ptrFromInt(self.p2v(pa)))[0..0x1000], 0);
        }
        fn init(alloc: *const fn (usize) ?u64, p2v: *const fn (u64) usize) ?Ept {
            const root = alloc(1) orelse return null;
            const self: Ept = .{ .root = root, .alloc = alloc, .p2v = p2v };
            self.zero(root);
            return self;
        }
        fn ensure(self: *Ept, tbl: u64, idx: usize) ?u64 {
            const t = self.table(tbl);
            if (t[idx] & 0x7 != 0) return t[idx] & addr_mask;
            const page = self.alloc(1) orelse return null;
            self.zero(page);
            t[idx] = (page & addr_mask) | table_bits;
            return page;
        }
        fn mapPage(self: *Ept, gpa: u64, hpa: u64, leaf: u64) bool {
            const pdpt = self.ensure(self.root, (gpa >> 39) & 0x1ff) orelse return false;
            const pd = self.ensure(pdpt, (gpa >> 30) & 0x1ff) orelse return false;
            const pt = self.ensure(pd, (gpa >> 21) & 0x1ff) orelse return false;
            self.table(pt)[(gpa >> 12) & 0x1ff] = (hpa & addr_mask) | leaf;
            return true;
        }
        fn tableBase(self: *const Ept) u64 {
            // EPTP: memtype WB(6) | page-walk-length-1 (3 -> 4 levels, <<3) | root.
            return (self.root & addr_mask) | 6 | (3 << 3);
        }
    };

    // VMCS field encodings (Intel SDM vol 3, appendix B).
    const GUEST_ES_SEL: u64 = 0x800;
    const GUEST_CS_SEL: u64 = 0x802;
    const GUEST_SS_SEL: u64 = 0x804;
    const GUEST_DS_SEL: u64 = 0x806;
    const GUEST_FS_SEL: u64 = 0x808;
    const GUEST_GS_SEL: u64 = 0x80a;
    const GUEST_LDTR_SEL: u64 = 0x80c;
    const GUEST_TR_SEL: u64 = 0x80e;
    const VMCS_LINK_PTR: u64 = 0x2800;
    const GUEST_EFER: u64 = 0x2806;
    const GUEST_ES_LIMIT: u64 = 0x4800;
    const GUEST_CS_LIMIT: u64 = 0x4802;
    const GUEST_SS_LIMIT: u64 = 0x4804;
    const GUEST_DS_LIMIT: u64 = 0x4806;
    const GUEST_FS_LIMIT: u64 = 0x4808;
    const GUEST_GS_LIMIT: u64 = 0x480a;
    const GUEST_LDTR_LIMIT: u64 = 0x480c;
    const GUEST_TR_LIMIT: u64 = 0x480e;
    const GUEST_GDTR_LIMIT: u64 = 0x4810;
    const GUEST_IDTR_LIMIT: u64 = 0x4812;
    const GUEST_ES_AR: u64 = 0x4814;
    const GUEST_CS_AR: u64 = 0x4816;
    const GUEST_SS_AR: u64 = 0x4818;
    const GUEST_DS_AR: u64 = 0x481a;
    const GUEST_FS_AR: u64 = 0x481c;
    const GUEST_GS_AR: u64 = 0x481e;
    const GUEST_LDTR_AR: u64 = 0x4820;
    const GUEST_TR_AR: u64 = 0x4822;
    const GUEST_INTERRUPTIBILITY: u64 = 0x4824;
    const GUEST_ACTIVITY: u64 = 0x4826;
    const GUEST_CR0: u64 = 0x6800;
    const GUEST_CR3: u64 = 0x6802;
    const GUEST_CR4: u64 = 0x6804;
    const GUEST_ES_BASE: u64 = 0x6806;
    const GUEST_CS_BASE: u64 = 0x6808;
    const GUEST_SS_BASE: u64 = 0x680a;
    const GUEST_DS_BASE: u64 = 0x680c;
    const GUEST_FS_BASE: u64 = 0x680e;
    const GUEST_GS_BASE: u64 = 0x6810;
    const GUEST_LDTR_BASE: u64 = 0x6812;
    const GUEST_TR_BASE: u64 = 0x6814;
    const GUEST_GDTR_BASE: u64 = 0x6816;
    const GUEST_IDTR_BASE: u64 = 0x6818;
    const GUEST_RSP: u64 = 0x681c;
    const GUEST_RIP: u64 = 0x681e;
    const GUEST_RFLAGS: u64 = 0x6820;

    const HOST_ES_SEL: u64 = 0xc00;
    const HOST_CS_SEL: u64 = 0xc02;
    const HOST_SS_SEL: u64 = 0xc04;
    const HOST_DS_SEL: u64 = 0xc06;
    const HOST_FS_SEL: u64 = 0xc08;
    const HOST_GS_SEL: u64 = 0xc0a;
    const HOST_TR_SEL: u64 = 0xc0c;
    const HOST_EFER: u64 = 0x2c02;
    const HOST_CR0: u64 = 0x6c00;
    const HOST_CR3: u64 = 0x6c02;
    const HOST_CR4: u64 = 0x6c04;
    const HOST_FS_BASE: u64 = 0x6c06;
    const HOST_GS_BASE: u64 = 0x6c08;
    const HOST_TR_BASE: u64 = 0x6c0a;
    const HOST_GDTR_BASE: u64 = 0x6c0c;
    const HOST_IDTR_BASE: u64 = 0x6c0e;
    const HOST_RSP: u64 = 0x6c14;
    const HOST_RIP: u64 = 0x6c16;
    const VM_INSTR_ERROR: u64 = 0x4400;

    const PIN_CTLS: u64 = 0x4000;
    const PROC_CTLS: u64 = 0x4002;
    const EXCEPTION_BITMAP: u64 = 0x4004;
    const VMEXIT_CTLS: u64 = 0x400c;
    const VMENTRY_CTLS: u64 = 0x4012;
    const PROC_CTLS2: u64 = 0x401e;
    const EPT_POINTER: u64 = 0x201a;
    const VM_EXIT_REASON: u64 = 0x4402;
    const VM_EXIT_QUAL: u64 = 0x6400;
    const GUEST_PHYS_ADDR: u64 = 0x2400;
    const VMEXIT_INSTR_LEN: u64 = 0x440c;

    // Control bits.
    const PIN_EXTINT_EXITING: u32 = 1 << 0;
    const PROC_HLT_EXITING: u32 = 1 << 7;
    const PROC_UNCOND_IO: u32 = 1 << 24;
    const PROC_SECONDARY: u32 = 1 << 31;
    const PROC2_EPT: u32 = 1 << 1;
    const PROC2_UNRESTRICTED: u32 = 1 << 7;
    const ENTRY_LOAD_EFER: u32 = 1 << 15;
    const ENTRY_IA32E: u32 = 1 << 9; // IA-32e mode guest (long mode)
    const EXIT_HOST_ADDR64: u32 = 1 << 9;
    const EXIT_SAVE_EFER: u32 = 1 << 20;
    const EXIT_LOAD_EFER: u32 = 1 << 21;
    const EFER_LME: u64 = 1 << 8;
    const EFER_LMA: u64 = 1 << 10;

    // segment access-rights (VMX form).
    const AR_CODE32_R0: u32 = 0xc09b;
    const AR_DATA32_R0: u32 = 0xc093;
    const AR_CODE32_R3: u32 = 0xc0fb;
    const AR_DATA32_R3: u32 = 0xc0f3;
    const AR_CODE64_R3: u32 = 0xa0fb; // 64-bit code (L=1, D=0), DPL=3
    const AR_TSS32: u32 = 0x008b;
    const AR_UNUSABLE: u32 = 1 << 16;

    // Basic exit reasons.
    const VMX_EXIT_EXCEPTION: u64 = 0;
    const VMX_EXIT_EXTINT: u64 = 1;
    const VMX_EXIT_TRIPLE_FAULT: u64 = 2;
    const VMX_EXIT_HLT: u64 = 12;
    const VMX_EXIT_VMCALL: u64 = 18;
    const VMX_EXIT_IO: u64 = 30;
    const VMX_EXIT_EPT_VIOLATION: u64 = 48;
    const VMX_EXIT_EPT_MISCONFIG: u64 = 49;

    const Vp = struct {
        regs: [16]u64 = @splat(0),
        rip: u64 = 0,
        rflags: u64 = 0x2,
        rsp: u64 = 0,
        eptp: u64 = 0,
        cpl: u8 = 0,
        guest_cr3: u64 = 0, // identity GVA->GPA table for the long-mode CPL3 sandbox
        launched: bool = false,
        vmcs_pa: u64 = 0,

        fn setEntry(self: *Vp, pc: u64, table_base: u64) void {
            self.rip = pc;
            self.eptp = table_base;
            self.cpl = 0;
        }
        // Sandbox a 64-bit program at CPL3 in long mode. The guest CR3 is set
        // separately via setReg(REG_GUEST_CR3) before entry.
        fn setEl0Entry(self: *Vp, pc: u64, sp: u64, table_base: u64) void {
            self.rip = pc;
            self.rsp = sp;
            self.eptp = table_base;
            self.cpl = 3;
        }
        fn reg(self: *const Vp, i: usize) u64 {
            return if (i >= 16) 0 else self.regs[i];
        }
        fn setReg(self: *Vp, i: usize, v: u64) void {
            if (i == REG_GUEST_CR3) {
                self.guest_cr3 = v;
            } else if (i < 16) {
                self.regs[i] = v;
            }
        }
        fn advancePc(self: *Vp, bytes: u64) void {
            self.rip +%= bytes;
        }

        fn guestCr0() u64 {
            // Unrestricted guest exempts PE/PG from the fixed-1 requirement.
            const fixed0 = rdmsr(MSR_VMX_CR0_FIXED0) & ~@as(u64, (1 << 0) | (1 << 31));
            return (@as(u64, 0x11) | fixed0) & rdmsr(MSR_VMX_CR0_FIXED1);
        }
        fn guestCr4() u64 {
            return (@as(u64, 0) | rdmsr(MSR_VMX_CR4_FIXED0)) & rdmsr(MSR_VMX_CR4_FIXED1);
        }

        // Populate the VMCS host-state area from the live host CPU state. On every
        // VM-exit the CPU loads these, so they MUST be correct or the host faults.
        fn marshalHost() void {
            const gdt = sgdtBase();
            vmwrite(HOST_CR0, readCr0());
            vmwrite(HOST_CR3, readCr3());
            vmwrite(HOST_CR4, readCr4());
            vmwrite(HOST_CS_SEL, readCs() & 0xfff8);
            vmwrite(HOST_SS_SEL, readSs() & 0xfff8);
            vmwrite(HOST_DS_SEL, readDs() & 0xfff8);
            vmwrite(HOST_ES_SEL, readEs() & 0xfff8);
            vmwrite(HOST_FS_SEL, readFs() & 0xfff8);
            vmwrite(HOST_GS_SEL, readGs() & 0xfff8);
            const tr = readTr();
            vmwrite(HOST_TR_SEL, tr & 0xfff8);
            vmwrite(HOST_TR_BASE, descBase(gdt, tr));
            vmwrite(HOST_GDTR_BASE, gdt);
            vmwrite(HOST_IDTR_BASE, sidtBase());
            vmwrite(HOST_FS_BASE, rdmsr(MSR_FS_BASE));
            vmwrite(HOST_GS_BASE, rdmsr(MSR_GS_BASE)); // per-CPU base; preserved
            vmwrite(HOST_EFER, rdmsr(MSR_EFER));
            // HOST_RSP/HOST_RIP are written by the world-switch asm.
        }

        fn marshalControls(self: *Vp) void {
            const pin = if (use_true) MSR_VMX_TRUE_PINBASED_CTLS else MSR_VMX_PINBASED_CTLS;
            const proc = if (use_true) MSR_VMX_TRUE_PROCBASED_CTLS else MSR_VMX_PROCBASED_CTLS;
            const exitc = if (use_true) MSR_VMX_TRUE_EXIT_CTLS else MSR_VMX_EXIT_CTLS;
            const entryc = if (use_true) MSR_VMX_TRUE_ENTRY_CTLS else MSR_VMX_ENTRY_CTLS;
            vmwrite(PIN_CTLS, adjustCtl(pin, PIN_EXTINT_EXITING));
            vmwrite(PROC_CTLS, adjustCtl(proc, PROC_HLT_EXITING | PROC_UNCOND_IO | PROC_SECONDARY));
            vmwrite(PROC_CTLS2, adjustCtl(MSR_VMX_PROCBASED_CTLS2, PROC2_EPT | PROC2_UNRESTRICTED));
            vmwrite(VMEXIT_CTLS, adjustCtl(exitc, EXIT_HOST_ADDR64 | EXIT_SAVE_EFER | EXIT_LOAD_EFER));
            // The CPL3 sandbox runs a 64-bit program -> IA-32e mode guest.
            const entry_want: u32 = if (self.cpl == 3) ENTRY_LOAD_EFER | ENTRY_IA32E else ENTRY_LOAD_EFER;
            vmwrite(VMENTRY_CTLS, adjustCtl(entryc, entry_want));
            // Sandbox: trap #UD/#GP so a CPL3 program's syscall path exits.
            const excbm: u32 = if (self.cpl == 3) (1 << 6) | (1 << 13) else 0;
            vmwrite(EXCEPTION_BITMAP, excbm);
            vmwrite(EPT_POINTER, self.eptp);
            vmwrite(VMCS_LINK_PTR, 0xffff_ffff_ffff_ffff);
        }

        fn marshalGuest(self: *Vp) void {
            const ring3 = self.cpl == 3;
            if (ring3) {
                // 64-bit long mode: PG|PE, PAE, CR3 = identity GVA->GPA table,
                // EFER.LME|LMA. CR0/CR4 still honor the VMX fixed bits.
                vmwrite(GUEST_CR0, (@as(u64, 0x8000_0011) | rdmsr(MSR_VMX_CR0_FIXED0)) & rdmsr(MSR_VMX_CR0_FIXED1));
                vmwrite(GUEST_CR3, self.guest_cr3);
                vmwrite(GUEST_CR4, (@as(u64, 0x20) | rdmsr(MSR_VMX_CR4_FIXED0)) & rdmsr(MSR_VMX_CR4_FIXED1));
                vmwrite(GUEST_EFER, EFER_LME | EFER_LMA);
            } else {
                vmwrite(GUEST_CR0, guestCr0());
                vmwrite(GUEST_CR3, 0);
                vmwrite(GUEST_CR4, guestCr4());
                vmwrite(GUEST_EFER, 0); // 32-bit guest, LMA=0
            }
            vmwrite(GUEST_RFLAGS, self.rflags);
            vmwrite(GUEST_RIP, self.rip);
            vmwrite(GUEST_RSP, self.rsp);
            vmwrite(GUEST_INTERRUPTIBILITY, 0);
            vmwrite(GUEST_ACTIVITY, 0);

            const cs_sel: u64 = if (ring3) 0x1b else 0x08;
            const ds_sel: u64 = if (ring3) 0x23 else 0x10;
            const cs_ar: u64 = if (ring3) AR_CODE64_R3 else AR_CODE32_R0;
            const ds_ar: u64 = if (ring3) AR_DATA32_R3 else AR_DATA32_R0;
            seg(GUEST_CS_SEL, GUEST_CS_BASE, GUEST_CS_LIMIT, GUEST_CS_AR, cs_sel, 0, 0xf_ffff, cs_ar);
            seg(GUEST_SS_SEL, GUEST_SS_BASE, GUEST_SS_LIMIT, GUEST_SS_AR, ds_sel, 0, 0xf_ffff, ds_ar);
            seg(GUEST_DS_SEL, GUEST_DS_BASE, GUEST_DS_LIMIT, GUEST_DS_AR, ds_sel, 0, 0xf_ffff, ds_ar);
            seg(GUEST_ES_SEL, GUEST_ES_BASE, GUEST_ES_LIMIT, GUEST_ES_AR, ds_sel, 0, 0xf_ffff, ds_ar);
            seg(GUEST_FS_SEL, GUEST_FS_BASE, GUEST_FS_LIMIT, GUEST_FS_AR, ds_sel, 0, 0xf_ffff, ds_ar);
            seg(GUEST_GS_SEL, GUEST_GS_BASE, GUEST_GS_LIMIT, GUEST_GS_AR, ds_sel, 0, 0xf_ffff, ds_ar);
            seg(GUEST_TR_SEL, GUEST_TR_BASE, GUEST_TR_LIMIT, GUEST_TR_AR, 0x18, 0, 0x67, AR_TSS32);
            seg(GUEST_LDTR_SEL, GUEST_LDTR_BASE, GUEST_LDTR_LIMIT, GUEST_LDTR_AR, 0, 0, 0, AR_UNUSABLE);
            vmwrite(GUEST_GDTR_BASE, 0);
            vmwrite(GUEST_GDTR_LIMIT, 0xffff);
            vmwrite(GUEST_IDTR_BASE, 0);
            vmwrite(GUEST_IDTR_LIMIT, 0xffff);
        }

        fn seg(sel_f: u64, base_f: u64, lim_f: u64, ar_f: u64, sel: u64, base: u64, lim: u64, ar: u64) void {
            vmwrite(sel_f, sel);
            vmwrite(base_f, base);
            vmwrite(lim_f, lim);
            vmwrite(ar_f, ar);
        }

        // Walk the EPT (stage-2) GPA -> HPA, honoring large pages. An EPT entry
        // is present when any of its low 3 (R/W/X) bits is set; PS = bit 7.
        fn gpaToHpa(self: *const Vp, gpa: u64) ?u64 {
            const p2v = g_p2v.?;
            const AM: u64 = 0x000f_ffff_ffff_f000;
            var t = self.eptp & AM;
            var e = @as([*]u64, @ptrFromInt(p2v(t)))[(gpa >> 39) & 0x1ff];
            if (e & 7 == 0) return null;
            t = e & AM;
            e = @as([*]u64, @ptrFromInt(p2v(t)))[(gpa >> 30) & 0x1ff];
            if (e & 7 == 0) return null;
            if (e & 0x80 != 0) return (e & 0x000f_ffff_c000_0000) | (gpa & 0x3fff_ffff);
            t = e & AM;
            e = @as([*]u64, @ptrFromInt(p2v(t)))[(gpa >> 21) & 0x1ff];
            if (e & 7 == 0) return null;
            if (e & 0x80 != 0) return (e & 0x000f_ffff_ffe0_0000) | (gpa & 0x1f_ffff);
            t = e & AM;
            e = @as([*]u64, @ptrFromInt(p2v(t)))[(gpa >> 12) & 0x1ff];
            if (e & 7 == 0) return null;
            return (e & AM) | (gpa & 0xfff);
        }
        // VMX gives no instruction bytes: read guest memory at the faulting RIP
        // (RIP == GPA for our flat/identity guests).
        fn fetchInsn(self: *const Vp, buf: *[15]u8) usize {
            const hpa = self.gpaToHpa(self.rip) orelse return 0;
            const off = self.rip & 0xfff;
            const cnt: usize = @intCast(@min(@as(u64, 15), 0x1000 - off));
            const src = @as([*]const u8, @ptrFromInt(g_p2v.?(hpa)));
            var k: usize = 0;
            while (k < cnt) : (k += 1) buf[k] = src[k];
            return cnt;
        }
        fn eptViolation(self: *Vp) Exit {
            const gpa = vmread(GUEST_PHYS_ADDR);
            var ib: [15]u8 = undefined;
            const n = self.fetchInsn(&ib);
            if (decodeMov(ib[0..n])) |d| {
                const mask = sizeMask(d.size);
                const data = if (d.imm) |im| im & mask else self.regs[d.reg_idx] & mask;
                self.rip +%= vmread(VMEXIT_INSTR_LEN); // hardware-provided length
                vmwrite(GUEST_RIP, self.rip);
                return .{ .reason = .mmio, .addr = gpa, .size = d.size, .is_write = d.is_write, .reg = d.reg_idx, .data = data, .mcause = VMX_EXIT_EPT_VIOLATION, .htval = gpa };
            }
            return .{ .reason = .fault, .mcause = VMX_EXIT_EPT_VIOLATION, .mtval = vmread(VM_EXIT_QUAL), .htval = gpa, .addr = gpa };
        }

        fn run(self: *Vp) Exit {
            if (self.vmcs_pa == 0) {
                self.vmcs_pa = (g_alloc.?)(1) orelse return .{ .reason = .fault };
                zeroPage(self.vmcs_pa, 0x1000);
                @as(*align(1) u32, @ptrFromInt(g_p2v.?(self.vmcs_pa))).* = vmx_rev;
                vmclear(self.vmcs_pa);
                self.launched = false;
            }
            while (true) {
                vmptrld(self.vmcs_pa);
                self.marshalControls();
                marshalHost();
                self.marshalGuest();
                const failed = vmxEnter(&self.regs, @intFromBool(self.launched));
                if (failed != 0) return .{ .reason = .fault, .mcause = vmread(VM_INSTR_ERROR) };
                self.launched = true;
                self.rip = vmread(GUEST_RIP);
                self.rsp = vmread(GUEST_RSP);
                self.rflags = vmread(GUEST_RFLAGS);
                const reason = vmread(VM_EXIT_REASON) & 0xffff;
                switch (reason) {
                    VMX_EXIT_VMCALL => {
                        self.rip +%= vmread(VMEXIT_INSTR_LEN);
                        vmwrite(GUEST_RIP, self.rip);
                        return .{ .reason = .hypercall, .mcause = reason };
                    },
                    VMX_EXIT_EXCEPTION => {
                        // The sandbox's `syscall` faults #UD (no EFER.SCE); the
                        // instruction is 2 bytes (0F 05).
                        self.rip +%= 2;
                        vmwrite(GUEST_RIP, self.rip);
                        return .{ .reason = .hypercall, .mcause = reason };
                    },
                    VMX_EXIT_HLT, VMX_EXIT_TRIPLE_FAULT => return .{ .reason = .poweroff, .mcause = reason },
                    VMX_EXIT_EXTINT => return .{ .reason = .interrupt, .mcause = reason },
                    VMX_EXIT_IO => {
                        const qual = vmread(VM_EXIT_QUAL);
                        const size: u64 = (qual & 0x7) + 1; // 0->1,1->2,3->4
                        const is_in = (qual & (1 << 3)) != 0;
                        const port: u64 = (qual >> 16) & 0xffff;
                        self.rip +%= vmread(VMEXIT_INSTR_LEN);
                        vmwrite(GUEST_RIP, self.rip);
                        return .{
                            .reason = .mmio,
                            .addr = port,
                            .size = size,
                            .is_write = !is_in,
                            .reg = 0,
                            .data = if (!is_in) (self.regs[0] & ((@as(u64, 1) << @intCast(size * 8)) - 1)) else 0,
                            .mcause = reason,
                        };
                    },
                    VMX_EXIT_EPT_VIOLATION => return self.eptViolation(), // decode -> .mmio, else .fault
                    VMX_EXIT_EPT_MISCONFIG => return .{
                        .reason = .fault,
                        .mcause = reason,
                        .mtval = vmread(VM_EXIT_QUAL),
                        .htval = vmread(GUEST_PHYS_ADDR),
                        .addr = vmread(GUEST_PHYS_ADDR),
                    },
                    else => return .{ .reason = .fault, .mcause = reason, .mtval = vmread(VM_EXIT_QUAL) },
                }
            }
        }
    };

    fn demo(alloc: *const fn (usize) ?u64, p2v: *const fn (u64) usize) void {
        var vm = Ept.init(alloc, p2v) orelse {
            uart.print("[hyp] x86 VMX VM init failed\n", .{});
            return;
        };
        const ram = alloc(1) orelse return;
        @memcpy(@as([*]u8, @ptrFromInt(p2v(ram)))[0..demo_blob.len], &demo_blob);
        const gpa: u64 = 0x10_0000;
        if (!vm.mapPage(gpa, ram, Ept.ram_leaf)) {
            uart.print("[hyp] x86 VMX VM map failed\n", .{});
            return;
        }
        var vcpu: Vp = .{};
        vcpu.setEntry(gpa, vm.tableBase());
        vcpu.rsp = gpa + 0xff0;
        runDemo(&vcpu, "VMX");
    }
};

// One Intel VM entry. Pins regs ptr in rdi + the launched flag in rsi (SysV),
// returns 1 in al if VM entry failed. vmxRun preserves rbx/rbp/r12-r15.
inline fn vmxEnter(regs: [*]u64, launched: u8) u8 {
    return asm volatile ("call vmxRun"
        : [ret] "={al}" (-> u8),
        : [r] "{rdi}" (regs),
          [l] "{rsi}" (launched),
        : .{ .rax = true, .rcx = true, .rdx = true, .rsi = true, .rdi = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .cc = true, .memory = true });
}

export fn vmxRun() callconv(.naked) noreturn {
    asm volatile (
        \\ push %rbp
        \\ push %rbx
        \\ push %r12
        \\ push %r13
        \\ push %r14
        \\ push %r15
        \\ push %rdi                 // [rsp] regs ptr
        \\ // VMWRITE HOST_RSP (current) + HOST_RIP (the exit label below)
        \\ mov $0x6c14, %rax         // HOST_RSP
        \\ vmwrite %rsp, %rax
        \\ lea 1f(%rip), %rdx
        \\ mov $0x6c16, %rax         // HOST_RIP
        \\ vmwrite %rdx, %rax
        \\ // decide vmlaunch vs vmresume (rsi = launched); ZF survives the movs
        \\ test %sil, %sil
        \\ mov 0x00(%rdi), %rax
        \\ mov 0x08(%rdi), %rbx
        \\ mov 0x10(%rdi), %rcx
        \\ mov 0x18(%rdi), %rdx
        \\ mov 0x30(%rdi), %rbp
        \\ mov 0x40(%rdi), %r8
        \\ mov 0x48(%rdi), %r9
        \\ mov 0x50(%rdi), %r10
        \\ mov 0x58(%rdi), %r11
        \\ mov 0x60(%rdi), %r12
        \\ mov 0x68(%rdi), %r13
        \\ mov 0x70(%rdi), %r14
        \\ mov 0x78(%rdi), %r15
        \\ mov 0x20(%rdi), %rsi
        \\ mov 0x28(%rdi), %rdi      // guest rdi last
        \\ jnz 2f                    // launched -> vmresume
        \\ vmlaunch
        \\ jmp 9f                    // VMLAUNCH returned = entry failed
        \\2:
        \\ vmresume
        \\ jmp 9f                    // VMRESUME returned = entry failed
        \\1:                         // HOST_RIP: VM-exit lands here
        \\ push %rax                 // stash guest rax
        \\ mov 8(%rsp), %rax         // regs ptr
        \\ mov %rbx, 0x08(%rax)
        \\ mov %rcx, 0x10(%rax)
        \\ mov %rdx, 0x18(%rax)
        \\ mov %rsi, 0x20(%rax)
        \\ mov %rdi, 0x28(%rax)
        \\ mov %rbp, 0x30(%rax)
        \\ mov %r8,  0x40(%rax)
        \\ mov %r9,  0x48(%rax)
        \\ mov %r10, 0x50(%rax)
        \\ mov %r11, 0x58(%rax)
        \\ mov %r12, 0x60(%rax)
        \\ mov %r13, 0x68(%rax)
        \\ mov %r14, 0x70(%rax)
        \\ mov %r15, 0x78(%rax)
        \\ pop %rdx                  // rdx = guest rax (stashed)
        \\ mov %rdx, 0x00(%rax)
        \\ xor %eax, %eax            // return 0 = VM-exit
        \\ jmp 7f
        \\9:                         // entry failure: guest never ran
        \\ mov $1, %al
        \\7:
        \\ pop %rdi                  // discard regs ptr
        \\ pop %r15
        \\ pop %r14
        \\ pop %r13
        \\ pop %r12
        \\ pop %rbx
        \\ pop %rbp
        \\ ret
    );
}

// Shared in-kernel demo.
// A flat 32-bit guest that prints "x86" via VMMCALL/VMCALL (selector RAX=1,
// char RBX) then HLTs. Hand-assembled: `0F 01 D9` is VMMCALL (AMD); `0F 01 C1`
// is VMCALL (Intel). We pick per vendor below.
const demo_putc = [_]u8{
    0xb8, 0x01, 0x00, 0x00, 0x00, // mov eax, 1
    0xbb, 0x00, 0x00, 0x00, 0x00, // mov ebx, <char> (patched)
};
var demo_blob: [40]u8 = undefined;

fn buildDemoBlob(intel: bool) void {
    const hyper = if (intel) [_]u8{ 0x0f, 0x01, 0xc1 } else [_]u8{ 0x0f, 0x01, 0xd9 };
    const chars = [_]u8{ 'x', '8', '6' };
    var i: usize = 0;
    for (chars) |ch| {
        @memcpy(demo_blob[i .. i + 10], &demo_putc);
        demo_blob[i + 6] = ch; // patch the mov ebx imm32 low byte
        @memcpy(demo_blob[i + 10 .. i + 13], &hyper);
        i += 13;
    }
    demo_blob[i] = 0xf4; // hlt
}

fn runDemo(vcpu: anytype, comptime tag: []const u8) void {
    uart.print("[hyp] booting x86 " ++ tag ++ " guest; console follows:\n[guest] ", .{});
    var guard: u32 = 0;
    while (guard < 100_000) : (guard += 1) {
        const exit = vcpu.run();
        switch (exit.reason) {
            .hypercall => switch (vcpu.reg(0)) {
                1 => uart.print("{c}", .{@as(u8, @truncate(vcpu.reg(1)))}),
                else => {},
            },
            .poweroff => {
                uart.print("\n[hyp] x86 " ++ tag ++ " guest halted (exit 0x{x})\n", .{exit.mcause});
                return;
            },
            else => {
                uart.print("\n[hyp] x86 " ++ tag ++ " guest unexpected exit reason={d} code=0x{x} info=0x{x} gpa=0x{x}\n", .{ @intFromEnum(exit.reason), exit.mcause, exit.mtval, exit.htval });
                return;
            },
        }
    }
}

/// Enable the vendor backend and run the in-kernel guest demo. enable() leaves
/// the facility live for the userspace VMM afterward. No-ops (prints a note) on
/// a CPU without SVM/VMX, e.g. every TCG run.
pub fn hypRunGuestDemo(alloc: *const fn (usize) ?u64, p2v: *const fn (u64) usize) void {
    if (!enable(alloc, p2v)) {
        uart.print("[hyp] x86 hardware virt not available (TCG / unknown vendor); skipping demo\n", .{});
        return;
    }
    switch (vendor) {
        .amd => {
            buildDemoBlob(false);
            Svm.demo(alloc, p2v);
        },
        .intel => {
            buildDemoBlob(true);
            Vmx.demo(alloc, p2v);
        },
        .none => unreachable,
    }
}
