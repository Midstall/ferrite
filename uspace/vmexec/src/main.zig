// vmexec, sandbox a single Ferrite program inside a hardware-isolated microVM.
//
//   vmexec [--allow=write,read,print,...] <program> [args...]
//
// Loads the target program into a VM, runs it unprivileged, and proxies its
// system calls through an allow-list policy. The program cannot touch the host
// except through calls vmexec chooses to forward; deny is the default, and only
// SYS_EXIT is always permitted. The VM boundary (stage-2 / G-stage) is the
// isolation, so the program needs no signature and gets no host caps.
//
// The kernel enters the program at the unprivileged guest level and routes its
// syscalls straight to the hypervisor: aarch64 runs it at EL0 with HCR_EL2.TGE
// (svc -> EL2), riscv64 runs it at VU-mode (ecall -> M-mode host). Either way no
// in-guest shim or page tables are needed (the program runs flat under the
// stage-2 / G-stage map). aarch64 needs the EL2 hyp stub, so run that host under
// -Dhyp; riscv64 needs no extra flag (H is always present). To boot a whole
// guest kernel like QEMU instead, use `vmboot`.
//
// Layout of the 16 MiB guest window (all guest-physical == guest-virtual, the
// program runs with its own paging off):
//   GUEST_BASE + 0x100000  program segments (PIE-slid here)
//   GUEST_BASE + 0xfff000  top of the program's stack / argv block
const std = @import("std");
const builtin = @import("builtin");
const ferrite = std.os.ferrite;
const sys = ferrite.syscall;
const macho = std.macho;

pub const panic = ferrite.panic;

const PAGE: u64 = 4096;
// Guest RAM base: each arch's conventional RAM base so it lands in the
// stage-2/G-stage range (riscv virt 0x8000_0000, aarch64 virt 0x4000_0000).
const GUEST_BASE: u64 = if (builtin.cpu.arch == .riscv64) 0x8000_0000 else 0x4000_0000;
const WINDOW_PAGES: usize = 4096; // 16 MiB (kernel caps a single VM_MAP here)
const WINDOW: u64 = @as(u64, WINDOW_PAGES) * PAGE;

const PROG_LOAD_GPA: u64 = GUEST_BASE + 0x10_0000; // program 1 MiB in
const ARGS_TOP: u64 = GUEST_BASE + WINDOW - 0x1000; // program's stack top

// Where the guest's syscall ABI puts the number, args, and return value.
// aarch64: nr=x8, args=x0..x7, ret=x0. riscv64: nr=a7(x17), args=a0..(x10..), ret=a0(x10).
// x86_64: `syscall`, nr=rax(0), args=rdi(5)/rsi(4)/rdx(3)/r10(10)/r8(8)/r9(9), ret=rax(0).
const is_riscv = builtin.cpu.arch == .riscv64;
const is_x86 = builtin.cpu.arch == .x86_64;
const NR_REG: usize = if (is_riscv) 17 else if (is_x86) 0 else 8;
const RET_REG: usize = if (is_riscv) 10 else if (is_x86) 0 else 0;
const x86_arg_regs = [_]usize{ 5, 4, 3, 10, 8, 9 }; // rdi, rsi, rdx, r10, r8, r9
inline fn argReg(i: usize) usize {
    if (is_riscv) return 10 + i;
    if (is_x86) return x86_arg_regs[i];
    return i;
}
// Reg index 16 is the kernel's pseudo-register for the long-mode sandbox guest
// CR3 (see arch/x86_64/hyp.zig REG_GUEST_CR3).
const REG_GUEST_CR3: usize = 16;

// Ferrite-only Mach-O command: pointer rebases the loader must apply.
const LC_FERRITE_REBASE: u32 = 0x1001;
const RebaseEntry = extern struct { r_offset: u64, r_addend: u64 };

// Ferrite syscall numbers we know how to proxy (subset of kernel syscall.zig).
const SYS_DEBUG_PRINT: usize = 0;
const SYS_WRITE_CONSOLE: usize = 1;
const SYS_READ_CONSOLE: usize = 2;
const SYS_EXIT: usize = 3;
const SYS_PAGE_SIZE: usize = 5;
const SYS_YIELD: usize = 6;
const SYS_UNAME: usize = 7;
const SYS_MEM_INFO: usize = 8;
const SYS_CLOCK_MONO: usize = 35;
const SYS_GETUID: usize = 38;
const SYS_CLOCK_BOOT: usize = 44;
const SYS_NANOSLEEP: usize = 45;
// IPC + capability primitives the filesystem rides on. The "fs" allow-name
// enables this whole group; vmexec acts as a gVisor-style sentry, virtualizing
// the guest's handles against real host handles it holds (see the vhandle table).
const SYS_SEND: usize = 15;
const SYS_RECV: usize = 16;
const SYS_CHANNEL_CREATE: usize = 17;
const SYS_CAP_DUP: usize = 18;
const SYS_CAP_RELEASE: usize = 19;
const SYS_NS_LOOKUP: usize = 21;

