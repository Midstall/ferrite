const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch");
const aspace = @import("aspace.zig");
const cap = @import("cap.zig");
const console = @import("console.zig");
const cpu = @import("cpu.zig");
const acpi = @import("acpi.zig");
const dtb = @import("dtb.zig");
const heap = @import("heap.zig");
const initrd = @import("initrd.zig");
const ipc = @import("ipc.zig");
const irq_mod = @import("irq.zig");
const memory = @import("memory.zig");
const loader = @import("loader.zig");
const process = @import("process.zig");
const sched = @import("sched.zig");
const signature = @import("signature.zig");
const thread = @import("thread.zig");
const timer_mod = @import("timer.zig");

pub const Errno = enum(isize) {
    ok = 0,
    bad_num = -1,
    bad_handle = -2,
    bad_arg = -3,
    no_mem = -4,
    closed = -5,
    no_process = -6,
    not_found = -7,
    denied = -8,
    bad_image = -9,
};

inline fn err(e: Errno) isize {
    return @intFromEnum(e);
}

// --- info / I/O on the kernel itself (0..8) ---
pub const SYS_DEBUG_PRINT: usize = 0;
pub const SYS_WRITE_CONSOLE: usize = 1;
pub const SYS_READ_CONSOLE: usize = 2;
pub const SYS_EXIT: usize = 3;
pub const SYS_SIG_STATUS: usize = 4;
pub const SYS_PAGE_SIZE: usize = 5;
pub const SYS_YIELD: usize = 6;
pub const SYS_UNAME: usize = 7;
pub const SYS_MEM_INFO: usize = 8;

// --- process / thread management (9..14) ---
pub const SYS_SPAWN: usize = 9;
pub const SYS_EXEC: usize = 10;
pub const SYS_WAIT: usize = 11;
pub const SYS_TRY_WAIT: usize = 12;
pub const SYS_KILL: usize = 13;
pub const SYS_THREAD_SPAWN: usize = 14;

// --- IPC, caps, and namespace (15..21) ---
pub const SYS_SEND: usize = 15;
pub const SYS_RECV: usize = 16;
pub const SYS_CHANNEL_CREATE: usize = 17;
pub const SYS_CAP_DUP: usize = 18;
pub const SYS_CAP_RELEASE: usize = 19;
pub const SYS_NS_BIND: usize = 20;
pub const SYS_NS_LOOKUP: usize = 21;

// --- memory + IRQ (22..28) ---
pub const SYS_ALLOC_PAGES: usize = 22;
pub const SYS_DMA_ALLOC: usize = 23;
pub const SYS_MMIO_CREATE: usize = 24;
pub const SYS_MMAP: usize = 25;
pub const SYS_IRQ_CREATE: usize = 26;
pub const SYS_IRQ_LISTEN: usize = 27;
pub const SYS_IRQ_ACK: usize = 28;

// --- firmware blob reads (29..31) ---
// All three share the `(buf=NULL, len=u64.max)` size-query sentinel.
pub const SYS_INITRD_READ: usize = 29;
pub const SYS_DTB_READ: usize = 30;
pub const SYS_ACPI_READ: usize = 31;

// --- TTY foreground-process slot (32..34) ---
pub const SYS_TTY_RAW: usize = 32;
pub const SYS_TTY_FG_SET: usize = 33;
pub const SYS_TTY_KILL_FG: usize = 34;

// --- Clocks (35) ---
pub const SYS_CLOCK_MONO: usize = 35;

// --- Process introspection (36..37) ---
pub const SYS_PROC_LIST: usize = 36;
pub const SYS_KILL_PID: usize = 37;

// --- User identity (38..39) ---
pub const SYS_GETUID: usize = 38;
pub const SYS_SETUID: usize = 39;

// --- Scheduling (40..41) ---
pub const SYS_THREAD_PRIORITY: usize = 40;
pub const SYS_THREAD_DEADLINE: usize = 41;

// --- Process accounting (42..43) ---
pub const SYS_PROC_STAT: usize = 42;
pub const SYS_HANDLE_PID: usize = 43;

// --- Clocks + timers (44..45) ---
pub const SYS_CLOCK_BOOT: usize = 44;
pub const SYS_NANOSLEEP: usize = 45;

// --- PCI config IO ports (x86 only; arch.pci returns null elsewhere) (46..47) ---
pub const SYS_PCI_CFG_READ: usize = 46;
pub const SYS_PCI_CFG_WRITE: usize = 47;

pub const SYS_SPAWN_NS: usize = 48;

// --- Memory return path (49) ---
//
// SYS_FREE_PAGES returns a previously-allocated region (SYS_ALLOC_PAGES /
// SYS_DMA_ALLOC / SYS_MMAP) back to the kernel. The va must match the
// base of an existing region; partial unmaps aren't supported.
pub const SYS_FREE_PAGES: usize = 49;

// --- POSIX process model: groups + signals (50..52) ---
// SETPGID(pid, pgid): set process pid's group (pid=0 -> self, pgid=0 -> pid).
// GETPGID(pid): return pid's pgid (pid=0 -> self).
// SIGNAL(pid, sig): deliver sig to process pid (default action = terminate).
pub const SYS_SETPGID: usize = 50;
pub const SYS_GETPGID: usize = 51;
pub const SYS_SIGNAL: usize = 52;
// SIGACTION(sig, handler_va, restorer_va): install a catchable handler (handler
// 0 = default/terminate). SIGRETURN: handled specially in the EL0 trap path
// (restores the sigframe); the generic dispatch entry is a safety no-op.
pub const SYS_SIGACTION: usize = 53;
pub const SYS_SIGRETURN: usize = 54;

pub const SPAWN_NS_CLEAR: usize = 1 << 0;

pub const PROT_READ: usize = 1;
pub const PROT_WRITE: usize = 2;
pub const PROT_EXEC: usize = 4;

pub fn init() void {
    arch.traps.syscall_handler = &dispatch;
}

