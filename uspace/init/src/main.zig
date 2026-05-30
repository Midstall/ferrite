const std = @import("std");
const ferrite = std.os.ferrite;
const fs = ferrite.fs;

pub const panic = ferrite.panic;

// Readiness polling, in scheduler yields. We yield (not nanosleep) between
// polls: yield is cooperative and timer-independent, so it hands the CPU to the
// service that is still coming up and converges in a handful of iterations once
// it registers. The budget only bounds the pathological case where a declared
// provides= never appears (which should not happen now that device drivers use
// wait=spawn); at ~10ms per idle yield that is a few seconds, not a wedge.
const READY_POLL_BUDGET: u32 = 2000;

const INITD_PREFIX = "etc/init.d/";

// Kernel cmdline (passed to init as argv[1..]; see kmain.runInit).
const Config = struct {
    /// "initrd" (or empty / "/dev/initrd") = no pivot. A block device path
    /// triggers the rootfs pivot (wired in a later phase).
    root: []const u8 = "initrd",
    rootfstype: []const u8 = "cpio",
    /// Post-pivot init to exec from the new root (Linux init=).
    init_path: []const u8 = "/sbin/init",
    ro: bool = true,
};

fn parseCmdline() Config {
    var cfg = Config{};
    if (ferrite.argv.len <= 1) return cfg;
    for (ferrite.argv[1..]) |arg_z| {
        const arg = std.mem.span(arg_z);
        if (std.mem.startsWith(u8, arg, "root=")) {
            cfg.root = arg["root=".len..];
        } else if (std.mem.startsWith(u8, arg, "rootfstype=")) {
            cfg.rootfstype = arg["rootfstype=".len..];
        } else if (std.mem.startsWith(u8, arg, "init=")) {
            cfg.init_path = arg["init=".len..];
        } else if (std.mem.eql(u8, arg, "ro")) {
            cfg.ro = true;
        } else if (std.mem.eql(u8, arg, "rw")) {
            cfg.ro = false;
        }
    }
    return cfg;
}

fn isInitrdRoot(root: []const u8) bool {
    return root.len == 0 or
        std.mem.eql(u8, root, "initrd") or
        std.mem.eql(u8, root, "/dev/initrd");
}

// Declarative service units (/etc/init.d/NN-name).
const MAX_UNITS = 48;
const NAME_MAX = 64;
const CMD_MAX = 128;
const ARGS_MAX = 256;
const URI_MAX = 128;
const NEEDS_MAX = 256;

const WaitMode = enum { spawn, exit, ready };
const Restart = enum { no, always, on_failure };

const Unit = struct {
    // basename within etc/init.d, e.g. "40-probe-acpi"; also the sort key.
    file: [NAME_MAX]u8 = @splat(0),
    file_len: usize = 0,
    command: [CMD_MAX]u8 = @splat(0),
    command_len: usize = 0,
    // NUL-separated argv tail for spawnArgs (path is argv[0], added by kernel).
    args: [ARGS_MAX]u8 = @splat(0),
    args_len: usize = 0,
    provides: [URI_MAX]u8 = @splat(0),
    provides_len: usize = 0,
    unless: [URI_MAX]u8 = @splat(0),
    unless_len: usize = 0,
    // comma-separated authorities that must be present before this unit starts.
    needs: [NEEDS_MAX]u8 = @splat(0),
    needs_len: usize = 0,
    wait: WaitMode = .spawn,
    restart: Restart = .no,
    valid: bool = false,

    // runtime
    pid: isize = -1,
    skipped: bool = false,

    fn fileName(self: *const Unit) []const u8 {
        return self.file[0..self.file_len];
    }
    fn cmd(self: *const Unit) []const u8 {
        return self.command[0..self.command_len];
    }
    fn argsSlice(self: *const Unit) []const u8 {
        return self.args[0..self.args_len];
    }
    fn providesSlice(self: *const Unit) []const u8 {
        return self.provides[0..self.provides_len];
    }
    fn unlessSlice(self: *const Unit) []const u8 {
        return self.unless[0..self.unless_len];
    }
    fn needsSlice(self: *const Unit) []const u8 {
        return self.needs[0..self.needs_len];
    }
};

