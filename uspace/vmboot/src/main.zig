// vmboot, a userspace virtual machine monitor (boot a whole guest, like QEMU).
//
//   vmboot <kernel> [initrd]
//
// Loads a flat guest kernel (and optional initrd) from the filesystem into guest
// RAM, then runs it via the KVM-style microVM syscalls (#231). The kernel owns
// the world-switch; vmboot loads the images, seeds the boot registers, and
// services the guest's SBI/MMIO calls, relaying the guest's serial console to
// its own stdout/stdin (the tty vmboot was given). riscv64 with the H extension
// (SBI guest) and aarch64 under -Dhyp (PL011/PSCI guest).
//
// To sandbox a single Ferrite program inside a VM instead of booting a whole
// guest kernel, use `vmexec`.
//
// Guest boot ABI (flat image, our convention until DTB support lands):
//   pc = a1 entry = GUEST_BASE; a0 = hartid (0); a1 = initrd GPA (0 if none);
//   a2 = initrd size. The guest reads its initrd straight from a1.
const std = @import("std");
const builtin = @import("builtin");
const ferrite = std.os.ferrite;
const sys = ferrite.syscall;

pub const panic = ferrite.panic;

// Guest RAM base IPA. Matches each arch's conventional RAM base so it lands in
// the stage-2/VTCR-configured address range (riscv virt = 0x80000000; aarch64
// virt = 0x40000000).
const GUEST_BASE: u64 = if (builtin.cpu.arch == .riscv64) 0x8000_0000 else 0x4000_0000;
const INITRD_OFF: u64 = 0x0020_0000; // 2 MiB in, leaves room for the kernel
const PAGE: usize = 4096;
const MAX_PAGES: usize = 4096; // kernel caps a single VM_MAP at 16 MiB

// SBI extension IDs we recognise.
const SBI_PUTCHAR: usize = 0x01; // legacy console_putchar (a0 = char)
const SBI_GETCHAR: usize = 0x02; // legacy console_getchar
const SBI_SHUTDOWN: usize = 0x08; // legacy shutdown
const SBI_BASE: usize = 0x10; // base extension
const SBI_DBCN: usize = 0x4442434E; // "DBCN" debug console
const SBI_SRST: usize = 0x53525354; // "SRST" system reset

fn writeByte(c: u8) void {
    ferrite.writeStdout(&[_]u8{c});
}

/// Load a file into host buffer `dst`, returning the byte count (or null).
fn loadFile(path: []const u8, dst: []u8) ?usize {
    var uri_buf: [256]u8 = undefined;
    const uri = ferrite.fs.resolvePath(path, &uri_buf) catch return null;
    const file = ferrite.fs.open(uri, .{ .mode = .read }) catch return null;
    defer file.close();
    var off: u64 = 0;
    while (off < dst.len) {
        const n = file.read(off, dst[@intCast(off)..]) catch return null;
        if (n == 0) break;
        off += n;
    }
    return @intCast(off);
}