// Raw Mach-O of the target program, staged here while we lay its segments into
// the guest window. BSS, so it costs nothing on disk.
var prog_scratch: [8 * 1024 * 1024]u8 = undefined;

// seccomp-style policy, indexed by syscall number. Each permitted syscall may
// carry one argument predicate; SYS_EXIT is always permitted unconditionally.
const Op = enum { none, eq, le, ge };
const Rule = struct {
    on: bool = false, // syscall permitted at all
    arg: u8 = 0, //      which arg the predicate tests (0-based)
    op: Op = .none, //   predicate operator (.none = unconditional)
    val: u64 = 0,
};
var rules: [128]Rule = @splat(.{});

const NameNum = struct { name: []const u8, nr: usize };
const allow_names = [_]NameNum{
    .{ .name = "write", .nr = SYS_WRITE_CONSOLE },
    .{ .name = "read", .nr = SYS_READ_CONSOLE },
    .{ .name = "print", .nr = SYS_DEBUG_PRINT },
    .{ .name = "pagesize", .nr = SYS_PAGE_SIZE },
    .{ .name = "yield", .nr = SYS_YIELD },
    .{ .name = "getuid", .nr = SYS_GETUID },
    .{ .name = "uname", .nr = SYS_UNAME },
    .{ .name = "meminfo", .nr = SYS_MEM_INFO },
    .{ .name = "sleep", .nr = SYS_NANOSLEEP },
    .{ .name = "clock", .nr = SYS_CLOCK_MONO }, // "clock" enables both clocks
    .{ .name = "clock", .nr = SYS_CLOCK_BOOT },
    // "fs" enables the gVisor-style filesystem sentry (the whole IPC group).
    .{ .name = "fs", .nr = SYS_NS_LOOKUP },
    .{ .name = "fs", .nr = SYS_CHANNEL_CREATE },
    .{ .name = "fs", .nr = SYS_SEND },
    .{ .name = "fs", .nr = SYS_RECV },
    .{ .name = "fs", .nr = SYS_CAP_DUP },
    .{ .name = "fs", .nr = SYS_CAP_RELEASE },
};

// gVisor-style sentry handle table: the guest sees small "virtual" handle
// numbers; vmexec holds the matching real host handles and translates on every
// IPC syscall. Index 0 is reserved (0 = invalid, so a real handle never aliases
// the guest's "no handle"). fs path filtering rides on top (see fsPathAllowed).
const VHANDLES: usize = 256;
var vh_real: [VHANDLES]u32 = @splat(0); // virtual handle -> real host handle (0 = free)
// Path-filter correlation state (see the fs sentry). vh_pair links the two
// halves of a channelCreate; vh_prefix tags a service handle with the unix mount
// prefix it serves; vh_pending marks a reply-recv handle awaiting a lookup reply
// whose returned service cap should inherit that prefix.
var vh_pair: [VHANDLES]u32 = @splat(0);
var vh_prefix: [VHANDLES]?[]const u8 = @splat(null);
var vh_pending: [VHANDLES]?[]const u8 = @splat(null);

fn vhAlloc(real: u32) u32 {
    var i: usize = 1;
    while (i < VHANDLES) : (i += 1) {
        if (vh_real[i] == 0) {
            vh_real[i] = real;
            vh_pair[i] = 0;
            vh_prefix[i] = null;
            vh_pending[i] = null;
            return @intCast(i);
        }
    }
    return 0; // table full
}
fn vhReal(v: u64) u32 {
    return if (v != 0 and v < VHANDLES) vh_real[@intCast(v)] else 0;
}
fn vhFree(v: u64) void {
    if (v != 0 and v < VHANDLES) {
        const i: usize = @intCast(v);
        vh_real[i] = 0;
        vh_pair[i] = 0;
        vh_prefix[i] = null;
        vh_pending[i] = null;
    }
}
fn vhPair(v: u64) u32 {
    return if (v != 0 and v < VHANDLES) vh_pair[@intCast(v)] else 0;
}

// fs path policy: unix-path prefixes the sandboxed program may open. Empty means
// allow any path (full fs). Slices point into argv, which outlives the run.
var fs_allow: [16][]const u8 = undefined;
var fs_allow_n: usize = 0;

fn fsPathAllowed(path: []const u8) bool {
    if (fs_allow_n == 0) return true;
    var i: usize = 0;
    while (i < fs_allow_n) : (i += 1) {
        if (std.mem.startsWith(u8, path, fs_allow[i])) return true;
    }
    return false;
}

fn parseFsAllow(list: []const u8) void {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |p| {
        if (p.len != 0 and fs_allow_n < fs_allow.len) {
            fs_allow[fs_allow_n] = p;
            fs_allow_n += 1;
        }
    }
}

// Mount table (unix prefix <-> authority), snapshotted from the nameserver once
// at startup so the sentry can turn a service handle's authority back into the
// mount point, then reconstruct full paths from the mount-relative Twalk paths.
const MountEnt = struct { prefix: []const u8, authority: []const u8 };
var mounts: [32]MountEnt = undefined;
var mounts_n: usize = 0;
var mounts_buf: [4096]u8 = undefined; // dumpMounts output; the slices point here

