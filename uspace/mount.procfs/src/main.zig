const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const p9 = ferrite.p9;
const fs = ferrite.fs;

const URI_PREFIX = "com.midstall.ferrite.procfs@v0";
const MOUNT_PREFIX = "/proc";

const MAX_FIDS = 32;
const MAX_PROCS = 32;

const Leaf = enum { stat, name };
const RootLeaf = enum { uptime, loadavg };

const FidKind = enum { root, pid_dir, leaf, root_leaf };

const Fid = struct {
    used: bool = false,
    opened: bool = false,
    kind: FidKind = .root,
    pid: u32 = 0,
    leaf: Leaf = .stat,
    root_leaf: RootLeaf = .uptime,
};

const State = struct {
    fids: [MAX_FIDS]Fid = @splat(.{}),
};

var state: State = .{};

pub fn main() void {
    const ch = ferrite.channelCreate(0);
    if (ch < 0) return;
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);

    fs.register(URI_PREFIX, svc_send) catch |e| {
        ferrite.console.print("[mount.procfs] register failed: {t}\n", .{e}) catch {};
        return;
    };
    fs.mount(MOUNT_PREFIX, URI_PREFIX) catch |e| switch (e) {
        // Permission = nameserver already mounted us via /etc/mounts.
        error.Permission => {},
        else => {
            ferrite.console.print("[mount.procfs] mount({s}) failed: {t}\n", .{ MOUNT_PREFIX, e }) catch {};
            return;
        },
    };

    state.fids[0] = .{ .used = true, .opened = true, .kind = .root };

    const handlers: fs.Handlers(State) = .{
        .on_walk = onWalk,
        .on_open = onOpen,
        .on_read = onRead,
        .on_write = onWrite,
        .on_close = onClose,
        .on_status = onStatus,
    };
    fs.serve(State, svc_recv, &state, &handlers);
}

fn allocFid(s: *State) ?u32 {
    var i: u32 = 1;
    while (i < MAX_FIDS) : (i += 1) {
        if (!s.fids[i].used) return i;
    }
    return null;
}

fn onWalk(s: *State, fid: u32, path: []const u8) fs.HandlerError!fs.WalkResult {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;

    var rest = path;
    while (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    while (rest.len > 0 and rest[rest.len - 1] == '/') rest = rest[0 .. rest.len - 1];

    if (rest.len == 0) {
        const new_fid = allocFid(s) orelse return error.ServerBusy;
        s.fids[new_fid] = .{ .used = true, .kind = .root };
        return .{ .bound = new_fid };
    }

    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const first = if (slash) |i| rest[0..i] else rest;
    const tail = if (slash) |i| rest[i + 1 ..] else "";

    if (tail.len == 0) {
        const root_leaf: ?RootLeaf =
            if (std.mem.eql(u8, first, "uptime")) .uptime else if (std.mem.eql(u8, first, "loadavg")) .loadavg else null;
        if (root_leaf) |rl| {
            const new_fid = allocFid(s) orelse return error.ServerBusy;
            s.fids[new_fid] = .{ .used = true, .kind = .root_leaf, .root_leaf = rl };
            return .{ .bound = new_fid };
        }
    }

    const pid = std.fmt.parseInt(u32, first, 10) catch return error.NotFound;
    if (!pidExists(pid)) return error.NotFound;

    if (tail.len == 0) {
        const new_fid = allocFid(s) orelse return error.ServerBusy;
        s.fids[new_fid] = .{ .used = true, .kind = .pid_dir, .pid = pid };
        return .{ .bound = new_fid };
    }

    const leaf: Leaf = if (std.mem.eql(u8, tail, "stat"))
        .stat
    else if (std.mem.eql(u8, tail, "name"))
        .name
    else
        return error.NotFound;

    const new_fid = allocFid(s) orelse return error.ServerBusy;
    s.fids[new_fid] = .{ .used = true, .kind = .leaf, .pid = pid, .leaf = leaf };
    return .{ .bound = new_fid };
}

fn pidExists(pid: u32) bool {
    var stat: ferrite.ProcStat = undefined;
    return ferrite.procStat(pid, &stat) == 0;
}

fn onOpen(s: *State, fid: u32, _: p9.Mode) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    s.fids[fid].opened = true;
}