pub fn dispatch(num: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, _: usize) callconv(.c) isize {
    if (cpu.current()) |t_in| {
        t_in.sys_in_ns = arch.timer.now();
    }

    const ret: isize = switch (num) {
        SYS_DEBUG_PRINT => sysDebugPrint(a0),
        SYS_WRITE_CONSOLE => sysWriteConsole(a0, a1),
        SYS_SEND => sysSend(@truncate(a0), a1, a2, @truncate(a3)),
        SYS_RECV => sysRecv(@truncate(a0), a1, a2),
        SYS_EXIT => sysExit(a0),
        SYS_SIG_STATUS => sysSigStatus(),
        SYS_SPAWN => sysSpawn(a0, a1, a2, a3, a4),
        SYS_THREAD_SPAWN => sysThreadSpawn(a0, a1),
        SYS_KILL => sysKill(@truncate(a0)),
        SYS_MMIO_CREATE => sysMmioCreate(a0, a1, a2),
        SYS_MMAP => sysMmap(@truncate(a0), a1),
        SYS_IRQ_CREATE => sysIrqCreate(@truncate(a0)),
        SYS_IRQ_LISTEN => sysIrqListen(@truncate(a0), @truncate(a1)),
        SYS_IRQ_ACK => sysIrqAck(@truncate(a0)),
        SYS_CHANNEL_CREATE => sysChannelCreate(a0, a1),
        SYS_NS_BIND => sysNsBind(a0, a1, @truncate(a2)),
        SYS_NS_LOOKUP => sysNsLookup(a0, a1),
        SYS_CAP_DUP => sysCapDup(@truncate(a0)),
        SYS_READ_CONSOLE => sysReadConsole(a0, a1),
        SYS_WAIT => sysWait(@truncate(a0)),
        SYS_DMA_ALLOC => sysDmaAlloc(a0, a1, a2),
        SYS_PAGE_SIZE => sysPageSize(),
        SYS_CAP_RELEASE => sysCapRelease(@truncate(a0)),
        SYS_YIELD => {
            sched.yield();
            return err(.ok);
        },
        SYS_EXEC => sysExec(a0, a1, a2, a3, a4),
        SYS_ALLOC_PAGES => sysAllocPages(a0, a1),
        SYS_TRY_WAIT => sysTryWait(@truncate(a0)),
        SYS_INITRD_READ => sysInitrdRead(a0, a1, a2),
        SYS_TTY_RAW => sysTtyRaw(a0),
        SYS_TTY_FG_SET => sysTtyFgSet(a0),
        SYS_TTY_KILL_FG => sysTtyKillFg(),
        SYS_DTB_READ => sysDtbRead(a0, a1, a2),
        SYS_UNAME => sysUname(a0),
        SYS_MEM_INFO => sysMemInfo(a0),
        SYS_ACPI_READ => sysAcpiRead(a0, a1, a2),
        SYS_CLOCK_MONO => sysClockMono(a0),
        SYS_PROC_LIST => sysProcList(a0, a1),
        SYS_KILL_PID => sysKillPid(@truncate(a0)),
        SYS_GETUID => sysGetUid(),
        SYS_SETUID => sysSetUid(@truncate(a0)),
        SYS_THREAD_PRIORITY => sysThreadPriority(@truncate(a0)),
        SYS_THREAD_DEADLINE => sysThreadDeadline(a0, a1),
        SYS_PROC_STAT => sysProcStat(@truncate(a0), a1),
        SYS_HANDLE_PID => sysHandlePid(@truncate(a0)),
        SYS_CLOCK_BOOT => sysClockBoot(a0),
        SYS_NANOSLEEP => sysNanosleep(a0, a1),
        SYS_PCI_CFG_READ => sysPciCfgRead(a0, a1, a2),
        SYS_PCI_CFG_WRITE => sysPciCfgWrite(a0, a1, a2, a3),
        SYS_SPAWN_NS => sysSpawnNs(a0, a1, a2, a3, a4),
        SYS_FREE_PAGES => sysFreePages(a0),
        SYS_SETPGID => sysSetPgid(@truncate(a0), @truncate(a1)),
        SYS_GETPGID => sysGetPgid(@truncate(a0)),
        SYS_SIGNAL => sysSignal(@truncate(a0), @truncate(a1)),
        SYS_SIGACTION => sysSigaction(@truncate(a0), a1, a2),
        SYS_SIGRETURN => err(.ok), // normally intercepted in the EL0 trap path
        else => err(.bad_num),
    };

    // Reap cross-CPU kills before returning to userspace.
    if (cpu.current()) |t| {
        if (@atomicLoad(u32, &t.die_requested, .acquire) != 0) sched.exit();
        if (t.sys_in_ns != 0) {
            // This path runs with IRQs enabled, so the timer IRQ's chargeAndArm
            // can set t.sys_in_ns = now_irq mid-expression. Snapshot once into a
            // local so the `>` compare and the subtraction use the SAME value;
            // re-reading t.sys_in_ns let chargeAndArm bump it between guard and
            // subtract, underflowing into an integer-overflow panic (seen under
            // KVM, where real-rate timer IRQs hit the window).
            const now = arch.timer.now();
            const in_ns = t.sys_in_ns;
            t.sys_in_ns = 0; // clear first so a preempting chargeAndArm skips, no double-charge
            if (now > in_ns) t.sys_cpu_ns += now - in_ns;
        }
    }
    return ret;
}

// --- helpers for u64 user-out writes (split into two usizes on i386) ---

/// Resolves `va` against the current process's page table to a kernel-side
/// pointer. M-mode riscv64 runs paging-off, so the kernel can't dereference
/// user VAs directly and must translate. Other arches' kernels share the
/// user PT but still benefit from the bounds-check.
inline fn userPtr(comptime T: type, va: usize) ?*T {
    if (va == 0) return null;
    if (kernel_shares_user_pt) return @ptrFromInt(va);
    const proc = currentProcess() orelse return null;
    const page_size: usize = @intCast(memory.pageSize());
    const page_va = va & ~(page_size - 1);
    const off = va - page_va;
    // Crosses-page accesses for our tiny out-params aren't expected; reject.
    if (off + @sizeOf(T) > page_size) return null;
    const pa = arch.mmu.userTableTranslate(&proc.aspace.table, page_va) orelse return null;
    return @ptrFromInt(memory.physToVirt(pa) + off);
}