var units: [MAX_UNITS]Unit = @splat(.{});
var unit_count: usize = 0;

// Kernel cmdline config, parsed once in main; consulted by the @rootfs unit.
var g_cfg: Config = .{};

// The authority the root filesystem is served under (the `/` mount).
const ROOTFS_AUTH = "com.midstall.ferrite.fs@v0";

pub fn main() void {
    setupNameserverChannel() orelse {
        ferrite.console.print("[init] nameserver channel setup failed. Aborting\n", .{}) catch {};
        return;
    };

    g_cfg = parseCmdline();

    loadUnits();
    if (unit_count == 0) {
        ferrite.console.print("[init] no units in {s}. Nothing to start\n", .{INITD_PREFIX}) catch {};
        return;
    }
    sortUnits();
    bringUp();
    supervise();
}

// Loading + parsing
fn loadUnits() void {
    var cursor: u64 = 0;
    var name_buf: [256]u8 = undefined;
    var body_buf: [2048]u8 = undefined;

    while (ferrite.initrdWalk(&cursor, &name_buf)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, INITD_PREFIX)) continue;
        const base = entry.name[INITD_PREFIX.len..];
        // Only direct children (no nested directories) and non-empty names.
        if (base.len == 0 or std.mem.indexOfScalar(u8, base, '/') != null) continue;
        if (base.len > NAME_MAX) continue;
        if (unit_count >= MAX_UNITS) {
            ferrite.console.print("[init] too many units, ignoring {s}\n", .{base}) catch {};
            break;
        }

        const want: usize = @min(@as(usize, @intCast(entry.size)), body_buf.len);
        const got = ferrite.initrdRead(entry.data_off, body_buf[0..want]);
        if (got <= 0) continue;

        const u = &units[unit_count];
        u.* = .{};
        @memcpy(u.file[0..base.len], base);
        u.file_len = base.len;
        parseUnit(u, body_buf[0..@intCast(got)]);
        if (u.command_len == 0) {
            ferrite.console.print("[init] {s}: no command, skipping\n", .{base}) catch {};
            continue;
        }
        u.valid = true;
        unit_count += 1;
    }
}

fn parseUnit(u: *Unit, body: []const u8) void {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = stripComment(raw);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        const val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "command")) {
            setField(&u.command, &u.command_len, val);
        } else if (std.mem.eql(u8, key, "args")) {
            setArgs(u, val);
        } else if (std.mem.eql(u8, key, "provides")) {
            setField(&u.provides, &u.provides_len, val);
        } else if (std.mem.eql(u8, key, "unless")) {
            setField(&u.unless, &u.unless_len, val);
        } else if (std.mem.eql(u8, key, "needs")) {
            setField(&u.needs, &u.needs_len, val);
        } else if (std.mem.eql(u8, key, "wait")) {
            u.wait = if (std.mem.eql(u8, val, "exit")) .exit else if (std.mem.eql(u8, val, "ready")) .ready else .spawn;
        } else if (std.mem.eql(u8, key, "restart")) {
            u.restart = if (std.mem.eql(u8, val, "always")) .always else if (std.mem.eql(u8, val, "on-failure")) .on_failure else .no;
        }
        // priority= is accepted for forward-compat but not enforced from init
        // yet: services set their own scheduling class today.
    }
}

fn setField(dst: []u8, dst_len: *usize, val: []const u8) void {
    const n = @min(val.len, dst.len);
    @memcpy(dst[0..n], val[0..n]);
    dst_len.* = n;
}