fn loadMounts() void {
    const n = ferrite.fs.dumpMounts(&mounts_buf) catch return;
    var it = std.mem.splitScalar(u8, mounts_buf[0..n], '\n');
    while (it.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (mounts_n < mounts.len) {
            mounts[mounts_n] = .{ .prefix = line[0..tab], .authority = line[tab + 1 ..] };
            mounts_n += 1;
        }
    }
}

fn prefixForAuthority(auth: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < mounts_n) : (i += 1) {
        if (std.mem.eql(u8, mounts[i].authority, auth)) return mounts[i].prefix;
    }
    return null;
}

// Join a mount prefix with a mount-relative sub-path into a full unix path.
var joinbuf: [512]u8 = undefined;
fn joinPath(prefix: []const u8, sub_in: []const u8) []const u8 {
    var n: usize = @min(prefix.len, joinbuf.len);
    @memcpy(joinbuf[0..n], prefix[0..n]);
    if (n == 0 or joinbuf[n - 1] != '/') {
        if (n < joinbuf.len) {
            joinbuf[n] = '/';
            n += 1;
        }
    }
    var sub = sub_in;
    if (sub.len > 0 and sub[0] == '/') sub = sub[1..];
    const cl = @min(sub.len, joinbuf.len - n);
    @memcpy(joinbuf[n..][0..cl], sub[0..cl]);
    return joinbuf[0 .. n + cl];
}

// Persistent store for mount prefixes computed at runtime (submount redirects),
// since vh_prefix slices must outlive the transient joinbuf/last_walk buffers.
var prefix_arena: [2048]u8 = undefined;
var prefix_arena_n: usize = 0;
fn intern(s: []const u8) ?[]const u8 {
    if (prefix_arena_n + s.len > prefix_arena.len) return null;
    const out = prefix_arena[prefix_arena_n..][0..s.len];
    @memcpy(out, s);
    prefix_arena_n += s.len;
    return out;
}

// The full path of the most recent walk send, kept so a walk_redirect reply can
// derive the submount's mount prefix. Walks are synchronous (send then recv on
// the same reply channel), so a single slot correctly pairs send with reply.
var last_walk: [512]u8 = undefined;
var last_walk_n: usize = 0;
fn saveLastWalk(full: []const u8) void {
    last_walk_n = @min(full.len, last_walk.len);
    @memcpy(last_walk[0..last_walk_n], full[0..last_walk_n]);
}

// A walk on a service at mount prefix P redirected with `remaining` left to walk
// under a submount. The submount is mounted at (full walk path) minus
// `remaining`; return that, interned. Null if it can't be derived cleanly.
fn submountPrefix(remaining: []const u8) ?[]const u8 {
    if (last_walk_n == 0) return null;
    const full = last_walk[0..last_walk_n];
    if (remaining.len > full.len or !std.mem.endsWith(u8, full, remaining)) return null;
    var sp = full[0 .. full.len - remaining.len];
    while (sp.len > 1 and sp[sp.len - 1] == '/') sp = sp[0 .. sp.len - 1];
    return intern(sp);
}