/// Copies up to `dst.len` bytes from user VA `va` into `dst`. Returns the
/// kernel-side slice of bytes successfully read. Walks page boundaries so
/// the caller can pass any length. On M-mode kernels (riscv64 raw) this is
/// the ONLY safe way to read user buffers from the kernel.
fn userBytes(va: usize, dst: []u8) ?[]u8 {
    if (va == 0 or dst.len == 0) return null;
    if (kernel_shares_user_pt) {
        const src: [*]const u8 = @ptrFromInt(va);
        @memcpy(dst, src[0..dst.len]);
        return dst;
    }
    const proc = currentProcess() orelse return null;
    const page_size: usize = @intCast(memory.pageSize());
    var off: usize = 0;
    while (off < dst.len) {
        const cur = va + off;
        const page_va = cur & ~(page_size - 1);
        const page_off = cur - page_va;
        const chunk = @min(dst.len - off, page_size - page_off);
        const pa = arch.mmu.userTableTranslate(&proc.aspace.table, page_va) orelse return null;
        const src: [*]const u8 = @ptrFromInt(memory.physToVirt(pa) + page_off);
        @memcpy(dst[off..][0..chunk], src[0..chunk]);
        off += chunk;
    }
    return dst[0..off];
}

/// Copies `src` to user VA `va`, walking pages. Returns true on success.
/// Used for kernel-to-user writes that can't go through a direct user-VA
/// pointer deref on M-mode riscv64.
fn writeUserBytes(va: usize, src: []const u8) bool {
    if (va == 0) return src.len == 0;
    if (src.len == 0) return true;
    if (kernel_shares_user_pt) {
        const dst: [*]u8 = @ptrFromInt(va);
        @memcpy(dst[0..src.len], src);
        return true;
    }
    const proc = currentProcess() orelse return false;
    const page_size: usize = @intCast(memory.pageSize());
    var off: usize = 0;
    while (off < src.len) {
        const cur = va + off;
        const page_va = cur & ~(page_size - 1);
        const page_off = cur - page_va;
        const chunk = @min(src.len - off, page_size - page_off);
        const pa = arch.mmu.userTableTranslate(&proc.aspace.table, page_va) orelse return false;
        const dst: [*]u8 = @ptrFromInt(memory.physToVirt(pa) + page_off);
        @memcpy(dst[0..chunk], src[off..][0..chunk]);
        off += chunk;
    }
    return true;
}

inline fn writeUserU64(out_va: usize, value: u64) isize {
    const dst = userPtr(u64, out_va) orelse return err(.bad_arg);
    dst.* = value;
    return err(.ok);
}

/// Use this for out-params declared `*usize` on the user side. Writing
/// 8 bytes into a 4-byte i386 slot smears into the caller's next stack
/// slot (typically the saved return address).
inline fn writeUserUsize(out_va: usize, value: u64) isize {
    if (@sizeOf(usize) == 8) {
        return writeUserU64(out_va, value);
    } else {
        const dst = userPtr(u32, out_va) orelse return err(.bad_arg);
        dst.* = @truncate(value);
        return err(.ok);
    }
}

inline fn readUserU64(in_lo_va: usize, in_hi_va: usize) u64 {
    // ABI: 64-bit args are passed as two usizes (low half + high half) on
    // 32-bit ISAs. On 64-bit ISAs the low arg carries the full value and
    // high is ignored (caller passes 0). Encode uniformly to keep dispatch
    // free of arch ifdefs.
    return @as(u64, in_lo_va) | (@as(u64, in_hi_va) << 32);
}

// --- handlers ---

fn sysDebugPrint(byte: usize) isize {
    const b: u8 = @truncate(byte);
    const buf: [1]u8 = .{b};
    arch.uart.write(&buf);
    return err(.ok);
}

fn sysWriteConsole(buf_va: usize, len: usize) isize {
    if (len > 4096) return err(.bad_arg);
    var kbuf: [4096]u8 = undefined;
    const bytes = userBytes(buf_va, kbuf[0..len]) orelse return err(.bad_arg);
    arch.uart.write(bytes);
    return err(.ok);
}

fn sysReadConsole(buf_va: usize, len: usize) isize {
    if (len == 0) return 0;
    if (len > 4096) return err(.bad_arg);
    var kbuf: [4096]u8 = undefined;
    const n = console.read(kbuf[0..len]);
    if (n > 0 and !writeUserBytes(buf_va, kbuf[0..n])) return err(.bad_arg);
    return @intCast(n);
}

fn sysSend(handle: cap.Handle, payload_va: usize, payload_len: usize, xfer_handle: cap.Handle) isize {
    if (payload_len > ipc.MAX_INLINE) return err(.bad_arg);
    const proc = currentProcess() orelse return err(.no_process);

    const ent = proc.cap_table.get(handle, .channel_send) catch return err(.bad_handle);
    const ch: *ipc.Channel = @ptrCast(@alignCast(ent.object orelse return err(.bad_handle)));

    var msg: ipc.Message = .{
        .payload = undefined,
        .payload_len = @intCast(payload_len),
        .cap_xfer = null,
    };
    if (payload_len != 0) {
        _ = userBytes(payload_va, msg.payload[0..@intCast(payload_len)]) orelse return err(.bad_arg);
    }

    // Cap ref moves into the message; sysRecv's mintNoRef consumes it.
    if (xfer_handle != cap.NULL_HANDLE) {
        if (xfer_handle >= proc.cap_table.entries.len) return err(.bad_handle);
        const xfer_slot = &proc.cap_table.entries[xfer_handle];
        if (xfer_slot.kind == .null) return err(.bad_handle);
        if (!xfer_slot.rights.grant) return err(.denied);
        msg.cap_xfer = .{
            .kind = xfer_slot.kind,
            .rights = xfer_slot.rights,
            .object = xfer_slot.object,
        };
        proc.cap_table.clearNoUnref(xfer_handle);
    }

    ch.send(msg) catch |e| return switch (e) {
        error.Closed => err(.closed),
        error.OutOfMemory => err(.no_mem),
    };
    return err(.ok);
}

fn sysRecv(handle: cap.Handle, out_va: usize, out_cap_va: usize) isize {
    const proc = currentProcess() orelse return err(.no_process);

    const ent = proc.cap_table.get(handle, .channel_recv) catch return err(.bad_handle);
    const ch: *ipc.Channel = @ptrCast(@alignCast(ent.object orelse return err(.bad_handle)));

    const msg = ch.recv() catch |e| return switch (e) {
        error.Closed => err(.closed),
        error.OutOfMemory => err(.no_mem),
    };

    if (msg.payload_len != 0 and out_va != 0) {
        if (!writeUserBytes(out_va, msg.payload[0..msg.payload_len])) return err(.bad_arg);
    }

    if (msg.cap_xfer) |xf| {
        if (out_cap_va != 0) {
            const new_handle = proc.cap_table.mintNoRef(xf.kind, xf.rights, xf.object) catch blk: {
                cap.Table.dropTransferred(xf.kind, xf.object);
                break :blk @as(u32, cap.NULL_HANDLE);
            };
            const cap_dst = userPtr(u32, out_cap_va) orelse return err(.bad_arg);
            cap_dst.* = new_handle;
        } else {
            cap.Table.dropTransferred(xf.kind, xf.object);
        }
    } else if (out_cap_va != 0) {
        const cap_dst = userPtr(u32, out_cap_va) orelse return err(.bad_arg);
        cap_dst.* = cap.NULL_HANDLE;
    }

    return @intCast(msg.payload_len);
}

