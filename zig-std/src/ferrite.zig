const std = @import("std");

pub const syscall = @import("ferrite/syscall.zig");
pub const p9 = @import("ferrite/p9.zig");
pub const uri = @import("ferrite/uri.zig");
pub const nameserver = @import("ferrite/nameserver.zig");
pub const fs = @import("ferrite/fs.zig");
pub const barrier = @import("ferrite/barrier.zig");
pub const io = @import("ferrite/io.zig");
pub const Io = io;
pub const start = @import("ferrite/start.zig");
pub const system = @import("ferrite/system.zig");

pub var argv: []const [*:0]const u8 = &.{};

pub const writeConsole = syscall.writeConsole;
pub const readConsole = syscall.readConsole;
pub const debugPrint = syscall.debugPrint;
pub const send = syscall.send;
pub const recv = syscall.recv;
pub const exit = syscall.exit;
pub const sigStatus = syscall.sigStatus;
pub const isEnforcing = syscall.isEnforcing;
pub const keyCount = syscall.keyCount;
pub const spawn = syscall.spawn;
pub const spawnArgs = syscall.spawnArgs;
pub const spawnArgsStdio = syscall.spawnArgsStdio;
pub const spawnNs = syscall.spawnNs;
pub const pipe = syscall.pipe;
pub const Pipe = syscall.Pipe;
pub const SPAWN_NS_CLEAR = syscall.SPAWN_NS_CLEAR;
pub const threadSpawn = syscall.threadSpawn;
pub const kill = syscall.kill;
pub const wait = syscall.wait;
pub const tryWait = syscall.tryWait;
pub const initrdSize = syscall.initrdSize;
pub const initrdRead = syscall.initrdRead;
pub const readInitrdFile = syscall.readInitrdFile;
pub const initrdWalk = syscall.initrdWalk;
pub const InitrdEntry = syscall.InitrdEntry;
pub const ttyRaw = syscall.ttyRaw;
pub const ttyFgSet = syscall.ttyFgSet;
pub const ttyKillFg = syscall.ttyKillFg;
pub const clockMono = syscall.clockMono;
pub const clockBoot = syscall.clockBoot;
pub const uptimeNs = syscall.uptimeNs;
pub const nanosleep = syscall.nanosleep;
pub const pciCfgRead = syscall.pciCfgRead;
pub const pciCfgWrite = syscall.pciCfgWrite;
pub const ProcEntry = syscall.ProcEntry;
pub const procList = syscall.procList;
pub const ProcStat = syscall.ProcStat;
pub const procStat = syscall.procStat;
pub const handlePid = syscall.handlePid;
pub const killPid = syscall.killPid;
pub const setpgid = syscall.setpgid;
pub const getpgid = syscall.getpgid;
pub const signalPid = syscall.signalPid;
pub const sigaction = syscall.sigaction;
pub const SIGINT = syscall.SIGINT;
pub const SIGKILL = syscall.SIGKILL;
pub const SIGTERM = syscall.SIGTERM;
pub const getUid = syscall.getUid;
pub const setUid = syscall.setUid;
pub const dtbSize = syscall.dtbSize;
pub const dtbRead = syscall.dtbRead;
pub const acpiSize = syscall.acpiSize;
pub const acpiRead = syscall.acpiRead;
pub const probe = @import("ferrite/probe.zig");
pub const panic = @import("ferrite/panic.zig").panic;
pub const uname = syscall.uname;
pub const UnameInfo = syscall.UnameInfo;
pub const memInfo = syscall.memInfo;
pub const MemInfo = syscall.MemInfo;
pub const mmioCreate = syscall.mmioCreate;
pub const mmap = syscall.mmap;
pub const dmaAlloc = syscall.dmaAlloc;
pub const allocPages = syscall.allocPages;
pub const freePages = syscall.freePages;
pub const pageSize = syscall.pageSize;
pub const Priority = syscall.Priority;
pub const setThreadPriority = syscall.setThreadPriority;
pub const setThreadDeadline = syscall.setThreadDeadline;
pub const PROT_READ = syscall.PROT_READ;
pub const PROT_WRITE = syscall.PROT_WRITE;
pub const PROT_EXEC = syscall.PROT_EXEC;
pub const irqCreate = syscall.irqCreate;
pub const irqListen = syscall.irqListen;
pub const irqAck = syscall.irqAck;
pub const channelCreate = syscall.channelCreate;
pub const nsBind = syscall.nsBind;
pub const nsLookup = syscall.nsLookup;
pub const capDup = syscall.capDup;
pub const capRelease = syscall.capRelease;
pub const yield = syscall.yield;
pub const exec = syscall.exec;
pub const execStdio = syscall.execStdio;
pub const SigStatus = syscall.SigStatus;

// Per-process stdio. stdin/stdout/stderr are inherited from the parent as
// channel handles bound in the namespace ("stdin" = recv end, "stdout"/"stderr"
// = send ends). When unset (handle 0) we fall back to the global console
// (UART/tty), so a process spawned without explicit stdio behaves as before.
// A pipe is just a channel; the shell wires them up for `|` and `< > >>`.

pub const STDIO_CHUNK: usize = 4096;