fn err(comptime fmt: []const u8, args: anytype) void {
    ferrite.console.print(fmt, args) catch {};
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

// Guest-physical window helpers (the window maps GUEST_BASE .. GUEST_BASE+WINDOW).

fn winSlice(window: []u8, gpa: u64, len: u64) ?[]u8 {
    if (gpa < GUEST_BASE) return null;
    const off = gpa - GUEST_BASE;
    if (off + len > WINDOW) return null;
    return window[@intCast(off)..][0..@intCast(len)];
}

// Like winSlice but clamps the length to whatever window remains (used for
// recv, whose ABI carries no buffer length: the message size, not `max`, is
// what actually gets written).
fn winSliceUpto(window: []u8, gpa: u64, max: u64) ?[]u8 {
    if (gpa < GUEST_BASE) return null;
    const off = gpa - GUEST_BASE;
    if (off >= WINDOW) return null;
    const end = @min(off + max, WINDOW);
    return window[@intCast(off)..@intCast(end)];
}

// Max 9p message size; the guest's reply buffers are this big.
const P9_MAX: u64 = ferrite.p9.MAX_MSG;

fn putU64(window: []u8, gpa: u64, v: u64) void {
    if (winSlice(window, gpa, 8)) |s| std.mem.writeInt(u64, s[0..8], v, .little);
}

// Mach-O load-command walker (raw cmd value + the command's bytes).

const LcIter = struct {
    file: []const u8,
    ncmds: u32,
    i: u32 = 0,
    cur: usize,

    const Item = struct { cmd: u32, bytes: []const u8 };

    fn init(file: []const u8, hdr: macho.mach_header_64) LcIter {
        return .{ .file = file, .ncmds = hdr.ncmds, .cur = @sizeOf(macho.mach_header_64) };
    }

    fn next(self: *LcIter) ?Item {
        if (self.i >= self.ncmds) return null;
        if (self.cur + 8 > self.file.len) return null;
        const cmd = std.mem.readInt(u32, self.file[self.cur..][0..4], .little);
        const size = std.mem.readInt(u32, self.file[self.cur + 4 ..][0..4], .little);
        if (size < 8 or self.cur + size > self.file.len) return null;
        const bytes = self.file[self.cur .. self.cur + size];
        self.cur += size;
        self.i += 1;
        return .{ .cmd = cmd, .bytes = bytes };
    }
};

const Prog = struct { entry: u64, sp: u64 };

/// Parse the (thin, native) Mach-O in `file`, lay its PIE-slid segments into the
/// guest window, apply Ferrite rebases, build the argv block, and return the
/// program's entry PC and stack pointer (both guest-physical).
fn loadProgram(window: []u8, file: []const u8, prog_argv: []const []const u8) ?Prog {
    if (file.len < @sizeOf(macho.mach_header_64)) return null;
    const hdr = std.mem.bytesAsValue(macho.mach_header_64, file[0..@sizeOf(macho.mach_header_64)]).*;
    if (hdr.magic != macho.MH_MAGIC_64) return null; // expect a thin native slice

    const SEG = @intFromEnum(macho.LC.SEGMENT_64);
    const MAIN = @intFromEnum(macho.LC.MAIN);

    // Pass 1: PIE slide = put the lowest segment vmaddr at PROG_LOAD_GPA.
    var min_vmaddr: u64 = std.math.maxInt(u64);
    var it1 = LcIter.init(file, hdr);
    while (it1.next()) |lc| {
        if (lc.cmd != SEG or lc.bytes.len < @sizeOf(macho.segment_command_64)) continue;
        const seg = std.mem.bytesAsValue(macho.segment_command_64, lc.bytes[0..@sizeOf(macho.segment_command_64)]).*;
        if (seg.vmsize != 0 and seg.vmaddr < min_vmaddr) min_vmaddr = seg.vmaddr;
    }
    if (min_vmaddr == std.math.maxInt(u64)) return null;
    const slide: u64 = PROG_LOAD_GPA -% min_vmaddr;

    // Pass 2: copy segment contents, record entry offset, apply rebases.
    var entry_off: u64 = 0;
    var it2 = LcIter.init(file, hdr);
    while (it2.next()) |lc| {
        if (lc.cmd == SEG and lc.bytes.len >= @sizeOf(macho.segment_command_64)) {
            const seg = std.mem.bytesAsValue(macho.segment_command_64, lc.bytes[0..@sizeOf(macho.segment_command_64)]).*;
            if (seg.vmsize == 0) continue;
            const copy = @min(seg.filesize, seg.vmsize);
            if (copy > 0) {
                const dst = winSlice(window, seg.vmaddr +% slide, copy) orelse return null;
                const fo: usize = @intCast(seg.fileoff);
                const hi: usize = fo + @as(usize, @intCast(copy));
                if (hi > file.len) return null;
                @memcpy(dst, file[fo..hi]);
            }
        } else if (lc.cmd == MAIN and lc.bytes.len >= @sizeOf(macho.entry_point_command)) {
            const ep = std.mem.bytesAsValue(macho.entry_point_command, lc.bytes[0..@sizeOf(macho.entry_point_command)]).*;
            entry_off = ep.entryoff;
        } else if (lc.cmd == LC_FERRITE_REBASE and lc.bytes.len >= 16) {
            const count = std.mem.readInt(u32, lc.bytes[8..12], .little);
            const need = 16 + @as(usize, count) * @sizeOf(RebaseEntry);
            if (lc.bytes.len < need) return null;
            const ents = std.mem.bytesAsSlice(RebaseEntry, lc.bytes[16..need]);
            for (ents) |r| putU64(window, r.r_offset +% slide, r.r_addend +% slide);
        }
    }

    // Resolve the entry: the segment whose file range contains entry_off.
    var entry_gpa: ?u64 = null;
    var it3 = LcIter.init(file, hdr);
    while (it3.next()) |lc| {
        if (lc.cmd != SEG or lc.bytes.len < @sizeOf(macho.segment_command_64)) continue;
        const seg = std.mem.bytesAsValue(macho.segment_command_64, lc.bytes[0..@sizeOf(macho.segment_command_64)]).*;
        if (entry_off >= seg.fileoff and entry_off < seg.fileoff + seg.filesize) {
            entry_gpa = seg.vmaddr + (entry_off - seg.fileoff) + slide;
            break;
        }
    }

    const e = entry_gpa orelse return null;
    return .{ .entry = e, .sp = buildArgs(window, prog_argv) };
}

const MAX_ARGV: usize = 64;

/// Lay the SysV/Mach-O startup block (argc | argv | NULL | envp NULL | apple
/// NULL | strings) at the top of the window and return the 16-byte-aligned sp.
fn buildArgs(window: []u8, argv: []const []const u8) u64 {
    const n: u64 = @intCast(argv.len);
    var str_bytes: u64 = 0;
    for (argv) |s| str_bytes += @as(u64, s.len) + 1;

    const array_bytes = 8 * (1 + n + 1 + 1 + 1); // argc, argv[n], NULL, envp NULL, apple NULL
    const str_lo = (ARGS_TOP - str_bytes) & ~@as(u64, 7);
    const sp = (str_lo - array_bytes) & ~@as(u64, 0xF);

    var argv_va: [MAX_ARGV]u64 = undefined;
    var str_va = ARGS_TOP - str_bytes;
    for (argv, 0..) |s, i| {
        argv_va[i] = str_va;
        if (winSlice(window, str_va, @as(u64, s.len) + 1)) |dst| {
            @memcpy(dst[0..s.len], s);
            dst[s.len] = 0;
        }
        str_va += @as(u64, s.len) + 1;
    }

    var pos = sp;
    putU64(window, pos, n);
    pos += 8;
    for (argv, 0..) |_, i| {
        putU64(window, pos, argv_va[i]);
        pos += 8;
    }
    putU64(window, pos, 0); // argv terminator
    pos += 8;
    putU64(window, pos, 0); // envp terminator
    pos += 8;
    putU64(window, pos, 0); // apple terminator
    return sp;
}

// Parse a `--allow=` list. Each comma-separated entry is `name` or
// `name:argN<op>val` (op = `<=`, `>=`, or `=`), e.g. `write:arg1<=4096` or
// `sleep:arg0<=1000000000`. The predicate is checked against the syscall's args
// before the call is performed (seccomp-style).
fn parseAllow(list: []const u8) void {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        var name = entry;
        var rule = Rule{ .on = true };
        if (std.mem.indexOfScalar(u8, entry, ':')) |ci| {
            name = entry[0..ci];
            if (!parsePred(entry[ci + 1 ..], &rule)) {
                err("vmexec: bad predicate in '{s}'\n", .{entry});
                continue;
            }
        }
        var matched = false;
        for (allow_names) |nn| {
            if (std.mem.eql(u8, name, nn.name)) {
                rules[nn.nr] = rule;
                matched = true;
            }
        }
        if (!matched) err("vmexec: unknown --allow name '{s}'\n", .{name});
    }
}