fn sysExit(code: usize) isize {
    if (currentProcess()) |proc| proc.exit_code = @intCast(code & 0xFF);
    sched.exit();
}

/// Bit 0 = 1 if enforcing, 0 if warning; bits [31:8] = trust root count.
fn sysSigStatus() isize {
    const status_bit: u64 = if (signature.status == .enforcing) 1 else 0;
    const count: u64 = @intCast(signature.keyCount() & 0xFFFFFF);
    return @intCast(status_bit | (count << 8));
}

// Scratch buffers for sysSpawn/sysSpawnNs arg copies. Global, not on the kernel
// stack ([4096] there overflowed the spawn->loader->crypto chain and corrupted
// an adjacent thread's stack). Safe while spawns are serialized; when SMP
// work-stealing is re-enabled these must become per-CPU so two cores spawning
// concurrently don't clobber each other. See ferrite-smp memory.
var spawn_path_buf: [256]u8 = undefined;
var spawn_args_buf: [4096]u8 = undefined;

// Bind a child's stdin/stdout/stderr from a parent-supplied [3]u32 of channel
// handles (0 = leave unset -> child falls back to the console). stdin is a recv
// end, stdout/stderr are send ends. Each cap is minted into the child + bound in
// its namespace under "stdin"/"stdout"/"stderr" (zig-std resolves them lazily).
fn applyStdio(parent: *process.Process, child: *process.Process, stdio_va: usize) void {
    if (stdio_va == 0) return;
    var caps: [3]u32 = .{ 0, 0, 0 };
    _ = userBytes(stdio_va, std.mem.asBytes(&caps)) orelse return;
    const names = [_][]const u8{ "stdin", "stdout", "stderr" };
    const kinds = [_]cap.Kind{ .channel_recv, .channel_send, .channel_send };
    inline for (0..3) |i| {
        if (caps[i] != 0) {
            if (parent.cap_table.get(caps[i], kinds[i])) |ent| {
                if (child.cap_table.mint(ent.kind, ent.rights, ent.object)) |nh| {
                    child.namespace.bind(names[i], nh) catch {};
                } else |_| {}
            } else |_| {}
        }
    }
}

// ABI: (a0,a1)=path slice, (a2,a3)=NUL-separated args appended after argv[0]=path,
// a4 = optional user pointer to [3]u32 stdin/stdout/stderr channel handles.
fn sysSpawn(path_va: usize, path_len: usize, args_va: usize, args_len: usize, stdio_va: usize) isize {
    if (path_len == 0 or path_len > spawn_path_buf.len) return err(.bad_arg);
    if (args_len > spawn_args_buf.len) return err(.bad_arg);
    const parent = currentProcess() orelse return err(.no_process);
    if (!parent.authority.spawn) return err(.denied);

    const path = userBytes(path_va, spawn_path_buf[0..path_len]) orelse return err(.bad_arg);

    const rec = (initrd.find(path) catch return err(.bad_arg)) orelse return err(.not_found);

    var argv_buf: [64][]const u8 = undefined;
    argv_buf[0] = path;
    var argc: usize = 1;
    if (args_va != 0 and args_len > 0) {
        const args = userBytes(args_va, spawn_args_buf[0..args_len]) orelse return err(.bad_arg);
        var start: usize = 0;
        var i: usize = 0;
        while (i < args.len and argc < argv_buf.len) : (i += 1) {
            if (args[i] == 0) {
                if (i > start) {
                    argv_buf[argc] = args[start..i];
                    argc += 1;
                }
                start = i + 1;
            }
        }
        if (start < args.len and argc < argv_buf.len) {
            argv_buf[argc] = args[start..args.len];
            argc += 1;
        }
    }

    const loaded = loader.load(rec.data, parent, argv_buf[0..argc]) catch |e| return switch (e) {
        error.OutOfMemory => err(.no_mem),
        error.SigRejected => err(.denied),
        else => err(.bad_image),
    };
    applyStdio(parent, loaded.proc, stdio_va);
    sched.add(loaded.thread); // start only after stdio is bound

    const handle = parent.cap_table.mint(.process, .{ .read = true }, @ptrCast(loaded.proc)) catch
        return err(.no_mem);
    return @intCast(handle);
}

fn sysSpawnNs(path_va: usize, path_len: usize, args_va: usize, args_len: usize, flags: usize) isize {
    if (path_len == 0 or path_len > spawn_path_buf.len) return err(.bad_arg);
    if (args_len > spawn_args_buf.len) return err(.bad_arg);
    const parent = currentProcess() orelse return err(.no_process);
    if (!parent.authority.spawn) return err(.denied);

    const path = userBytes(path_va, spawn_path_buf[0..path_len]) orelse return err(.bad_arg);
    const rec = (initrd.find(path) catch return err(.bad_arg)) orelse return err(.not_found);

    var argv_buf: [64][]const u8 = undefined;
    argv_buf[0] = path;
    var argc: usize = 1;
    if (args_va != 0 and args_len > 0) {
        const args = userBytes(args_va, spawn_args_buf[0..args_len]) orelse return err(.bad_arg);
        var start: usize = 0;
        var i: usize = 0;
        while (i < args.len and argc < argv_buf.len) : (i += 1) {
            if (args[i] == 0) {
                if (i > start) {
                    argv_buf[argc] = args[start..i];
                    argc += 1;
                }
                start = i + 1;
            }
        }
        if (start < args.len and argc < argv_buf.len) {
            argv_buf[argc] = args[start..args.len];
            argc += 1;
        }
    }

    const opts: loader.LoadOpts = .{
        .clone_namespace = (flags & SPAWN_NS_CLEAR) == 0,
    };
    const loaded = loader.loadWith(rec.data, parent, argv_buf[0..argc], opts) catch |e| return switch (e) {
        error.OutOfMemory => err(.no_mem),
        error.SigRejected => err(.denied),
        else => err(.bad_image),
    };
    sched.add(loaded.thread);

    const handle = parent.cap_table.mint(.process, .{ .read = true }, @ptrCast(loaded.proc)) catch
        return err(.no_mem);
    return @intCast(handle);
}

