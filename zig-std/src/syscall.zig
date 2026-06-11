const std = @import("std");
const builtin = @import("builtin");

pub const SYS_DEBUG_PRINT: usize = 0;
pub const SYS_WRITE_CONSOLE: usize = 1;
pub const SYS_READ_CONSOLE: usize = 2;
pub const SYS_EXIT: usize = 3;
pub const SYS_SIG_STATUS: usize = 4;
pub const SYS_PAGE_SIZE: usize = 5;
pub const SYS_YIELD: usize = 6;
pub const SYS_UNAME: usize = 7;
pub const SYS_MEM_INFO: usize = 8;

pub const SYS_SPAWN: usize = 9;
pub const SYS_EXEC: usize = 10;
pub const SYS_WAIT: usize = 11;
pub const SYS_TRY_WAIT: usize = 12;
pub const SYS_KILL: usize = 13;
pub const SYS_THREAD_SPAWN: usize = 14;

pub const SYS_SEND: usize = 15;
pub const SYS_RECV: usize = 16;
pub const SYS_CHANNEL_CREATE: usize = 17;
pub const SYS_CAP_DUP: usize = 18;
pub const SYS_CAP_RELEASE: usize = 19;
pub const SYS_NS_BIND: usize = 20;
pub const SYS_NS_LOOKUP: usize = 21;

pub const SYS_ALLOC_PAGES: usize = 22;
pub const SYS_DMA_ALLOC: usize = 23;
pub const SYS_MMIO_CREATE: usize = 24;
pub const SYS_MMAP: usize = 25;
pub const SYS_IRQ_CREATE: usize = 26;
pub const SYS_IRQ_LISTEN: usize = 27;
pub const SYS_IRQ_ACK: usize = 28;

pub const SYS_INITRD_READ: usize = 29;
pub const SYS_DTB_READ: usize = 30;
pub const SYS_ACPI_READ: usize = 31;

pub const SYS_TTY_RAW: usize = 32;
pub const SYS_TTY_FG_SET: usize = 33;
pub const SYS_TTY_KILL_FG: usize = 34;

pub const SYS_CLOCK_MONO: usize = 35;

pub const SYS_PROC_LIST: usize = 36;
pub const SYS_KILL_PID: usize = 37;

pub const SYS_GETUID: usize = 38;
pub const SYS_SETUID: usize = 39;
pub const SYS_THREAD_PRIORITY: usize = 40;
pub const SYS_THREAD_DEADLINE: usize = 41;
pub const SYS_PROC_STAT: usize = 42;
pub const SYS_HANDLE_PID: usize = 43;
pub const SYS_CLOCK_BOOT: usize = 44;
pub const SYS_NANOSLEEP: usize = 45;
pub const SYS_PCI_CFG_READ: usize = 46;
pub const SYS_PCI_CFG_WRITE: usize = 47;

pub const SYS_SPAWN_NS: usize = 48;
pub const SYS_FREE_PAGES: usize = 49;
pub const SYS_SETPGID: usize = 50;
pub const SYS_GETPGID: usize = 51;
pub const SYS_SIGNAL: usize = 52;
pub const SYS_SIGACTION: usize = 53;
pub const SYS_SIGRETURN: usize = 54;

pub const SYS_VM_CREATE: usize = 55;
pub const SYS_VM_MAP: usize = 56;
pub const SYS_VCPU_RUN: usize = 57;
pub const SYS_VCPU_SET_REG: usize = 58;
pub const SYS_VCPU_GET_REG: usize = 59;
pub const SYS_VCPU_MMIO: usize = 60;
pub const SYS_VCPU_EL0_ENTRY: usize = 61;

// POSIX signal numbers (default action = terminate; no catchable handlers yet).
pub const SIGINT: u32 = 2;
pub const SIGKILL: u32 = 9;
pub const SIGTERM: u32 = 15;

/// Flags for SYS_SPAWN_NS.
pub const SPAWN_NS_CLEAR: usize = 1 << 0;

pub const PROT_READ: usize = 1;
pub const PROT_WRITE: usize = 2;
pub const PROT_EXEC: usize = 4;

/// bit 0 = enforcing; bits 8..31 = trust-root count.
pub const SigStatus = usize;

pub inline fn isEnforcing(st: SigStatus) bool {
    return (st & 1) != 0;
}