fn parsePred(pred: []const u8, rule: *Rule) bool {
    if (!std.mem.startsWith(u8, pred, "arg")) return false;
    var i: usize = 3;
    var argn: u64 = 0;
    var have_digit = false;
    while (i < pred.len and pred[i] >= '0' and pred[i] <= '9') : (i += 1) {
        argn = argn * 10 + (pred[i] - '0');
        have_digit = true;
    }
    if (!have_digit or i >= pred.len) return false;
    if (std.mem.startsWith(u8, pred[i..], "<=")) {
        rule.op = .le;
        i += 2;
    } else if (std.mem.startsWith(u8, pred[i..], ">=")) {
        rule.op = .ge;
        i += 2;
    } else if (pred[i] == '=') {
        rule.op = .eq;
        i += 1;
    } else return false;
    rule.val = std.fmt.parseInt(u64, pred[i..], 0) catch return false;
    rule.arg = @intCast(argn);
    return true;
}

// x86_64 long-mode sandbox guest paging: build an identity GVA->GPA table that
// maps the whole guest window with 2 MiB pages, placed inside the window itself
// (so the stage-2/EPT already covers it). The guest's CR3 walks these GPAs; the
// stage-2 then maps GPA->HPA. Returns the PML4 guest-physical address.
// Layout: PML4 at window+0xC0000, PDPT +0xC1000, PD +0xC2000 (all below the
// program load at +1 MiB, so they never collide with segments/stack).
const PT_OFF: u64 = 0x0c_0000;
fn putPte(window: []u8, off: u64, value: u64) void {
    std.mem.writeInt(u64, window[@intCast(off)..][0..8], value, .little);
}
fn buildIdentityPageTable(window: []u8) u64 {
    const pml4_gpa = GUEST_BASE + PT_OFF;
    const pdpt_gpa = GUEST_BASE + PT_OFF + PAGE;
    const pd_gpa = GUEST_BASE + PT_OFF + 2 * PAGE;
    const pml4_i = (GUEST_BASE >> 39) & 0x1ff;
    const pdpt_i = (GUEST_BASE >> 30) & 0x1ff;
    const pd_i0 = (GUEST_BASE >> 21) & 0x1ff;
    // P|RW|US for the upper levels, + PS (2 MiB) for the leaves.
    putPte(window, PT_OFF + pml4_i * 8, pdpt_gpa | 0x7);
    putPte(window, PT_OFF + PAGE + pdpt_i * 8, pd_gpa | 0x7);
    const npd = WINDOW / 0x20_0000; // 2 MiB pages spanning the window
    var i: u64 = 0;
    while (i < npd) : (i += 1) {
        putPte(window, PT_OFF + 2 * PAGE + (pd_i0 + i) * 8, (GUEST_BASE + i * 0x20_0000) | 0x87);
    }
    return pml4_gpa;
}