// ABI: (a0,a1)=image bytes, (a2,a3)=NUL-separated argv tail,
// a4 = optional user pointer to [3]u32 stdin/stdout/stderr channel handles.
fn sysExec(buf_va: usize, buf_len: usize, args_va: usize, args_len: usize, stdio_va: usize) isize {
    if (buf_len == 0 or buf_len > 64 * 1024 * 1024) return err(.bad_arg);
    if (args_len > 4096) return err(.bad_arg);
    const parent = currentProcess() orelse return err(.no_process);
    if (!parent.authority.spawn) return err(.denied);

    const buf_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(buf_va)));
    const buf = buf_ptr[0..@intCast(buf_len)];

    var argv_buf: [64][]const u8 = undefined;
    var argc: usize = 0;
    if (args_va != 0 and args_len > 0) {
        const args: [*]const u8 = @ptrFromInt(@as(usize, @intCast(args_va)));
        var start: usize = 0;
        var i: usize = 0;
        while (i < args_len and argc < argv_buf.len) : (i += 1) {
            if (args[i] == 0) {
                if (i > start) {
                    argv_buf[argc] = args[start..i];
                    argc += 1;
                }
                start = i + 1;
            }
        }
        if (start < args_len and argc < argv_buf.len) {
            argv_buf[argc] = args[start..@intCast(args_len)];
            argc += 1;
        }
    }

    const loaded = loader.load(buf, parent, argv_buf[0..argc]) catch |e| return switch (e) {
        error.OutOfMemory => err(.no_mem),
        error.SigRejected => err(.denied),
        else => err(.bad_image),
    };
    applyStdio(parent, loaded.proc, stdio_va);
    sched.add(loaded.thread); // start only after stdio is bound

    const handle = parent.cap_table.mint(.process, .{ .read = true }, @ptrCast(loaded.proc)) catch
        return err(.no_mem);
    return @intCast(handle);
}

/// Caller must have mapped entry_va and stack_va USER-RW already.
fn sysThreadSpawn(entry_va: usize, stack_va: usize) isize {
    const proc = currentProcess() orelse return err(.no_process);
    if (entry_va < @import("aspace.zig").USER_VA_BASE) return err(.bad_arg);
    if (stack_va == 0) return err(.bad_arg);

    const t = proc.spawnUser(entry_va, stack_va) catch |e| return switch (e) {
        error.OutOfMemory => err(.no_mem),
        error.ArchUnsupported => err(.bad_arg),
    };
    sched.add(t);

    const handle = proc.cap_table.mint(.thread, .{ .read = true }, @ptrCast(t)) catch
        return err(.no_mem);
    return @intCast(handle);
}

fn sysKill(handle: cap.Handle) isize {
    const proc = currentProcess() orelse return err(.no_process);
    const ent = proc.cap_table.get(handle, .thread) catch |first| {
        if (first == error.WrongKind) {
            const pent = proc.cap_table.get(handle, .process) catch return err(.bad_handle);
            const target_proc: *process.Process = @ptrCast(@alignCast(pent.object orelse return err(.bad_handle)));
            target_proc.kill();
            return err(.ok);
        }
        return err(.bad_handle);
    };
    const target: *thread.Thread = @ptrCast(@alignCast(ent.object orelse return err(.bad_handle)));

    const me = cpu.current() orelse return err(.no_process);
    if (target == me) {
        sched.exit();
    }
    _ = sched.killOther(target);
    return err(.ok);
}

fn sysWait(handle: cap.Handle) isize {
    const me_proc = currentProcess() orelse return err(.no_process);
    const ent = me_proc.cap_table.get(handle, .process) catch return err(.bad_handle);
    const target: *process.Process = @ptrCast(@alignCast(ent.object orelse return err(.bad_handle)));
    // Lock-protect the read-exited / add-waiter / block sequence so a
    // concurrent notifyThreadExit can't drop our wake. blockReleasing
    // commits state=.blocked then releases the lock atomically.
    target.wait_lock.acquire();
    if (target.exited) {
        target.wait_lock.release();
    } else {
        const t = cpu.current() orelse {
            target.wait_lock.release();
            return err(.no_process);
        };
        target.addWaiter(t);
        sched.blockReleasing(&target.wait_lock);
    }
    // Report signal death as 128+sig (shell $? convention); else the exit code.
    // Keeps the small-int wait ABI intact for existing callers.
    const status: i32 = if (target.term_signal != 0)
        @intCast(128 + target.term_signal)
    else
        target.exit_code;
    me_proc.cap_table.revoke(handle);
    target.destroy();
    return @intCast(status);
}

fn sysTryWait(handle: cap.Handle) isize {
    const me_proc = currentProcess() orelse return err(.no_process);
    const ent = me_proc.cap_table.get(handle, .process) catch return err(.bad_handle);
    const target: *process.Process = @ptrCast(@alignCast(ent.object orelse return err(.bad_handle)));
    return if (target.exited) 1 else 0;
}

fn sysMmioCreate(phys_lo: usize, phys_hi: usize, len: usize) isize {
    const proc = currentProcess() orelse return err(.no_process);
    if (!proc.authority.mmio_map) return err(.denied);
    const phys = readUserU64(phys_lo, phys_hi);
    const ps = memory.pageSize();
    if (len == 0 or (phys & (ps - 1)) != 0 or (len & (ps - 1)) != 0) return err(.bad_arg);

    const region = heap.allocator().create(aspace.MemRegion) catch return err(.no_mem);
    region.* = .{ .phys = phys, .len = len, .device = true };

    const rights: cap.Rights = .{ .read = true, .write = true, .map = true, .grant = true };
    const handle = proc.cap_table.mint(.mem_region, rights, @ptrCast(region)) catch {
        heap.allocator().destroy(region);
        return err(.no_mem);
    };
    return @intCast(handle);
}