pub inline fn keyCount(st: SigStatus) u32 {
    return @intCast((st >> 8) & 0xFFFFFF);
}

pub fn debugPrint(byte: u8) isize {
    return syscall1(SYS_DEBUG_PRINT, byte);
}

pub fn writeConsole(s: []const u8) isize {
    return syscall2(SYS_WRITE_CONSOLE, @intFromPtr(s.ptr), s.len);
}

pub fn readConsole(buf: []u8) isize {
    return syscall2(SYS_READ_CONSOLE, @intFromPtr(buf.ptr), buf.len);
}

pub fn wait(handle: u32) isize {
    return syscall1(SYS_WAIT, handle);
}

pub fn tryWait(handle: u32) isize {
    return syscall1(SYS_TRY_WAIT, handle);
}

pub fn initrdSize() isize {
    return syscall3(SYS_INITRD_READ, 0, 0, std.math.maxInt(usize));
}

pub fn initrdRead(offset: u64, buf: []u8) isize {
    return syscall3(SYS_INITRD_READ, @intCast(offset), @intFromPtr(buf.ptr), buf.len);
}

pub fn readInitrdFile(name: []const u8, dst: []u8) usize {
    const CPIO_HEADER = 110;
    const S_IFREG: u32 = 0o100000;
    const S_IFMT: u32 = 0o170000;

    var off: u64 = 0;
    while (true) {
        var hdr: [CPIO_HEADER]u8 = undefined;
        if (initrdRead(off, &hdr) != @as(isize, CPIO_HEADER)) return 0;
        if (!std.mem.eql(u8, hdr[0..6], "070701")) return 0;
        const mode: u32 = @intCast(parseHex8(hdr[14..22]) orelse return 0);
        const filesize: u64 = parseHex8(hdr[54..62]) orelse return 0;
        const namesize: u64 = parseHex8(hdr[94..102]) orelse return 0;
        if (namesize == 0) return 0;

        var name_buf: [256]u8 = undefined;
        if (namesize > name_buf.len) return 0;
        const ns: usize = @intCast(namesize);
        if (initrdRead(off + CPIO_HEADER, name_buf[0..ns]) != @as(isize, @intCast(ns))) return 0;
        const entry_name = if (name_buf[ns - 1] == 0) name_buf[0 .. ns - 1] else name_buf[0..ns];

        if (std.mem.eql(u8, entry_name, "TRAILER!!!")) return 0;

        const data_off = alignUp(off + CPIO_HEADER + namesize, 4);
        const next_off = alignUp(data_off + filesize, 4);

        if (std.mem.eql(u8, entry_name, name) and (mode & S_IFMT) == S_IFREG) {
            const want = @min(@as(usize, @intCast(filesize)), dst.len);
            const got = initrdRead(data_off, dst[0..want]);
            return if (got < 0) 0 else @intCast(got);
        }
        off = next_off;
    }
}

pub const InitrdEntry = struct {
    /// Full archive path, e.g. "etc/init.d/40-probe". Points into the caller's
    /// name_buf, so copy it out before the next initrdWalk call.
    name: []const u8,
    size: u64,
    /// Initrd byte offset of the file data; read with initrdRead(data_off, ..).
    data_off: u64,
};

/// Iterates regular files in the initrd cpio. `cursor` starts at 0 and is
/// advanced on each call; pass the same pointer to continue. Non-regular
/// entries (directories) are skipped. Returns null at the archive end or on a
/// malformed header.
pub fn initrdWalk(cursor: *u64, name_buf: []u8) ?InitrdEntry {
    const CPIO_HEADER = 110;
    const S_IFREG: u32 = 0o100000;
    const S_IFMT: u32 = 0o170000;

    while (true) {
        var hdr: [CPIO_HEADER]u8 = undefined;
        if (initrdRead(cursor.*, &hdr) != @as(isize, CPIO_HEADER)) return null;
        if (!std.mem.eql(u8, hdr[0..6], "070701")) return null;
        const mode: u32 = @intCast(parseHex8(hdr[14..22]) orelse return null);
        const filesize: u64 = parseHex8(hdr[54..62]) orelse return null;
        const namesize: u64 = parseHex8(hdr[94..102]) orelse return null;
        if (namesize == 0) return null;

        const data_off = alignUp(cursor.* + CPIO_HEADER + namesize, 4);
        const next_off = alignUp(data_off + filesize, 4);
        const name_off = cursor.* + CPIO_HEADER;
        cursor.* = next_off;

        const ns: usize = @intCast(namesize);
        if (ns > name_buf.len) continue; // name too long for caller buffer; skip
        if (initrdRead(name_off, name_buf[0..ns]) != @as(isize, @intCast(ns))) return null;
        const entry_name = if (name_buf[ns - 1] == 0) name_buf[0 .. ns - 1] else name_buf[0..ns];

        if (std.mem.eql(u8, entry_name, "TRAILER!!!")) return null;
        if ((mode & S_IFMT) != S_IFREG) continue;
        return .{ .name = entry_name, .size = filesize, .data_off = data_off };
    }
}