pub fn main() void {
    if (builtin.cpu.arch != .aarch64 and builtin.cpu.arch != .riscv64 and builtin.cpu.arch != .x86_64) {
        err("vmexec: the sandbox needs aarch64, riscv64, or x86_64\n", .{});
        return;
    }
    const args = ferrite.argv;
    rules[SYS_EXIT] = .{ .on = true }; // the program must always be able to exit

    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        const a = std.mem.span(args[idx]);
        if (std.mem.startsWith(u8, a, "--allow=")) {
            parseAllow(a["--allow=".len..]);
        } else if (std.mem.startsWith(u8, a, "--fs-allow=")) {
            parseFsAllow(a["--fs-allow=".len..]);
        } else if (std.mem.eql(u8, a, "--")) {
            idx += 1;
            break;
        } else if (a.len > 0 and a[0] == '-') {
            err("vmexec: unknown flag '{s}'\n", .{a});
            return;
        } else break;
    }
    if (idx >= args.len) {
        err("usage: vmexec [--allow=name[:argN<op>val],...] [--fs-allow=/prefix,...] <program> [args...]\n" ++
            "  names: write read print pagesize yield getuid uname meminfo sleep clock fs\n", .{});
        return;
    }
    const prog_path = std.mem.span(args[idx]);

    // The program's argv is [program, the rest].
    var pargv: [MAX_ARGV][]const u8 = undefined;
    var pn: usize = 0;
    var k = idx;
    while (k < args.len and pn < MAX_ARGV) : (k += 1) {
        pargv[pn] = std.mem.span(args[k]);
        pn += 1;
    }

    // Snapshot the mount table so the path filter can reconstruct full paths
    // from a service's mount-relative Twalk paths (only needed when filtering).
    if (fs_allow_n > 0) loadMounts();

    const vm = sys.vmCreate(GUEST_BASE);
    if (vm < 0) {
        err("vmexec: vm_create failed ({d}); aarch64 needs -Dhyp\n", .{vm});
        return;
    }
    const vmh: u32 = @intCast(vm);

    var ram_va: usize = 0;
    if (sys.vmMap(vmh, GUEST_BASE, WINDOW_PAGES, &ram_va) < 0) {
        err("vmexec: vm_map failed\n", .{});
        return;
    }
    const window = @as([*]u8, @ptrFromInt(ram_va))[0..@intCast(WINDOW)];
    @memset(window, 0);

    const nbytes = loadFile(prog_path, &prog_scratch) orelse {
        err("vmexec: cannot read program '{s}'\n", .{prog_path});
        return;
    };
    const prog = loadProgram(window, prog_scratch[0..nbytes], pargv[0..pn]) orelse {
        err("vmexec: bad program image '{s}'\n", .{prog_path});
        return;
    };

    // x86_64 runs the sandbox in 64-bit long mode (the only mode that runs the
    // 64-bit program), which needs guest paging. Build an identity GVA->GPA page
    // table inside the window and hand its root to the kernel as the guest CR3.
    if (is_x86) {
        const cr3 = buildIdentityPageTable(window);
        _ = sys.vcpuSetReg(vmh, REG_GUEST_CR3, cr3);
    }

    // Enter the program unprivileged (aarch64 EL0+TGE / riscv VU-mode / x86 CPL3
    // long mode) so its syscalls trap straight to the hypervisor.
    _ = sys.vcpuEl0Entry(vmh, prog.entry, prog.sp);

    const code = runGuest(vmh, window);
    err("\nvmexec: '{s}' exited ({d})\n", .{ prog_path, code });
}

fn getReg(vmh: u32, i: usize) u64 {
    var v: usize = 0;
    _ = sys.vcpuGetReg(vmh, i, &v);
    return v;
}

fn denied() u64 {
    return @bitCast(@as(i64, -1));
}

fn runGuest(vmh: u32, window: []u8) u64 {
    while (true) {
        var x0: usize = 0;
        var x1: usize = 0;
        const r = sys.vcpuRun(vmh, &x0, &x1);
        if (r < 0) {
            err("\nvmexec: vcpu_run error {d}\n", .{r});
            return 1;
        }
        switch (@as(sys.VmExit, @enumFromInt(r))) {
            .interrupt => {}, // host tick during the guest; re-enter
            .poweroff => {
                err("\nvmexec: VM powered off\n", .{});
                return 0;
            },
            .fault => {
                err("\nvmexec: guest CPU fault (x0=0x{x} x1=0x{x})\n", .{ x0, x1 });
                return 1;
            },
            .mmio => {
                err("\nvmexec: unexpected guest MMIO; stopping\n", .{});
                return 1;
            },
            .hypercall => {
                // The program's syscall (aarch64 svc / riscv ecall) is the only
                // thing that reaches here; a guest fault arrives as .fault/.mmio.
                const nr = getReg(vmh, NR_REG);
                if (service(vmh, window, @intCast(nr))) |code| return code;
            },
        }
    }
}

fn setRet(vmh: u32, v: u64) void {
    _ = sys.vcpuSetReg(vmh, RET_REG, v);
}

// Allocate a virtual handle for a real host handle, returning the error value
// (so the guest sees a failed syscall) if the table is full.
fn allocOrErr(real: u32) u64 {
    const v = vhAlloc(real);
    return if (v == 0) denied() else v;
}

