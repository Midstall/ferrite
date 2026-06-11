// Arch-neutral microVM object model for the userspace VMM.
//
// The kernel owns the world-switch and exits back to userspace (KVM model); a
// userspace process (`vmexec`) holds a `.vm` capability, maps guest RAM, and
// loops VCPU_RUN to service exits. This module is the thin glue between the
// syscall layer and the per-arch hypervisor backend (`arch.Vm` + `arch.Vcpu`):
// it allocates guest RAM from the kernel page allocator and drives the
// backend. Today only the riscv64 H-extension backend exists; `available` lets
// the syscalls compile (and cleanly fail) on arches without one.
const std = @import("std");
const arch = @import("arch");
const memory = @import("memory.zig");

/// True when this arch has a hypervisor backend (riscv64 H today).
pub const available = @hasDecl(arch, "Vm") and @hasDecl(arch, "Vcpu");

/// MMIO exit detail, copied out to userspace by SYS_VCPU_MMIO. Layout is the
/// userspace ABI (see zig-std VmMmio).
pub const MmioInfo = extern struct {
    addr: u64,
    data: u64, // value the guest wrote (write); ignored on read
    size: u64, // access width in bytes
    is_write: u64,
    reg: u64, // guest GPR index (so userspace can SET_REG a read result)
};

pub const VmObject = if (available) struct {
    backend: arch.Vm,
    vcpu: arch.Vcpu = .{},
    last_exit: arch.Exit = undefined,

    /// Allocate a VM: its G-stage root comes from the kernel page allocator.
    pub fn create(a: std.mem.Allocator) !*VmObject {
        const self = try a.create(VmObject);
        self.* = .{
            .backend = arch.Vm.init(&memory.allocPages, &memory.physToVirtFn) orelse {
                a.destroy(self);
                return error.OutOfMemory;
            },
        };
        return self;
    }

    /// Back `npages` of guest-physical at `gpa` with fresh contiguous RAM and
    /// map it into the G-stage (V|R|W|X|U|A|D). Returns the host-physical base
    /// so the caller can also map it into the VMM's address space.
    pub fn mapRam(self: *VmObject, gpa: u64, npages: usize) ?u64 {
        const phys = memory.allocPages(npages) orelse return null;
        const ps: u64 = @intCast(memory.pageSize());
        var i: usize = 0;
        while (i < npages) : (i += 1) {
            const off = @as(u64, i) * ps;
            if (!self.backend.mapPage(gpa + off, phys + off, arch.Vm.ram_leaf)) return null;
        }
        return phys;
    }

    pub fn setEntry(self: *VmObject, gpa: u64) void {
        self.vcpu.setEntry(gpa, self.backend.tableBase());
    }

    /// Enter the guest unprivileged, to sandbox a userspace program: aarch64 at
    /// EL0 with HCR_EL2.TGE, riscv64 at VU-mode. A backend that doesn't implement
    /// `setEl0Entry` falls back to a plain (privileged) entry.
    pub fn setEl0Entry(self: *VmObject, gpa: u64, sp: u64) void {
        if (@hasDecl(arch.Vcpu, "setEl0Entry")) {
            self.vcpu.setEl0Entry(gpa, sp, self.backend.tableBase());
        } else {
            self.vcpu.setEntry(gpa, self.backend.tableBase());
        }
    }

    /// One VM entry. Returns when the guest traps out; the exit reason plus the
    /// guest registers are read back by the syscall layer. The exit is cached
    /// for a follow-up SYS_VCPU_MMIO query.
    pub fn run(self: *VmObject) arch.Exit {
        self.last_exit = self.vcpu.run();
        return self.last_exit;
    }

    /// MMIO detail of the most recent exit (valid when reason == .mmio).
    pub fn mmio(self: *const VmObject) MmioInfo {
        const e = self.last_exit;
        return .{
            .addr = e.addr,
            .data = e.data,
            .size = e.size,
            .is_write = if (e.is_write) 1 else 0,
            .reg = e.reg,
        };
    }

    pub fn reg(self: *const VmObject, i: usize) u64 {
        return self.vcpu.reg(i);
    }
    pub fn setReg(self: *VmObject, i: usize, v: u64) void {
        self.vcpu.setReg(i, v);
    }
    pub fn advancePc(self: *VmObject, bytes: u64) void {
        self.vcpu.advancePc(bytes);
    }
} else void;