inline fn alignUp(x: u64, a: u64) u64 {
    return (x + a - 1) & ~(a - 1);
}

fn parseHex8(field: []const u8) ?u64 {
    var v: u64 = 0;
    for (field) |c| {
        const d: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        v = (v << 4) | d;
    }
    return v;
}

pub fn ttyRaw(raw: bool) isize {
    return syscall1(SYS_TTY_RAW, if (raw) 1 else 0);
}

/// Set the console tty's foreground process *group* (pgid). 0 clears it. Ctrl-C
/// delivers SIGINT to the whole group, so a pipeline dies as a unit.
pub fn ttyFgSet(pgid: u32) isize {
    return syscall1(SYS_TTY_FG_SET, pgid);
}

pub fn ttyKillFg() isize {
    return syscall0(SYS_TTY_KILL_FG);
}

/// Set process `pid`'s group (pid=0 -> self, pgid=0 -> pid).
pub fn setpgid(pid: u32, pgid: u32) isize {
    return syscall2(SYS_SETPGID, pid, pgid);
}

/// Get process `pid`'s group (pid=0 -> self).
pub fn getpgid(pid: u32) isize {
    return syscall1(SYS_GETPGID, pid);
}

/// Deliver `sig` to process `pid` (default action = terminate).
pub fn signalPid(pid: u32, sig: u32) isize {
    return syscall2(SYS_SIGNAL, pid, sig);
}

// Return path for a signal handler: after the handler `ret`s, execution lands
// here (the kernel set LR to this), which asks the kernel to restore the
// pre-signal context. aarch64-only delivery for now; the trampoline is harmless
// on other arches (delivery never redirects there).
fn sigreturnTrampoline() callconv(.naked) void {
    if (builtin.cpu.arch == .aarch64) {
        asm volatile (
            \\ mov x8, #54
            \\ svc #0
        );
    } else {
        asm volatile ("");
    }
}

/// Install a catchable handler for `sig` (null = default action = terminate).
/// The handler runs on the interrupted stack and receives the signal number.
pub fn sigaction(sig: u32, handler: ?*const fn (u32) callconv(.c) void) isize {
    const h: usize = if (handler) |f| @intFromPtr(f) else 0;
    return syscall3(SYS_SIGACTION, sig, h, @intFromPtr(&sigreturnTrampoline));
}

pub fn clockMono() u64 {
    var out: u64 = 0;
    _ = syscall1(SYS_CLOCK_MONO, @intFromPtr(&out));
    return out;
}

pub fn clockBoot() u64 {
    var out: u64 = 0;
    _ = syscall1(SYS_CLOCK_BOOT, @intFromPtr(&out));
    return out;
}

pub fn uptimeNs() u64 {
    return clockMono() - clockBoot();
}

/// Tick-granularity (10 ms); sub-tick sleeps round up.
pub fn nanosleep(ns: u64) void {
    const halves = splitU64(ns);
    _ = syscall2(SYS_NANOSLEEP, halves[0], halves[1]);
}

/// Reads `width` bytes (1, 2, or 4) from PCI config space via the kernel.
/// `bdf` packs `(bus << 8) | (dev << 3) | func`. Negative return = error.
/// Only meaningful on x86; other archs reply -bad_num.
pub fn pciCfgRead(bdf: u16, off: u16, width: u32) isize {
    return syscall3(SYS_PCI_CFG_READ, bdf, off, width);
}

pub fn pciCfgWrite(bdf: u16, off: u16, width: u32, value: u32) isize {
    return syscall4(SYS_PCI_CFG_WRITE, bdf, off, width, value);
}