fn sysMmap(handle: cap.Handle, prot_bits: usize) isize {
    const proc = currentProcess() orelse return err(.no_process);
    const ent = proc.cap_table.get(handle, .mem_region) catch return err(.bad_handle);
    if (!ent.rights.map) return err(.denied);
    const region: *aspace.MemRegion = @ptrCast(@alignCast(ent.object orelse return err(.bad_handle)));

    const p: aspace.Prot = .{
        .read = (prot_bits & PROT_READ) != 0,
        .write = (prot_bits & PROT_WRITE) != 0,
        .execute = (prot_bits & PROT_EXEC) != 0,
        .user = true,
    };
    const va = proc.aspace.mmap(region, p) catch |e| return switch (e) {
        error.OutOfMemory => err(.no_mem),
        error.BadAlignment => err(.bad_arg),
        else => err(.bad_arg),
    };
    return @intCast(va);
}

fn sysPageSize() isize {
    return @intCast(memory.pageSize());
}

fn sysCapRelease(handle: cap.Handle) isize {
    const proc = currentProcess() orelse return err(.no_process);
    proc.cap_table.revoke(handle);
    return err(.ok);
}

fn sysTtyRaw(raw: usize) isize {
    arch.uart.rx_echo = (raw == 0);
    return err(.ok);
}

// ABI change: arg is now a process-GROUP id (pgid), not a process handle. 0
// clears the foreground group. Ctrl-C signals the whole group, so a pipeline
// dies as a unit. The shell passes each pipeline's leader pid (== its pgid).
fn sysTtyFgSet(pgid: usize) isize {
    console.setForegroundGroup(@truncate(pgid));
    return err(.ok);
}

fn sysTtyKillFg() isize {
    console.killForeground();
    return err(.ok);
}

fn sysInitrdRead(offset: usize, buf_va: usize, len: usize) isize {
    return rawBlobRead(initrd.rawImage(), offset, buf_va, len);
}

fn sysDtbRead(offset: usize, buf_va: usize, len: usize) isize {
    return rawBlobRead(dtb.rawImage(), offset, buf_va, len);
}

// Sentinel `buf_va == 0 and len == usize.max` returns the total size.
// usize.max (not u64.max) because i386 truncates u64 args to u32 in the
// syscall ABI, so a userspace u64.max becomes u32.max in the kernel.
inline fn rawBlobRead(blob: ?[]const u8, offset: u64, buf_va: u64, len: u64) isize {
    const SIZE_SENTINEL: u64 = std.math.maxInt(usize);
    const bytes = blob orelse {
        if (buf_va == 0 and len == SIZE_SENTINEL) return 0;
        return err(.not_found);
    };
    if (buf_va == 0 and len == SIZE_SENTINEL) return @intCast(bytes.len);
    if (buf_va == 0) return err(.bad_arg);
    if (offset >= bytes.len) return 0;
    const remaining = bytes.len - @as(usize, @intCast(offset));
    const n = @min(remaining, @as(usize, @intCast(len)));
    if (n == 0) return 0;
    if (!writeUserBytes(@intCast(buf_va), bytes[@intCast(offset)..][0..n])) return err(.bad_arg);
    return @intCast(n);
}

/// True when the kernel can directly dereference user VAs (i.e. it runs in a
/// privilege mode that walks the user PT for loads/stores). False only for
/// M-mode riscv64 (raw boot), where the kernel runs paging-off and must
/// translate via userTableTranslate to read/write user memory.
const kernel_shares_user_pt = !@hasDecl(arch.mmu, "kernel_translates_user");

pub const UnameInfo = extern struct {
    name: [16]u8,
    version: [16]u8,
    arch: [16]u8,
};

const KERNEL_NAME = "Ferrite";
const KERNEL_VERSION = "0.1.0";

fn sysUname(buf_va: usize) isize {
    if (buf_va == 0) return err(.bad_arg);
    var info: UnameInfo = .{
        .name = @splat(0),
        .version = @splat(0),
        .arch = @splat(0),
    };
    @memcpy(info.name[0..KERNEL_NAME.len], KERNEL_NAME);
    @memcpy(info.version[0..KERNEL_VERSION.len], KERNEL_VERSION);
    const arch_tag = @tagName(builtin.target.cpu.arch);
    const an = @min(arch_tag.len, info.arch.len);
    @memcpy(info.arch[0..an], arch_tag[0..an]);
    const dst: *UnameInfo = @ptrFromInt(@as(usize, @intCast(buf_va)));
    dst.* = info;
    return err(.ok);
}

fn sysAcpiRead(offset: usize, buf_va: usize, len: usize) isize {
    return rawBlobRead(acpi.rawImage(), offset, buf_va, len);
}

// `state` bit 0: 1=alive, 0=exited.
pub const ProcEntry = extern struct {
    pid: u32,
    state: u32,
    name: [process.NAME_MAX]u8,
};

/// SYS_PROC_STAT result. user_cpu_ns = total - sys, computed kernel-side.
pub const ProcStat = extern struct {
    pid: u32,
    uid: u32,
    state: u32, // 0=exited, 1=alive
    num_threads: u32,
    user_cpu_ns: u64,
    sys_cpu_ns: u64,
    rss_bytes: u64,
    kstack_bytes: u64,
    kmem_bytes: u64,
    priority: u8,
    _pad: [7]u8,
    name: [process.NAME_MAX]u8,
};

fn sysHandlePid(handle: cap.Handle) isize {
    const proc = currentProcess() orelse return err(.no_process);
    const ent = proc.cap_table.get(handle, .process) catch return err(.bad_handle);
    const target: *process.Process = @ptrCast(@alignCast(ent.object orelse return err(.bad_handle)));
    return @intCast(target.pid);
}

fn sysProcStat(pid: u32, out_va: usize) isize {
    if (out_va == 0) return err(.bad_arg);
    // pid 0 = current process.
    const target_pid = if (pid == 0) blk: {
        const proc = currentProcess() orelse return err(.no_process);
        break :blk proc.pid;
    } else pid;

    const p = process.byPid(target_pid) orelse return err(.not_found);
    const s = process.stats(p);

    var out: ProcStat = .{
        .pid = p.pid,
        .uid = p.uid,
        .state = if (p.exited) 0 else 1,
        .num_threads = s.num_threads,
        .user_cpu_ns = if (s.total_cpu_ns > s.sys_cpu_ns) s.total_cpu_ns - s.sys_cpu_ns else 0,
        .sys_cpu_ns = s.sys_cpu_ns,
        .rss_bytes = s.rss_bytes,
        .kstack_bytes = s.kstack_bytes,
        .kmem_bytes = s.kmem_bytes,
        .priority = @intFromEnum(if (p.threads) |t| t.priority else thread.DEFAULT_PRIORITY),
        ._pad = @splat(0),
        .name = @splat(0),
    };
    const name = p.nameSlice();
    const n = @min(name.len, out.name.len);
    @memcpy(out.name[0..n], name[0..n]);

    const dst: *ProcStat = @ptrFromInt(@as(usize, @intCast(out_va)));
    dst.* = out;
    return err(.ok);
}