// Convert a space-separated "a b c" into the NUL-separated "a\0b\0c\0" form
// spawnArgs expects (each token NUL-terminated, including the last).
fn setArgs(u: *Unit, val: []const u8) void {
    var len: usize = 0;
    var it = std.mem.tokenizeAny(u8, val, " \t");
    while (it.next()) |tok| {
        if (len + tok.len + 1 > u.args.len) break;
        @memcpy(u.args[len..][0..tok.len], tok);
        len += tok.len;
        u.args[len] = 0;
        len += 1;
    }
    u.args_len = len;
}

fn stripComment(line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, '#')) |i| return line[0..i];
    return line;
}

// Selection sort by filename; unit_count is small (< MAX_UNITS).
fn sortUnits() void {
    var i: usize = 0;
    while (i < unit_count) : (i += 1) {
        var min = i;
        var j = i + 1;
        while (j < unit_count) : (j += 1) {
            if (std.mem.lessThan(u8, units[j].fileName(), units[min].fileName())) min = j;
        }
        if (min != i) {
            const tmp = units[i];
            units[i] = units[min];
            units[min] = tmp;
        }
    }
}

// Bring-up + supervision
fn bringUp() void {
    var i: usize = 0;
    while (i < unit_count) : (i += 1) {
        const u = &units[i];
        if (!u.valid) continue;

        if (u.unless_len > 0 and authorityPresent(u.unlessSlice())) {
            u.skipped = true;
            continue;
        }
        if (u.needs_len > 0) waitNeeds(u.needsSlice());

        startUnit(u);

        switch (u.wait) {
            .spawn => {},
            .exit => if (u.pid >= 0) {
                _ = ferrite.wait(@intCast(u.pid));
                u.pid = -1;
            },
            .ready => waitReady(u),
        }
    }
}

fn startUnit(u: *Unit) void {
    // The @rootfs sentinel mounts the root filesystem chosen by the kernel
    // cmdline (root=/rootfstype=), rather than a fixed command.
    if (std.mem.eql(u8, u.cmd(), "@rootfs")) {
        startRootfs(u);
        return;
    }
    const pid = if (u.args_len > 0)
        ferrite.spawnArgs(u.cmd(), u.argsSlice())
    else
        ferrite.spawn(u.cmd());
    u.pid = pid;
    if (pid < 0) {
        ferrite.console.print("[init] {s}: spawn({s}) failed: {d}\n", .{ u.fileName(), u.cmd(), pid }) catch {};
    }
}

// Mount the root filesystem at / using the driver for rootfstype= (looked up in
// /etc/filesystems) over the device implied by root=. root=initrd uses the boot
// cpio via /dev/initrd; otherwise root= names a block device (e.g. /dev/blk0).
fn startRootfs(u: *Unit) void {
    const device = if (isInitrdRoot(g_cfg.root)) "/dev/initrd" else g_cfg.root;
    var drv_buf: [128]u8 = undefined;
    const driver = filesystemDriver(g_cfg.rootfstype, &drv_buf) orelse {
        ferrite.console.print("[init] no fs driver for rootfstype={s}\n", .{g_cfg.rootfstype}) catch {};
        u.pid = -1;
        return;
    };
    var args: [320]u8 = undefined;
    var n: usize = 0;
    n = appendArg(&args, n, device);
    n = appendArg(&args, n, ROOTFS_AUTH);
    n = appendArg(&args, n, "/");
    u.pid = ferrite.spawnArgs(driver, args[0..n]);
    ferrite.console.print("[init] rootfs ({s}): {s} {s} -> /\n", .{ g_cfg.rootfstype, driver, device }) catch {};
}

fn appendArg(buf: []u8, n: usize, s: []const u8) usize {
    if (n + s.len + 1 > buf.len) return n;
    @memcpy(buf[n..][0..s.len], s);
    buf[n + s.len] = 0;
    return n + s.len + 1;
}