pub const PROC_NAME_MAX: usize = 16;
pub const ProcEntry = extern struct {
    pid: u32,
    state: u32,
    name: [PROC_NAME_MAX]u8,

    pub fn nameSlice(self: *const ProcEntry) []const u8 {
        var len: usize = 0;
        while (len < self.name.len and self.name[len] != 0) : (len += 1) {}
        return self.name[0..len];
    }
};

pub fn procList(entries: []ProcEntry) usize {
    const n = syscall2(SYS_PROC_LIST, @intFromPtr(entries.ptr), entries.len);
    return if (n < 0) 0 else @intCast(n);
}

pub fn killPid(pid: u32) isize {
    return syscall1(SYS_KILL_PID, pid);
}

pub fn getUid() u32 {
    return @intCast(syscall0(SYS_GETUID));
}

pub fn setUid(target: u32) isize {
    return syscall1(SYS_SETUID, target);
}

pub const Priority = enum(u32) {
    rt_high = 0,
    rt_mid = 1,
    rt_low = 2,
    high = 3,
    normal = 4,
    low = 5,
    background = 6,
    idle = 7,
};

pub fn setThreadPriority(p: Priority) isize {
    return syscall1(SYS_THREAD_PRIORITY, @intFromEnum(p));
}

pub fn setThreadDeadline(deadline_ns: u64) isize {
    const halves = splitU64(deadline_ns);
    return syscall2(SYS_THREAD_DEADLINE, halves[0], halves[1]);
}

/// Matches kernel `ProcStat` layout.
pub const ProcStat = extern struct {
    pid: u32,
    uid: u32,
    state: u32,
    num_threads: u32,
    user_cpu_ns: u64,
    sys_cpu_ns: u64,
    rss_bytes: u64,
    kstack_bytes: u64,
    kmem_bytes: u64,
    priority: u8,
    _pad: [7]u8,
    name: [PROC_NAME_MAX]u8,

    pub fn nameSlice(self: *const ProcStat) []const u8 {
        var len: usize = 0;
        while (len < self.name.len and self.name[len] != 0) : (len += 1) {}
        return self.name[0..len];
    }

    pub fn totalCpuNs(self: *const ProcStat) u64 {
        return self.user_cpu_ns + self.sys_cpu_ns;
    }
};

/// Pid 0 means current process.
pub fn procStat(pid: u32, out: *ProcStat) isize {
    return syscall2(SYS_PROC_STAT, pid, @intFromPtr(out));
}

pub fn handlePid(handle: u32) isize {
    return syscall1(SYS_HANDLE_PID, handle);
}

pub fn dtbSize() isize {
    return syscall3(SYS_DTB_READ, 0, 0, std.math.maxInt(usize));
}

pub fn dtbRead(offset: u64, buf: []u8) isize {
    return syscall3(SYS_DTB_READ, @intCast(offset), @intFromPtr(buf.ptr), buf.len);
}

pub const UnameInfo = extern struct {
    name: [16]u8,
    version: [16]u8,
    arch: [16]u8,

    pub fn fieldSlice(self: *const UnameInfo, comptime field: []const u8) []const u8 {
        const b = &@field(self, field);
        var len: usize = 0;
        while (len < b.len and b[len] != 0) : (len += 1) {}
        return b[0..len];
    }
};

pub fn uname(out: *UnameInfo) isize {
    return syscall1(SYS_UNAME, @intFromPtr(out));
}

pub const MemInfo = extern struct {
    total_bytes: u64,
    free_bytes: u64,
};

pub fn memInfo(out: *MemInfo) isize {
    return syscall1(SYS_MEM_INFO, @intFromPtr(out));
}

pub fn acpiSize() isize {
    return syscall3(SYS_ACPI_READ, 0, 0, std.math.maxInt(usize));
}

pub fn acpiRead(offset: u64, buf: []u8) isize {
    return syscall3(SYS_ACPI_READ, @intCast(offset), @intFromPtr(buf.ptr), buf.len);
}

pub fn dmaAlloc(npages: usize, out_va: *usize, out_pa: *u64) isize {
    return syscall3(SYS_DMA_ALLOC, npages, @intFromPtr(out_va), @intFromPtr(out_pa));
}