fn sysProcList(out_va: usize, max_entries: usize) isize {
    if (out_va == 0 or max_entries == 0) return err(.bad_arg);
    const dst: [*]ProcEntry = @ptrFromInt(@as(usize, @intCast(out_va)));
    var written: usize = 0;
    for (process.list()) |entry| {
        if (written >= max_entries) break;
        const p = entry orelse continue;
        var e: ProcEntry = .{
            .pid = p.pid,
            .state = if (p.exited) 0 else 1,
            .name = @splat(0),
        };
        const name = p.nameSlice();
        const n = @min(name.len, e.name.len);
        @memcpy(e.name[0..n], name[0..n]);
        dst[written] = e;
        written += 1;
    }
    return @intCast(written);
}

fn sysGetUid() isize {
    const proc = currentProcess() orelse return err(.no_process);
    return @intCast(proc.uid);
}

fn sysThreadPriority(level: u32) isize {
    if (level >= thread.NUM_PRIORITIES) return err(.bad_arg);
    const cur = cpu.thisCpu().current orelse return err(.no_process);
    sched.setPriority(cur, @enumFromInt(@as(u8, @intCast(level))));
    return err(.ok);
}

fn sysThreadDeadline(lo: usize, hi: usize) isize {
    const cur = cpu.thisCpu().current orelse return err(.no_process);
    sched.setDeadline(cur, readUserU64(lo, hi));
    return err(.ok);
}

fn sysClockMono(out_va: usize) isize {
    return writeUserU64(out_va, arch.timer.now());
}

fn sysClockBoot(out_va: usize) isize {
    return writeUserU64(out_va, timer_mod.boot_mono_ns);
}

fn sysNanosleep(lo: usize, hi: usize) isize {
    timer_mod.nanosleep(readUserU64(lo, hi));
    return err(.ok);
}

// PCI mechanism #1 (legacy 0xCF8 / 0xCFC), the only PCI access mode on
// QEMU's i386 i440fx machine. Other arches return -bad_num.
fn sysPciCfgRead(bdf: usize, off: usize, width: usize) isize {
    const proc = currentProcess() orelse return err(.no_process);
    if (!proc.authority.mmio_map) return err(.denied);
    if (!@hasDecl(arch, "pci")) return err(.bad_num);
    const val = arch.pci.cfgRead(@truncate(bdf), @truncate(off), @truncate(width)) catch return err(.bad_arg);
    // PCI config values are u32, so the caller must @bitCast back to u32 on
    // 32-bit ISAs since isize there is i32 and the high bit may be set
    // (e.g., a BAR with phys >= 0x80000000).
    if (@sizeOf(isize) == 8) return @intCast(val);
    const v32: i32 = @bitCast(val);
    return @intCast(v32);
}

fn sysPciCfgWrite(bdf: usize, off: usize, width: usize, value: usize) isize {
    const proc = currentProcess() orelse return err(.no_process);
    if (!proc.authority.mmio_map) return err(.denied);
    if (!@hasDecl(arch, "pci")) return err(.bad_num);
    arch.pci.cfgWrite(@truncate(bdf), @truncate(off), @truncate(width), @truncate(value)) catch return err(.bad_arg);
    return err(.ok);
}

fn sysSetUid(target: u32) isize {
    const proc = currentProcess() orelse return err(.no_process);
    if (!proc.authority.setuid) return err(.denied);
    proc.uid = target;
    return err(.ok);
}

fn sysKillPid(pid: u32) isize {
    const target = process.byPid(pid) orelse return err(.not_found);
    if (target.exited) {
        target.destroy();
        return err(.ok);
    }
    var t = target.threads;
    while (t) |th| : (t = th.next_in_process) {
        _ = sched.killOther(th);
    }
    return err(.ok);
}

fn sysSetPgid(pid: u32, pgid: u32) isize {
    const me = currentProcess() orelse return err(.no_process);
    const target = if (pid == 0) me else (process.byPid(pid) orelse return err(.not_found));
    target.pgid = if (pgid == 0) target.pid else pgid;
    return err(.ok);
}

fn sysGetPgid(pid: u32) isize {
    const me = currentProcess() orelse return err(.no_process);
    const target = if (pid == 0) me else (process.byPid(pid) orelse return err(.not_found));
    return @intCast(target.pgid);
}

fn sysSignal(pid: u32, sig: u32) isize {
    const target = process.byPid(pid) orelse return err(.not_found);
    target.signal(sig);
    return err(.ok);
}

fn sysSigaction(sig: u32, handler_va: usize, restorer_va: usize) isize {
    const proc = currentProcess() orelse return err(.no_process);
    if (sig == 0 or sig >= process.NSIG) return err(.bad_arg);
    proc.sig_handlers[sig] = handler_va;
    if (restorer_va != 0) proc.sig_restorer = restorer_va;
    return err(.ok);
}

fn sysMemInfo(buf_va: usize) isize {
    if (buf_va == 0) return err(.bad_arg);
    const info = memory.meminfo();
    const dst: *memory.MemInfo = @ptrFromInt(@as(usize, @intCast(buf_va)));
    dst.* = info;
    return err(.ok);
}

fn sysAllocPages(npages: usize, out_va_ptr: usize) isize {
    const proc = currentProcess() orelse return err(.no_process);
    if (npages == 0 or npages > 4096) return err(.bad_arg);

    const result = proc.aspace.dmaAlloc(@intCast(npages)) catch |e| return switch (e) {
        error.OutOfMemory => err(.no_mem),
        else => err(.bad_arg),
    };

    return writeUserUsize(out_va_ptr, result.va);
}