fn onClose(s: *State, fid: u32) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    if (fid != 0) s.fids[fid] = .{};
}

fn onStatus(s: *State, fid: u32) fs.HandlerError!p9.StatusReply {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    return switch (s.fids[fid].kind) {
        .root, .pid_dir => .{ .kind = .dir, .size = 0 },
        .leaf, .root_leaf => .{ .kind = .file, .size = 0 },
    };
}

fn onWrite(_: *State, _: u32, _: u64, _: []const u8) fs.HandlerError!u32 {
    return error.BadOp;
}

fn onRead(s: *State, fid: u32, offset: u64, out: []u8) fs.HandlerError!usize {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;

    var buf: [4096]u8 = undefined;
    const view = switch (s.fids[fid].kind) {
        .root => renderRoot(&buf),
        .pid_dir => "stat\nname\n",
        .leaf => switch (s.fids[fid].leaf) {
            .stat => renderStat(&buf, s.fids[fid].pid),
            .name => renderName(&buf, s.fids[fid].pid),
        },
        .root_leaf => switch (s.fids[fid].root_leaf) {
            .uptime => renderUptime(&buf),
            .loadavg => renderLoadavg(&buf),
        },
    };
    if (offset >= view.len) return 0;
    const start: usize = @intCast(offset);
    const n = @min(view.len - start, out.len);
    @memcpy(out[0..n], view[start..][0..n]);
    return n;
}

fn renderRoot(buf: []u8) []const u8 {
    var entries: [MAX_PROCS]ferrite.ProcEntry = undefined;
    const n = ferrite.procList(entries[0..]);
    var fbs = std.Io.Writer.fixed(buf);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        fbs.print("{d}\n", .{entries[i].pid}) catch break;
    }
    fbs.print("uptime\nloadavg\n", .{}) catch {};
    return buf[0..fbs.end];
}

fn renderUptime(buf: []u8) []const u8 {
    // Linux /proc/uptime fmt. Idle ns isn't tracked yet; report 0.
    const up_ns = ferrite.uptimeNs();
    const up_s = up_ns / 1_000_000_000;
    const up_cs = (up_ns / 10_000_000) % 100;
    var fbs = std.Io.Writer.fixed(buf);
    fbs.print("{d}.{d:0>2} 0.00\n", .{ up_s, up_cs }) catch {};
    return buf[0..fbs.end];
}

fn renderLoadavg(buf: []u8) []const u8 {
    // Linux /proc/loadavg fmt. No load sampler yet; report placeholder.
    var entries: [MAX_PROCS]ferrite.ProcEntry = undefined;
    const n = ferrite.procList(entries[0..]);
    var alive: u32 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (entries[i].state & 1 != 0) alive += 1;
    }
    var fbs = std.Io.Writer.fixed(buf);
    fbs.print("0.00 0.00 0.00 1/{d} 0\n", .{alive}) catch {};
    return buf[0..fbs.end];
}

fn renderStat(buf: []u8, pid: u32) []const u8 {
    var stat: ferrite.ProcStat = undefined;
    if (ferrite.procStat(pid, &stat) != 0) return "";
    var fbs = std.Io.Writer.fixed(buf);
    fbs.print(
        \\pid {d}
        \\uid {d}
        \\state {d}
        \\name {s}
        \\threads {d}
        \\priority {d}
        \\user_cpu_ns {d}
        \\sys_cpu_ns {d}
        \\rss_bytes {d}
        \\kstack_bytes {d}
        \\kmem_bytes {d}
        \\
    , .{
        stat.pid,
        stat.uid,
        stat.state,
        stat.nameSlice(),
        stat.num_threads,
        stat.priority,
        stat.user_cpu_ns,
        stat.sys_cpu_ns,
        stat.rss_bytes,
        stat.kstack_bytes,
        stat.kmem_bytes,
    }) catch {};
    return buf[0..fbs.end];
}

fn renderName(buf: []u8, pid: u32) []const u8 {
    var stat: ferrite.ProcStat = undefined;
    if (ferrite.procStat(pid, &stat) != 0) return "";
    const name = stat.nameSlice();
    if (name.len + 1 > buf.len) return name;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = '\n';
    return buf[0 .. name.len + 1];
}