pub fn allocPages(npages: usize, out_va: *usize) isize {
    return syscall2(SYS_ALLOC_PAGES, npages, @intFromPtr(out_va));
}

/// VM exit reasons returned by vcpuRun (mirrors the kernel's ExitReason).
pub const VmExit = enum(isize) {
    hypercall = 0, // guest SBI (riscv) / HVC (aarch64): a7/a0 carry the call
    fault = 1, // unhandled guest exception: a7 = cause, a0 = fault addr
    interrupt = 2, // a host interrupt fired during the guest
    mmio = 3, // guest device access; query details via vcpuMmio (aarch64)
    poweroff = 4, // guest asked to power off (aarch64 PSCI)
};

/// MMIO exit detail, filled by vcpuMmio after a `.mmio` exit.
pub const VmMmio = extern struct {
    addr: u64, // guest-physical device address
    data: u64, // value the guest wrote (writes only)
    size: u64, // access width in bytes
    is_write: u64, // 1 = store, 0 = load
    reg: u64, // guest GPR index (SET_REG it to satisfy a load)
};

/// Create a microVM and set its single vCPU's entry point. Returns a `.vm`
/// capability handle (negative = error). riscv64 with the H extension only.
pub fn vmCreate(entry_gpa: u64) isize {
    return syscall1(SYS_VM_CREATE, @intCast(entry_gpa));
}

/// Back `npages` of guest-physical RAM at `gpa`, mapped into the guest's
/// G-stage and into this process; *out_va receives the address to load into.
pub fn vmMap(vm: u32, gpa: u64, npages: usize, out_va: *usize) isize {
    return syscall4(SYS_VM_MAP, vm, @intCast(gpa), npages, @intFromPtr(out_va));
}

/// Run the vCPU until it traps out. On an SBI exit, *out_a7/*out_a0 carry the
/// guest a7/a0 and the kernel has stepped past the ecall; on a fault they carry
/// mcause/mtval. The return value is a VmExit (negative = error).
pub fn vcpuRun(vm: u32, out_a7: *usize, out_a0: *usize) isize {
    return syscall3(SYS_VCPU_RUN, vm, @intFromPtr(out_a7), @intFromPtr(out_a0));
}

/// Set guest GPR `idx` (x0..x31). Use for boot registers and SBI returns.
pub fn vcpuSetReg(vm: u32, idx: usize, val: u64) isize {
    return syscall3(SYS_VCPU_SET_REG, vm, idx, @intCast(val));
}

/// Read guest GPR `idx` (x0..x31) into *out.
pub fn vcpuGetReg(vm: u32, idx: usize, out: *usize) isize {
    return syscall3(SYS_VCPU_GET_REG, vm, idx, @intFromPtr(out));
}

/// Fetch the most recent exit's MMIO detail (valid after a `.mmio` exit).
pub fn vcpuMmio(vm: u32, out: *VmMmio) isize {
    return syscall2(SYS_VCPU_MMIO, vm, @intFromPtr(out));
}

/// Configure the vCPU to enter the guest unprivileged (aarch64 EL0+TGE / riscv64
/// VU-mode), so a sandboxed program's syscalls trap straight to the hypervisor.
/// `entry`/`sp` are guest-physical.
pub fn vcpuEl0Entry(vm: u32, entry: u64, sp: u64) isize {
    return syscall3(SYS_VCPU_EL0_ENTRY, vm, @intCast(entry), @intCast(sp));
}

// RISC-V GPR indices used by the SBI ABI.
pub const REG_A0: usize = 10;
pub const REG_A1: usize = 11;
pub const REG_A2: usize = 12;
pub const REG_A6: usize = 16;
pub const REG_A7: usize = 17;

/// Return a region previously obtained from allocPages/dmaAlloc/mmap to
/// the kernel. The va MUST be the base of the original mapping.
pub fn freePages(va: usize) isize {
    return syscall1(SYS_FREE_PAGES, va);
}

pub fn pageSize() usize {
    return @intCast(syscall0(SYS_PAGE_SIZE));
}

pub fn capRelease(handle: u32) isize {
    return syscall1(SYS_CAP_RELEASE, handle);
}

pub fn yield() void {
    _ = syscall0(SYS_YIELD);
}

pub fn exec(buf: []const u8, args: []const u8) isize {
    return execStdio(buf, args, null);
}