var stdout_handle: u32 = 0;
var stdout_resolved: bool = false;
var stdin_handle: u32 = 0;
var stdin_resolved: bool = false;

fn stdoutChannel() u32 {
    if (!stdout_resolved) {
        stdout_resolved = true;
        const r = nsLookup("stdout");
        if (r > 0) stdout_handle = @intCast(r);
    }
    return stdout_handle;
}

fn stdinChannel() u32 {
    if (!stdin_resolved) {
        stdin_resolved = true;
        const r = nsLookup("stdin");
        if (r > 0) stdin_handle = @intCast(r);
    }
    return stdin_handle;
}

/// Write to stdout: the inherited channel if present, else the console. On a
/// closed channel (reader gone) the remainder is dropped (SIGPIPE territory).
pub fn writeStdout(bytes: []const u8) void {
    const h = stdoutChannel();
    var rest = bytes;
    if (h != 0) {
        while (rest.len > 0) {
            const n = @min(rest.len, STDIO_CHUNK);
            if (send(h, rest[0..n], 0) != 0) return; // channel closed/broken
            rest = rest[n..];
        }
        return;
    }
    while (rest.len > 0) {
        const n = @min(rest.len, 4096);
        _ = writeConsole(rest[0..n]);
        rest = rest[n..];
    }
}

var stdin_stage: [STDIO_CHUNK]u8 = undefined;
var stdin_have: usize = 0;
var stdin_pos: usize = 0;

/// Read from stdin: the inherited channel if present, else the console. Returns
/// 0 on EOF (the write end closed). One channel message is staged and doled out
/// across reads since the kernel delivers a whole message per recv.
pub fn readStdin(buf: []u8) usize {
    if (buf.len == 0) return 0;
    const h = stdinChannel();
    if (h == 0) {
        const r = readConsole(buf);
        return if (r > 0) @intCast(r) else 0;
    }
    if (stdin_pos >= stdin_have) {
        const n = recv(h, &stdin_stage, null);
        if (n <= 0) return 0; // EOF (closed) or error
        stdin_have = @intCast(n);
        stdin_pos = 0;
    }
    const avail = stdin_have - stdin_pos;
    const take = @min(avail, buf.len);
    @memcpy(buf[0..take], stdin_stage[stdin_pos..][0..take]);
    stdin_pos += take;
    return take;
}

fn writeChunked(bytes: []const u8) void {
    writeStdout(bytes);
}

/// Stand-in for `std.Io.Writer` that bypasses the std vtable indirection.
///
/// Why this exists: x86_64 Zig 0.16 ReleaseFast compiles the std.Io.Writer
/// vtable's `drain` with sret return (rdi=sret), but the indirect call
/// sites we observed pass rdi=NULL (the call site emits a non-sret signature
/// for the same `*const fn (...) Error!usize` type). Result: drain's
/// epilogue writes to NULL+8, page-faults. This wrapper avoids the
/// vtable entirely. `print` formats into a stack buffer and calls
/// `writeConsole` directly. drain is no longer reachable.
pub const ConsoleWriter = struct {
    pub fn print(self: ConsoleWriter, comptime fmt: []const u8, args: anytype) error{WriteFailed}!void {
        _ = self;
        var buf: [4096]u8 = undefined;
        // On oversized prints emit the first 4 KB rather than nothing.
        if (std.fmt.bufPrint(&buf, fmt, args)) |s| {
            writeChunked(s);
        } else |_| {
            // Buffer too small: write what fits, then a truncation marker.
            const got = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..buf.len];
            writeChunked(got);
            writeChunked("[truncated]\n");
        }
    }

    pub fn writeAll(self: ConsoleWriter, bytes: []const u8) error{WriteFailed}!void {
        _ = self;
        writeChunked(bytes);
    }
};

pub var console: ConsoleWriter = .{};

pub fn lookup(uri_str: []const u8) fs.Error!u32 {
    const parts = uri.parse(uri_str) catch return error.BadUri;
    var prefix_buf: [256]u8 = undefined;
    const prefix = uri.formatPrefix(&prefix_buf, parts) catch return error.BadUri;

    const ns_h = nsLookup("nameserver");
    if (ns_h < 0) return error.NoNameserver;

    const packed_h = channelCreate(0);
    if (packed_h < 0) return error.NoMemory;
    const reply_send: u32 = @truncate(@as(u64, @bitCast(packed_h)));
    const reply_recv: u32 = @truncate(@as(u64, @bitCast(packed_h)) >> 32);

    var req_buf: [p9.MAX_MSG]u8 = undefined;
    const req_len = p9.encodeLookup(&req_buf, 1, prefix) catch return error.Protocol;
    const sr = send(@intCast(ns_h), req_buf[0..req_len], reply_send);
    if (sr != 0) return error.SendFailed;

    var resp_buf: [p9.MAX_MSG]u8 = undefined;
    var svc_cap: u32 = 0;
    const rn = recv(reply_recv, &resp_buf, &svc_cap);
    if (rn < 0) return error.RecvFailed;

    const decoded = p9.decodeResponse(resp_buf[0..@intCast(rn)]) catch return error.Protocol;
    return switch (decoded.resp) {
        .lookup => svc_cap,
        .err => error.NotFound,
        else => error.Protocol,
    };
}