pub fn main() void {
    const argv = ferrite.argv;
    if (argv.len < 2) {
        ferrite.console.print("usage: vmboot <kernel> [initrd]\n", .{}) catch {};
        return;
    }
    const kernel_path = std.mem.span(argv[1]);
    const initrd_path: ?[]const u8 = if (argv.len >= 3) std.mem.span(argv[2]) else null;

    const vm = sys.vmCreate(GUEST_BASE);
    if (vm < 0) {
        ferrite.console.print("vmboot: vm_create failed ({d}); needs riscv64 H\n", .{vm}) catch {};
        return;
    }
    const vmh: u32 = @intCast(vm);

    // Map a single region of guest RAM covering kernel + (optional) initrd.
    const ram_pages = MAX_PAGES; // 16 MiB; generous for a flat demo guest
    var ram_va: usize = 0;
    if (sys.vmMap(vmh, GUEST_BASE, ram_pages, &ram_va) < 0) {
        ferrite.console.print("vmboot: vm_map failed (RAM too fragmented?)\n", .{}) catch {};
        return;
    }
    const ram: [*]u8 = @ptrFromInt(ram_va);
    const ram_len = ram_pages * PAGE;

    // Load the kernel at GUEST_BASE.
    const ksize = loadFile(kernel_path, ram[0..ram_len]) orelse {
        ferrite.console.print("vmboot: cannot read kernel '{s}'\n", .{kernel_path}) catch {};
        return;
    };

    // Load the initrd at GUEST_BASE + INITRD_OFF, if given.
    var initrd_gpa: u64 = 0;
    var initrd_size: u64 = 0;
    if (initrd_path) |ip| {
        const n = loadFile(ip, ram[@intCast(INITRD_OFF)..ram_len]) orelse {
            ferrite.console.print("vmboot: cannot read initrd '{s}'\n", .{ip}) catch {};
            return;
        };
        initrd_gpa = GUEST_BASE + INITRD_OFF;
        initrd_size = n;
    }

    // Seed the boot registers per the arch's boot protocol.
    if (builtin.cpu.arch == .riscv64) {
        // a0 = hartid, a1 = initrd GPA, a2 = initrd size.
        _ = sys.vcpuSetReg(vmh, sys.REG_A0, 0);
        _ = sys.vcpuSetReg(vmh, sys.REG_A1, initrd_gpa);
        _ = sys.vcpuSetReg(vmh, sys.REG_A2, initrd_size);
    } else {
        // aarch64: x0 = initrd/DTB GPA (our flat guest reads its initrd from x0).
        _ = sys.vcpuSetReg(vmh, 0, initrd_gpa);
    }

    ferrite.console.print("vmboot: booting '{s}' ({d} bytes){s} ...\n", .{
        kernel_path,
        ksize,
        if (initrd_size > 0) " with initrd" else "",
    }) catch {};

    runGuest(vmh, ram, ram_len);
}

fn getReg(vmh: u32, idx: usize) usize {
    var v: usize = 0;
    _ = sys.vcpuGetReg(vmh, idx, &v);
    return v;
}

// Translate a guest-physical address to a pointer into our mapped RAM, bounds
// checked against the mapped window.
fn guestPtr(ram: [*]u8, ram_len: usize, gpa: u64, len: usize) ?[]u8 {
    if (gpa < GUEST_BASE) return null;
    const off = gpa - GUEST_BASE;
    if (off + len > ram_len) return null;
    return ram[@intCast(off)..][0..len];
}

fn runGuest(vmh: u32, ram: [*]u8, ram_len: usize) void {
    while (true) {
        var a7: usize = 0;
        var a0: usize = 0;
        const r = sys.vcpuRun(vmh, &a7, &a0);
        if (r < 0) {
            ferrite.console.print("\nvmboot: vcpu_run error {d}\n", .{r}) catch {};
            return;
        }
        switch (@as(sys.VmExit, @enumFromInt(r))) {
            .fault => {
                ferrite.console.print("\nvmboot: guest fault mcause=0x{x} mtval=0x{x}\n", .{ a7, a0 }) catch {};
                return;
            },
            .interrupt => {}, // host tick during the guest; just re-enter
            .poweroff => {
                ferrite.console.print("\nvmboot: guest powered off\n", .{}) catch {};
                return;
            },
            .mmio => if (!serviceMmio(vmh, ram, ram_len)) return,
            .hypercall => if (!serviceSbi(vmh, ram, ram_len, a7, a0)) return,
        }
    }
}

// aarch64 guest console: a PL011 UART the hypervisor traps as MMIO.
const UART_BASE: u64 = 0x0900_0000;