/// Like `exec` but binds the child's stdin/stdout/stderr to the given channel
/// handles (a `[3]u32` of {stdin_recv, stdout_send, stderr_send}; 0 = console).
pub fn execStdio(buf: []const u8, args: []const u8, stdio: ?*const [3]u32) isize {
    return syscall5(
        SYS_EXEC,
        @intFromPtr(buf.ptr),
        buf.len,
        if (args.len == 0) 0 else @intFromPtr(args.ptr),
        args.len,
        if (stdio) |s| @intFromPtr(s) else 0,
    );
}

pub fn send(handle: u32, buf: []const u8, xfer_handle: u32) isize {
    return syscall4(SYS_SEND, handle, @intFromPtr(buf.ptr), buf.len, xfer_handle);
}

pub fn recv(handle: u32, out: []u8, cap_out: ?*u32) isize {
    return syscall3(SYS_RECV, handle, @intFromPtr(out.ptr), if (cap_out) |p| @intFromPtr(p) else 0);
}

/// Wraps the new out-param ABI in the legacy `(recv << 32) | send` packed
/// i64 so existing callers using `@truncate` to extract handles still work.
/// Negative return = error (preserved old contract).
pub fn channelCreate(capacity: usize) i64 {
    var out: [2]u32 = .{ 0, 0 };
    const status = syscall2(SYS_CHANNEL_CREATE, capacity, @intFromPtr(&out));
    if (status < 0) return @intCast(status);
    return @bitCast((@as(u64, out[1]) << 32) | @as(u64, out[0]));
}

pub fn nsBind(name: []const u8, handle: u32) isize {
    return syscall3(SYS_NS_BIND, @intFromPtr(name.ptr), name.len, handle);
}

pub fn nsLookup(name: []const u8) isize {
    return syscall2(SYS_NS_LOOKUP, @intFromPtr(name.ptr), name.len);
}

pub fn capDup(handle: u32) isize {
    return syscall1(SYS_CAP_DUP, handle);
}

pub fn exit(code: usize) noreturn {
    _ = syscall1(SYS_EXIT, code);
    unreachable;
}

pub fn sigStatus() SigStatus {
    return @bitCast(syscall0(SYS_SIG_STATUS));
}

pub fn spawn(path: []const u8) isize {
    return spawnArgs(path, &.{});
}

pub fn spawnArgs(path: []const u8, args: []const u8) isize {
    return spawnArgsStdio(path, args, null);
}

/// Like `spawnArgs` but binds the child's stdin/stdout/stderr to the given
/// channel handles (a `[3]u32` of {stdin_recv, stdout_send, stderr_send};
/// 0 = inherit the console default).
pub fn spawnArgsStdio(path: []const u8, args: []const u8, stdio: ?*const [3]u32) isize {
    return syscall5(
        SYS_SPAWN,
        @intFromPtr(path.ptr),
        path.len,
        if (args.len == 0) 0 else @intFromPtr(args.ptr),
        args.len,
        if (stdio) |s| @intFromPtr(s) else 0,
    );
}

/// Create a byte-stream pipe (a kernel channel). Returns the read (recv) and
/// write (send) handles. `capacity` is the message buffer depth (1..16).
pub const Pipe = struct { read: u32, write: u32 };
pub fn pipe(capacity: usize) ?Pipe {
    const packed_h = channelCreate(capacity);
    if (packed_h < 0) return null;
    const u: u64 = @bitCast(packed_h);
    return .{ .write = @truncate(u), .read = @truncate(u >> 32) };
}

/// Like `spawnArgs` but controls how the child's namespace + caps are
/// derived from the parent's. `flags` is a bitmask of SPAWN_NS_*.
pub fn spawnNs(path: []const u8, args: []const u8, flags: usize) isize {
    return syscall5(
        SYS_SPAWN_NS,
        @intFromPtr(path.ptr),
        path.len,
        if (args.len == 0) 0 else @intFromPtr(args.ptr),
        args.len,
        flags,
    );
}

pub fn threadSpawn(entry: usize, stack: usize) isize {
    return syscall2(SYS_THREAD_SPAWN, entry, stack);
}

pub fn kill(handle: u32) isize {
    return syscall1(SYS_KILL, handle);
}

pub fn mmioCreate(phys: u64, len: usize) isize {
    const h = splitU64(phys);
    return syscall3(SYS_MMIO_CREATE, h[0], h[1], len);
}