/// Service one proxied syscall. Returns the exit code (stop the VM) for
/// SYS_EXIT, else null after writing the result into the guest's return reg.
fn service(vmh: u32, window: []u8, nr: usize) ?u64 {
    if (nr == SYS_EXIT) return getReg(vmh, argReg(0));

    // seccomp gate: the syscall must be permitted, and any argument predicate
    // attached to it (`name:argN<op>val`) must hold, or it is refused.
    if (nr >= rules.len or !rules[nr].on) {
        setRet(vmh, denied());
        return null;
    }
    const ru = rules[nr];
    if (ru.op != .none) {
        const a = getReg(vmh, argReg(ru.arg));
        const ok = switch (ru.op) {
            .eq => a == ru.val,
            .le => a <= ru.val,
            .ge => a >= ru.val,
            .none => true,
        };
        if (!ok) {
            setRet(vmh, denied());
            return null;
        }
    }

    switch (nr) {
        SYS_WRITE_CONSOLE => {
            const buf = getReg(vmh, argReg(0));
            const len = getReg(vmh, argReg(1));
            if (winSlice(window, buf, len)) |s| {
                ferrite.writeStdout(s);
                setRet(vmh, len);
            } else setRet(vmh, denied());
        },
        SYS_READ_CONSOLE => {
            const buf = getReg(vmh, argReg(0));
            const len = getReg(vmh, argReg(1));
            if (winSlice(window, buf, len)) |s| {
                setRet(vmh, ferrite.readStdin(s));
            } else setRet(vmh, denied());
        },
        SYS_DEBUG_PRINT => {
            const ptr = getReg(vmh, argReg(0));
            var n: u64 = 0;
            while (n < 4096) : (n += 1) {
                const cs = winSlice(window, ptr + n, 1) orelse break;
                if (cs[0] == 0) break;
            }
            if (winSlice(window, ptr, n)) |s| ferrite.writeStdout(s);
            setRet(vmh, 0);
        },
        SYS_PAGE_SIZE => setRet(vmh, PAGE),
        SYS_YIELD => setRet(vmh, 0),
        SYS_GETUID => setRet(vmh, sys.getUid()),
        SYS_CLOCK_MONO, SYS_CLOCK_BOOT => {
            // arg0 = guest pointer to a u64 that receives the time.
            if (winSlice(window, getReg(vmh, argReg(0)), 8)) |d| {
                const t = if (nr == SYS_CLOCK_MONO) sys.clockMono() else sys.clockBoot();
                std.mem.writeInt(u64, d[0..8], t, .little);
                setRet(vmh, 0);
            } else setRet(vmh, denied());
        },
        SYS_NANOSLEEP => {
            // ns split lo/hi across two args (splitU64); on 64-bit hi is 0.
            const ns = getReg(vmh, argReg(0)) | (getReg(vmh, argReg(1)) << 32);
            sys.nanosleep(ns);
            setRet(vmh, 0);
        },
        SYS_UNAME => {
            var u: sys.UnameInfo = undefined;
            _ = sys.uname(&u);
            if (winSlice(window, getReg(vmh, argReg(0)), @sizeOf(sys.UnameInfo))) |d| {
                @memcpy(d, std.mem.asBytes(&u));
                setRet(vmh, 0);
            } else setRet(vmh, denied());
        },
        SYS_MEM_INFO => {
            var m: sys.MemInfo = undefined;
            _ = sys.memInfo(&m);
            if (winSlice(window, getReg(vmh, argReg(0)), @sizeOf(sys.MemInfo))) |d| {
                @memcpy(d, std.mem.asBytes(&m));
                setRet(vmh, 0);
            } else setRet(vmh, denied());
        },

        // gVisor-style fs sentry: virtualize the IPC + capability primitives.
        // The guest sees virtual handles; vmexec holds the real host handles and
        // shuttles the 9p bytes (passing guest-window slices straight to the real
        // syscalls, since the window IS vmexec's mapped memory).
        SYS_NS_LOOKUP => {
            const name = winSlice(window, getReg(vmh, argReg(0)), getReg(vmh, argReg(1))) orelse {
                setRet(vmh, denied());
                return null;
            };
            const r = sys.nsLookup(name);
            if (r < 0) setRet(vmh, @bitCast(@as(i64, r))) else setRet(vmh, allocOrErr(@intCast(r)));
        },
        SYS_CHANNEL_CREATE => {
            const out_ptr = getReg(vmh, argReg(1));
            const packed_ = sys.channelCreate(@intCast(getReg(vmh, argReg(0))));
            if (packed_ < 0) {
                setRet(vmh, @bitCast(@as(i64, packed_)));
                return null;
            }
            const up: u64 = @bitCast(packed_);
            const real_send: u32 = @truncate(up);
            const real_recv: u32 = @truncate(up >> 32);
            const vs = vhAlloc(real_send);
            const vr = vhAlloc(real_recv);
            const d = winSlice(window, out_ptr, 8);
            if (vs == 0 or vr == 0 or d == null) {
                _ = sys.capRelease(real_send);
                _ = sys.capRelease(real_recv);
                vhFree(vs);
                vhFree(vr);
                setRet(vmh, denied());
                return null;
            }
            vh_pair[vs] = vr; // link the halves so a lookup reply can be correlated
            vh_pair[vr] = vs;
            std.mem.writeInt(u32, d.?[0..4], vs, .little);
            std.mem.writeInt(u32, d.?[4..8], vr, .little);
            setRet(vmh, 0);
        },
        SYS_SEND => {
            const hv = getReg(vmh, argReg(0));
            const h = vhReal(hv);
            const xfer_v = getReg(vmh, argReg(3));
            const xfer = vhReal(xfer_v);
            const buf = winSlice(window, getReg(vmh, argReg(1)), getReg(vmh, argReg(2)));
            if (h == 0 or buf == null) {
                setRet(vmh, denied());
                return null;
            }
            // fs path policy (only meaningful when --fs-allow is set). The path a
            // program opens appears in three message kinds, and a hostile program
            // can skip any one of them, so all three are checked:
            //   resolve_mount(path)  - the full unix path (the cooperative path).
            //   lookup(authority)    - which mount; tag the reply channel so the
            //                          returned service cap inherits the prefix.
            //   walk(fid, sub_path)  - the mount-relative path; rebuilt to a full
            //                          path via the service handle's mount prefix.
            if (fs_allow_n > 0) {
                if (ferrite.p9.decodeRequest(buf.?)) |dec| {
                    switch (dec.req) {
                        .resolve_mount => |m| if (!fsPathAllowed(m.path)) {
                            setRet(vmh, denied());
                            return null;
                        },
                        .lookup => |m| {
                            const rv = vhPair(xfer_v); // reply arrives on the paired half
                            if (rv != 0) vh_pending[rv] = prefixForAuthority(m.prefix);
                        },
                        .walk => |m| {
                            // A walk must ride a service handle we tagged (at lookup
                            // or via a submount redirect); an untagged one is refused
                            // under an active filter. Save the full path so a
                            // walk_redirect reply can tag the submount it hands back.
                            const pfx: ?[]const u8 = if (hv < VHANDLES) vh_prefix[@intCast(hv)] else null;
                            if (pfx) |p| {
                                const full = joinPath(p, m.path);
                                saveLastWalk(full);
                                if (!fsPathAllowed(full)) {
                                    setRet(vmh, denied());
                                    return null;
                                }
                            } else {
                                setRet(vmh, denied());
                                return null;
                            }
                        },
                        else => {},
                    }
                } else |_| {}
            }
            const r = sys.send(h, buf.?, xfer);
            if (r == 0 and xfer != 0) vhFree(xfer_v); // send transferred the cap away
            setRet(vmh, @bitCast(@as(i64, r)));
        },
        SYS_RECV => {
            const hv = getReg(vmh, argReg(0));
            const h = vhReal(hv);
            const cap_out_ptr = getReg(vmh, argReg(2));
            const out = winSliceUpto(window, getReg(vmh, argReg(1)), P9_MAX);
            if (h == 0 or out == null) {
                setRet(vmh, denied());
                return null;
            }
            var cap: u32 = 0;
            const r = sys.recv(h, out.?, &cap);
            if (r >= 0 and cap != 0) {
                const vc = vhAlloc(cap); // 0 if the table is full
                // Tag the returned service cap with a mount prefix so its walks can
                // be path-filtered. Two sources: a pending lookup reply (the cap is
                // a freshly looked-up mount), or a walk_redirect reply (the cap is a
                // submount, whose prefix is the walked path minus the remainder).
                var pending: ?[]const u8 = null;
                if (hv < VHANDLES) {
                    pending = vh_pending[@intCast(hv)];
                    vh_pending[@intCast(hv)] = null;
                }
                if (vc != 0) {
                    if (pending) |pfx| {
                        vh_prefix[vc] = pfx;
                    } else if (fs_allow_n > 0) {
                        if (ferrite.p9.decodeResponse(out.?[0..@intCast(r)])) |dec| {
                            if (dec.resp == .walk_redirect) {
                                if (submountPrefix(dec.resp.walk_redirect.remaining_path)) |sp| vh_prefix[vc] = sp;
                            }
                        } else |_| {}
                    }
                }
                if (cap_out_ptr != 0) {
                    if (winSlice(window, cap_out_ptr, 4)) |cd| std.mem.writeInt(u32, cd[0..4], vc, .little);
                }
            }
            setRet(vmh, @bitCast(@as(i64, r)));
        },
        SYS_CAP_DUP => {
            const h = vhReal(getReg(vmh, argReg(0)));
            if (h == 0) {
                setRet(vmh, denied());
                return null;
            }
            const r = sys.capDup(h);
            if (r < 0) setRet(vmh, @bitCast(@as(i64, r))) else setRet(vmh, allocOrErr(@intCast(r)));
        },
        SYS_CAP_RELEASE => {
            const v = getReg(vmh, argReg(0));
            const h = vhReal(v);
            if (h != 0) _ = sys.capRelease(h);
            vhFree(v);
            setRet(vmh, 0);
        },

        else => setRet(vmh, denied()),
    }
    return null;
}