/// Handle one MMIO exit (aarch64). Relays UART transmit to the tty and keeps
/// the guest's console driver happy on reads. Returns false to stop the VM.
fn serviceMmio(vmh: u32, ram: [*]u8, ram_len: usize) bool {
    _ = ram;
    _ = ram_len;
    var m: sys.VmMmio = undefined;
    if (sys.vcpuMmio(vmh, &m) < 0) return true;
    if (m.addr >= UART_BASE and m.addr < UART_BASE + 0x1000) {
        const off = m.addr - UART_BASE;
        if (m.is_write != 0) {
            if (off == 0x00) writeByte(@truncate(m.data)); // UARTDR: transmit
        } else if (m.reg < 31) { // 31 == xzr, no destination
            const v: u64 = switch (off) {
                0x18 => 0x90, // UARTFR: TXFE|RXFE -> "ready to TX, nothing to RX"
                else => 0,
            };
            _ = sys.vcpuSetReg(vmh, m.reg, v);
        }
    } else if (m.is_write == 0 and m.reg < 31) {
        _ = sys.vcpuSetReg(vmh, m.reg, 0); // unmapped device: reads as zero
    }
    return true;
}

/// Handle one SBI call. Returns false when the guest has asked to shut down.
fn serviceSbi(vmh: u32, ram: [*]u8, ram_len: usize, a7: usize, a0: usize) bool {
    switch (a7) {
        SBI_PUTCHAR => writeByte(@truncate(a0)),
        SBI_GETCHAR => {
            var b: [1]u8 = undefined;
            const n = ferrite.readStdin(&b);
            // a0 = the byte, or -1 when no input is available.
            _ = sys.vcpuSetReg(vmh, sys.REG_A0, if (n == 1) @as(u64, b[0]) else @bitCast(@as(i64, -1)));
        },
        SBI_SHUTDOWN => {
            ferrite.console.print("\nvmboot: guest halted (legacy shutdown)\n", .{}) catch {};
            return false;
        },
        SBI_DBCN => {
            const fid = getReg(vmh, sys.REG_A6);
            switch (fid) {
                0 => { // console_write(num=a0, addr_lo=a1, addr_hi=a2)
                    const len = a0;
                    const gpa = (@as(u64, getReg(vmh, sys.REG_A2)) << 32) | getReg(vmh, sys.REG_A1);
                    if (guestPtr(ram, ram_len, gpa, len)) |buf| {
                        ferrite.writeStdout(buf);
                        _ = sys.vcpuSetReg(vmh, sys.REG_A0, 0); // SBI_SUCCESS
                        _ = sys.vcpuSetReg(vmh, sys.REG_A1, len);
                    } else {
                        _ = sys.vcpuSetReg(vmh, sys.REG_A0, @bitCast(@as(i64, -3))); // SBI_ERR_INVALID_PARAM
                    }
                },
                2 => writeByte(@truncate(a0)), // console_write_byte
                else => _ = sys.vcpuSetReg(vmh, sys.REG_A0, @bitCast(@as(i64, -2))), // NOT_SUPPORTED
            }
        },
        SBI_BASE => {
            const fid = getReg(vmh, sys.REG_A6);
            var value: u64 = 0;
            switch (fid) {
                0 => value = 2, // get_spec_version -> 0.2
                3 => { // probe_extension(ext id in a0)
                    value = switch (a0) {
                        SBI_PUTCHAR, SBI_GETCHAR, SBI_SHUTDOWN, SBI_DBCN, SBI_SRST => 1,
                        else => 0,
                    };
                },
                else => {}, // impl id/version/mvendorid/... -> 0
            }
            _ = sys.vcpuSetReg(vmh, sys.REG_A0, 0); // SBI_SUCCESS
            _ = sys.vcpuSetReg(vmh, sys.REG_A1, value);
        },
        SBI_SRST => {
            ferrite.console.print("\nvmboot: guest requested system reset\n", .{}) catch {};
            return false;
        },
        else => {
            // Unknown extension: report NOT_SUPPORTED and let the guest cope.
            _ = sys.vcpuSetReg(vmh, sys.REG_A0, @bitCast(@as(i64, -2)));
        },
    }
    return true;
}