pub fn mmap(handle: u32, prot: usize) isize {
    return syscall2(SYS_MMAP, handle, prot);
}

pub fn irqCreate(irq_num: u32) isize {
    return syscall1(SYS_IRQ_CREATE, irq_num);
}

pub fn irqListen(irq_handle: u32) isize {
    return syscall2(SYS_IRQ_LISTEN, irq_handle, 0);
}

pub fn irqAck(irq_handle: u32) isize {
    return syscall1(SYS_IRQ_ACK, irq_handle);
}

// Per-arch syscall ABI (kernel-side handlers documented in
// kernel/src/arch/<arch>/{syscall_entry.S, isr.S, traps*.zig}):
//   aarch64:        svc #0,  num=x8,  args=x0..x5,  ret=x0
//   riscv32/riscv64:ecall,   num=a7,  args=a0..a5,  ret=a0
//   x86_64:         syscall, num=rax, args=rdi/rsi/rdx/r10/r8/r9, ret=rax (clobbers rcx, r11)
//   x86:            int 0x80,num=eax, args=ebx/ecx/edx/esi/edi/ebp, ret=eax
//
// Args are usize (native register width); return is isize. For 64-bit values
// on i386, callers split into (lo, hi) usizes - see splitU64 / joinI64.

pub inline fn splitU64(v: u64) struct { usize, usize } {
    if (@sizeOf(usize) >= 8) return .{ @as(usize, @intCast(v)), 0 };
    return .{ @as(usize, @truncate(v)), @as(usize, @truncate(v >> 32)) };
}

inline fn syscall0(num: usize) isize {
    return switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("svc #0"
            : [ret] "={x0}" (-> isize),
            : [num] "{x8}" (num),
            : .{ .memory = true }),
        .riscv32, .riscv64 => asm volatile ("ecall"
            : [ret] "={x10}" (-> isize),
            : [num] "{x17}" (num),
            : .{ .memory = true }),
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> isize),
            : [num] "{rax}" (num),
            : .{ .memory = true, .rcx = true, .r11 = true }),
        .x86 => asm volatile ("int $0x80"
            : [ret] "={eax}" (-> isize),
            : [num] "{eax}" (num),
            : .{ .memory = true }),
        else => @compileError("ferrite syscall: unsupported arch"),
    };
}

inline fn syscall1(num: usize, a0: usize) isize {
    return switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("svc #0"
            : [ret] "={x0}" (-> isize),
            : [num] "{x8}" (num),
              [a0] "{x0}" (a0),
            : .{ .memory = true }),
        .riscv32, .riscv64 => asm volatile ("ecall"
            : [ret] "={x10}" (-> isize),
            : [num] "{x17}" (num),
              [a0] "{x10}" (a0),
            : .{ .memory = true }),
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> isize),
            : [num] "{rax}" (num),
              [a0] "{rdi}" (a0),
            : .{ .memory = true, .rcx = true, .r11 = true }),
        .x86 => asm volatile ("int $0x80"
            : [ret] "={eax}" (-> isize),
            : [num] "{eax}" (num),
              [a0] "{ebx}" (a0),
            : .{ .memory = true }),
        else => @compileError("ferrite syscall: unsupported arch"),
    };
}

inline fn syscall2(num: usize, a0: usize, a1: usize) isize {
    return switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("svc #0"
            : [ret] "={x0}" (-> isize),
            : [num] "{x8}" (num),
              [a0] "{x0}" (a0),
              [a1] "{x1}" (a1),
            : .{ .memory = true }),
        .riscv32, .riscv64 => asm volatile ("ecall"
            : [ret] "={x10}" (-> isize),
            : [num] "{x17}" (num),
              [a0] "{x10}" (a0),
              [a1] "{x11}" (a1),
            : .{ .memory = true }),
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> isize),
            : [num] "{rax}" (num),
              [a0] "{rdi}" (a0),
              [a1] "{rsi}" (a1),
            : .{ .memory = true, .rcx = true, .r11 = true }),
        .x86 => asm volatile ("int $0x80"
            : [ret] "={eax}" (-> isize),
            : [num] "{eax}" (num),
              [a0] "{ebx}" (a0),
              [a1] "{ecx}" (a1),
            : .{ .memory = true }),
        else => @compileError("ferrite syscall: unsupported arch"),
    };
}