fn sysFreePages(va: usize) isize {
    const proc = currentProcess() orelse return err(.no_process);
    if (va == 0) return err(.bad_arg);
    proc.aspace.freeRegion(va) catch |e| return switch (e) {
        error.OutOfMemory => err(.no_mem),
        error.BadAlignment => err(.bad_arg),
        else => err(.bad_arg),
    };
    return err(.ok);
}

fn sysDmaAlloc(npages: usize, out_va_ptr: usize, out_pa_ptr: usize) isize {
    const proc = currentProcess() orelse return err(.no_process);
    if (!proc.authority.mmio_map) return err(.denied);
    if (npages == 0 or npages > 4096) return err(.bad_arg);

    const result = proc.aspace.dmaAlloc(@intCast(npages)) catch |e| return switch (e) {
        error.OutOfMemory => err(.no_mem),
        else => err(.bad_arg),
    };

    const va_rc = writeUserUsize(out_va_ptr, result.va);
    if (va_rc != err(.ok)) return va_rc;
    return writeUserUsize(out_pa_ptr, result.pa);
}

fn sysIrqCreate(irq_num: u32) isize {
    const proc = currentProcess() orelse return err(.no_process);
    if (!proc.authority.irq_claim) return err(.denied);
    if (!irq_mod.archSupported()) return err(.bad_arg);

    const c = irq_mod.claim(heap.allocator(), irq_num) catch |e| return switch (e) {
        error.BadSource => err(.bad_arg),
        error.AlreadyClaimed => err(.denied),
        error.Unsupported => err(.bad_arg),
    };
    const rights: cap.Rights = .{ .read = true, .write = true, .grant = true };
    const handle = proc.cap_table.mint(.irq, rights, @ptrCast(c)) catch return err(.no_mem);
    return @intCast(handle);
}

fn sysIrqListen(irq_handle: cap.Handle, _: u32) isize {
    const proc = currentProcess() orelse return err(.no_process);
    const ent = proc.cap_table.get(irq_handle, .irq) catch return err(.bad_handle);
    const c: *irq_mod.IrqCap = @ptrCast(@alignCast(ent.object orelse return err(.bad_handle)));
    if (c.channel != null) return err(.denied);

    // Cap=4 keeps the buffer under heap's single-page large-alloc limit.
    const ch = ipc.Channel.create(4) catch return err(.no_mem);
    const rights: cap.Rights = .{ .read = true, .grant = true };
    const recv_handle = proc.cap_table.mint(.channel_recv, rights, @ptrCast(ch)) catch {
        ch.destroy();
        return err(.no_mem);
    };
    irq_mod.listen(c, ch);
    return @intCast(recv_handle);
}

// Writes [send_h, recv_h] (two u32s) to *out_va; returns 0 on success.
// Out-param shape so isize fits the return on all arches: 32-bit kernels
// can't pack two handles into a single isize.
fn sysChannelCreate(capacity: usize, out_va: usize) isize {
    if (out_va == 0) return err(.bad_arg);
    const proc = currentProcess() orelse return err(.no_process);
    if (!proc.authority.channel_create) return err(.denied);

    // Cap at 16 (≈256 KB at MAX_INLINE=16 KB) so a typo can't blow the aspace.
    const eff_cap: usize = if (capacity == 0) 1 else @intCast(@min(capacity, 16));
    const ch = ipc.Channel.create(eff_cap) catch return err(.no_mem);

    const send_rights: cap.Rights = .{ .write = true, .grant = true };
    const send_h = proc.cap_table.mint(.channel_send, send_rights, @ptrCast(ch)) catch {
        ch.destroy();
        return err(.no_mem);
    };
    const recv_rights: cap.Rights = .{ .read = true, .grant = true };
    const recv_h = proc.cap_table.mint(.channel_recv, recv_rights, @ptrCast(ch)) catch {
        // revoke unref's the send cap, which is the channel's last ref and
        // already destroys it. A trailing ch.destroy() here double-frees.
        proc.cap_table.revoke(send_h);
        return err(.no_mem);
    };

    const out = userPtr([2]u32, out_va) orelse {
        proc.cap_table.revoke(send_h);
        proc.cap_table.revoke(recv_h); // last ref -> destroys; no explicit destroy.
        return err(.bad_arg);
    };
    out[0] = send_h;
    out[1] = recv_h;
    return err(.ok);
}

fn sysNsBind(name_va: usize, name_len: usize, handle: cap.Handle) isize {
    const proc = currentProcess() orelse return err(.no_process);
    if (name_len == 0 or name_len > 256) return err(.bad_arg);
    var name_buf: [256]u8 = undefined;
    const name = userBytes(name_va, name_buf[0..@intCast(name_len)]) orelse return err(.bad_arg);
    if (handle != cap.NULL_HANDLE) {
        if (handle >= proc.cap_table.entries.len) return err(.bad_handle);
        if (proc.cap_table.entries[handle].kind == .null) return err(.bad_handle);
    }
    proc.namespace.bind(name, handle) catch return err(.no_mem);
    return err(.ok);
}

fn sysCapDup(handle: cap.Handle) isize {
    const proc = currentProcess() orelse return err(.no_process);
    if (handle == cap.NULL_HANDLE or handle >= proc.cap_table.entries.len) return err(.bad_handle);
    const slot = proc.cap_table.entries[handle];
    if (slot.kind == .null) return err(.bad_handle);
    if (!slot.rights.grant) return err(.denied);
    const new = proc.cap_table.mint(slot.kind, slot.rights, slot.object) catch return err(.no_mem);
    return @intCast(new);
}

fn sysNsLookup(name_va: usize, name_len: usize) isize {
    const proc = currentProcess() orelse return err(.no_process);
    if (name_len == 0 or name_len > 256) return err(.bad_arg);
    var name_buf: [256]u8 = undefined;
    const name = userBytes(name_va, name_buf[0..name_len]) orelse return err(.bad_arg);
    const handle = proc.namespace.resolve(name) catch return err(.not_found);
    return @intCast(handle);
}

fn sysIrqAck(irq_handle: cap.Handle) isize {
    const proc = currentProcess() orelse return err(.no_process);
    const ent = proc.cap_table.get(irq_handle, .irq) catch return err(.bad_handle);
    const c: *irq_mod.IrqCap = @ptrCast(@alignCast(ent.object orelse return err(.bad_handle)));
    irq_mod.ack(c);
    return err(.ok);
}

inline fn currentProcess() ?*process.Process {
    const t = cpu.current() orelse return null;
    return process.fromThread(t);
}