// Look up the mount driver for a filesystem type in /etc/filesystems
// (format: "type binary"). Returns the binary path written into `out`.
fn filesystemDriver(fstype: []const u8, out: []u8) ?[]const u8 {
    var buf: [1024]u8 = undefined;
    const len = ferrite.readInitrdFile("etc/filesystems", &buf);
    if (len == 0) return null;
    var lines = std.mem.splitScalar(u8, buf[0..len], '\n');
    while (lines.next()) |raw| {
        const line = stripComment(raw);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var tok = std.mem.tokenizeAny(u8, trimmed, " \t");
        const t = tok.next() orelse continue;
        const bin = tok.next() orelse continue;
        if (std.mem.eql(u8, t, fstype)) {
            if (bin.len > out.len) return null;
            @memcpy(out[0..bin.len], bin);
            return out[0..bin.len];
        }
    }
    return null;
}

// Block until each comma-separated authority in `list` is present (or budget).
fn waitNeeds(list: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, list, ',');
    while (it.next()) |raw| {
        const auth = std.mem.trim(u8, raw, " \t");
        if (auth.len == 0) continue;
        var n: u32 = 0;
        while (n < READY_POLL_BUDGET) : (n += 1) {
            if (authorityPresent(auth)) break;
            ferrite.yield();
        }
    }
}

// Poll until the unit's provides authority is present. Give up early if the
// process exited without providing it (e.g. a probe that found no devices).
fn waitReady(u: *Unit) void {
    if (u.provides_len == 0) return;
    var n: u32 = 0;
    while (n < READY_POLL_BUDGET) : (n += 1) {
        if (authorityPresent(u.providesSlice())) return;
        if (u.pid >= 0 and ferrite.tryWait(@intCast(u.pid)) == 1) return;
        ferrite.yield();
    }
    ferrite.console.print("[init] {s}: timed out waiting for {s}\n", .{ u.fileName(), u.providesSlice() }) catch {};
}

fn authorityPresent(authority: []const u8) bool {
    const cap = fs.lookupService(authority) catch return false;
    _ = ferrite.capRelease(cap);
    return true;
}

// Supervise restart=always units forever. Blocks on a live one (no busy-poll)
// and respawns it when it exits; rescans after each event to cover others.
fn supervise() void {
    if (!hasRestartUnit()) {
        // Nothing to keep alive: idle without spinning hot.
        while (true) {
            var n: u32 = 0;
            while (n < 1024) : (n += 1) ferrite.yield();
        }
    }

    while (true) {
        var acted = false;
        var i: usize = 0;
        while (i < unit_count) : (i += 1) {
            const u = &units[i];
            if (u.restart != .always or u.skipped or !u.valid) continue;
            if (u.pid < 0) startUnit(u);
            if (u.pid >= 0) {
                _ = ferrite.wait(@intCast(u.pid));
                ferrite.console.print("[init] {s} exited. Respawning\n", .{u.fileName()}) catch {};
                u.pid = -1;
                acted = true;
                break;
            }
        }
        if (!acted) {
            var n: u32 = 0;
            while (n < 256) : (n += 1) ferrite.yield();
        }
    }
}

fn hasRestartUnit() bool {
    var i: usize = 0;
    while (i < unit_count) : (i += 1) {
        const u = &units[i];
        if (u.valid and !u.skipped and u.restart == .always) return true;
    }
    return false;
}

// Nameserver bootstrap (kernel-side ns holds the channel caps).
fn setupNameserverChannel() ?void {
    // Capacity 16 (kernel caps at 16) so concurrent clients don't serialize
    // through a 1-deep rendezvous queue. With cap=1 the SECOND ping's send
    // would block until nameserver finished the FIRST ping's request. That
    // is a valid pattern but it exposes a wake-path issue on x86_64.
    const packed_h = ferrite.channelCreate(16);
    if (packed_h < 0) return null;
    const send_h: u32 = @truncate(@as(u64, @bitCast(packed_h)));
    const recv_h: u32 = @truncate(@as(u64, @bitCast(packed_h)) >> 32);
    if (ferrite.nsBind("nameserver", send_h) != 0) return null;
    if (ferrite.nsBind("nameserver-recv", recv_h) != 0) return null;
}