inline fn syscall3(num: usize, a0: usize, a1: usize, a2: usize) isize {
    return switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("svc #0"
            : [ret] "={x0}" (-> isize),
            : [num] "{x8}" (num),
              [a0] "{x0}" (a0),
              [a1] "{x1}" (a1),
              [a2] "{x2}" (a2),
            : .{ .memory = true }),
        .riscv32, .riscv64 => asm volatile ("ecall"
            : [ret] "={x10}" (-> isize),
            : [num] "{x17}" (num),
              [a0] "{x10}" (a0),
              [a1] "{x11}" (a1),
              [a2] "{x12}" (a2),
            : .{ .memory = true }),
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> isize),
            : [num] "{rax}" (num),
              [a0] "{rdi}" (a0),
              [a1] "{rsi}" (a1),
              [a2] "{rdx}" (a2),
            : .{ .memory = true, .rcx = true, .r11 = true }),
        .x86 => asm volatile ("int $0x80"
            : [ret] "={eax}" (-> isize),
            : [num] "{eax}" (num),
              [a0] "{ebx}" (a0),
              [a1] "{ecx}" (a1),
              [a2] "{edx}" (a2),
            : .{ .memory = true }),
        else => @compileError("ferrite syscall: unsupported arch"),
    };
}

inline fn syscall4(num: usize, a0: usize, a1: usize, a2: usize, a3: usize) isize {
    return switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("svc #0"
            : [ret] "={x0}" (-> isize),
            : [num] "{x8}" (num),
              [a0] "{x0}" (a0),
              [a1] "{x1}" (a1),
              [a2] "{x2}" (a2),
              [a3] "{x3}" (a3),
            : .{ .memory = true }),
        .riscv32, .riscv64 => asm volatile ("ecall"
            : [ret] "={x10}" (-> isize),
            : [num] "{x17}" (num),
              [a0] "{x10}" (a0),
              [a1] "{x11}" (a1),
              [a2] "{x12}" (a2),
              [a3] "{x13}" (a3),
            : .{ .memory = true }),
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> isize),
            : [num] "{rax}" (num),
              [a0] "{rdi}" (a0),
              [a1] "{rsi}" (a1),
              [a2] "{rdx}" (a2),
              [a3] "{r10}" (a3),
            : .{ .memory = true, .rcx = true, .r11 = true }),
        .x86 => asm volatile ("int $0x80"
            : [ret] "={eax}" (-> isize),
            : [num] "{eax}" (num),
              [a0] "{ebx}" (a0),
              [a1] "{ecx}" (a1),
              [a2] "{edx}" (a2),
              [a3] "{esi}" (a3),
            : .{ .memory = true }),
        else => @compileError("ferrite syscall: unsupported arch"),
    };
}

inline fn syscall5(num: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
    return switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("svc #0"
            : [ret] "={x0}" (-> isize),
            : [num] "{x8}" (num),
              [a0] "{x0}" (a0),
              [a1] "{x1}" (a1),
              [a2] "{x2}" (a2),
              [a3] "{x3}" (a3),
              [a4] "{x4}" (a4),
            : .{ .memory = true }),
        .riscv32, .riscv64 => asm volatile ("ecall"
            : [ret] "={x10}" (-> isize),
            : [num] "{x17}" (num),
              [a0] "{x10}" (a0),
              [a1] "{x11}" (a1),
              [a2] "{x12}" (a2),
              [a3] "{x13}" (a3),
              [a4] "{x14}" (a4),
            : .{ .memory = true }),
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> isize),
            : [num] "{rax}" (num),
              [a0] "{rdi}" (a0),
              [a1] "{rsi}" (a1),
              [a2] "{rdx}" (a2),
              [a3] "{r10}" (a3),
              [a4] "{r8}" (a4),
            : .{ .memory = true, .rcx = true, .r11 = true }),
        .x86 => asm volatile ("int $0x80"
            : [ret] "={eax}" (-> isize),
            : [num] "{eax}" (num),
              [a0] "{ebx}" (a0),
              [a1] "{ecx}" (a1),
              [a2] "{edx}" (a2),
              [a3] "{esi}" (a3),
              [a4] "{edi}" (a4),
            : .{ .memory = true }),
        else => @compileError("ferrite syscall: unsupported arch"),
    };
}
