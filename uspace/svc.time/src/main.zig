const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const p9 = ferrite.p9;
const fs = ferrite.fs;

const URI_PREFIX = "com.midstall.ferrite.time@v0";
const MOUNT_PREFIX = "/sys/time";

const MAX_FIDS = 16;
const ZONE_NAME_MAX = 64;
const TZIF_MAX = 16 * 1024;
// 32 KiB fits the largest IANA zone's transitions+timetypes allocations.
const TZ_ARENA_BYTES = 32 * 1024;

const Leaf = enum { utc, zone, local, iso };

const Fid = struct {
    used: bool = false,
    opened: bool = false,
    kind: enum { root, leaf } = .root,
    leaf: Leaf = .utc,
};

const State = struct {
    fids: [MAX_FIDS]Fid = @splat(.{}),
};

var state: State = .{};

var epoch_anchor: u64 = 0;
var mono_anchor: u64 = 0;
var zone_name_buf: [ZONE_NAME_MAX]u8 = @splat(0);
var zone_name_len: usize = 0;
var tzif_buf: [TZIF_MAX]u8 = undefined;
var tzif_len: usize = 0;
var tz_arena: [TZ_ARENA_BYTES]u8 = undefined;
var tz_fba: std.heap.FixedBufferAllocator = undefined;
var loaded_tz: ?std.tz.Tz = null;

pub fn main() void {
    mono_anchor = ferrite.clockMono();

    loadInitialZone();

    const ch = ferrite.channelCreate(0);
    if (ch < 0) return;
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);

    fs.register(URI_PREFIX, svc_send) catch |e| {
        ferrite.console.print("[svc.time] register failed: {t}\n", .{e}) catch {};
        return;
    };
    fs.mount(MOUNT_PREFIX, URI_PREFIX) catch |e| switch (e) {
        error.Permission => {},
        else => {
            ferrite.console.print("[svc.time] mount({s}) failed: {t}\n", .{ MOUNT_PREFIX, e }) catch {};
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

fn loadInitialZone() void {
    var buf: [128]u8 = undefined;
    const n = ferrite.readInitrdFile("etc/timezone", &buf);
    // TODO: read from fs, not initrd
    var name: []const u8 = "UTC";
    if (n > 0) {
        const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (trimmed.len > 0 and trimmed.len <= ZONE_NAME_MAX) name = trimmed;
    }
    setZone(name);
}

fn setZone(name: []const u8) void {
    if (name.len == 0 or name.len > ZONE_NAME_MAX) return;
    @memcpy(zone_name_buf[0..name.len], name);
    zone_name_len = name.len;
    loadTzif(name);
}

fn loadTzif(name: []const u8) void {
    loaded_tz = null;
    tzif_len = 0;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "etc/zoneinfo/{s}", .{name}) catch return;
    // TODO: read from fs, not initrd
    const n = ferrite.readInitrdFile(path, &tzif_buf);
    if (n == 0) return;
    tzif_len = n;

    tz_fba = std.heap.FixedBufferAllocator.init(&tz_arena);
    var reader: std.Io.Reader = .fixed(tzif_buf[0..tzif_len]);
    loaded_tz = std.tz.Tz.parse(tz_fba.allocator(), &reader) catch |e| blk: {
        ferrite.console.print("[svc.time] tz parse {s} failed: {t}\n", .{ name, e }) catch {};
        break :blk null;
    };
}

fn onWalk(s: *State, fid: u32, path: []const u8) fs.HandlerError!fs.WalkResult {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    var trimmed = path;
    while (trimmed.len > 0 and trimmed[0] == '/') trimmed = trimmed[1..];
    if (trimmed.len == 0) {
        var i: u32 = 1;
        while (i < MAX_FIDS) : (i += 1) {
            if (!s.fids[i].used) {
                s.fids[i] = .{ .used = true, .kind = .root };
                return .{ .bound = i };
            }
        }
        return error.ServerBusy;
    }
    const leaf: Leaf = if (std.mem.eql(u8, trimmed, "utc"))
        .utc
    else if (std.mem.eql(u8, trimmed, "zone"))
        .zone
    else if (std.mem.eql(u8, trimmed, "local"))
        .local
    else if (std.mem.eql(u8, trimmed, "iso"))
        .iso
    else
        return error.NotFound;
    var i: u32 = 1;
    while (i < MAX_FIDS) : (i += 1) {
        if (!s.fids[i].used) {
            s.fids[i] = .{ .used = true, .kind = .leaf, .leaf = leaf };
            return .{ .bound = i };
        }
    }
    return error.ServerBusy;
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
        .root => .{ .kind = .dir, .size = 0 },
        .leaf => .{ .kind = .file, .size = 0 },
    };
}

fn onRead(s: *State, fid: u32, offset: u64, out: []u8) fs.HandlerError!usize {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    var rbuf: [128]u8 = undefined;
    const view: []const u8 = switch (s.fids[fid].kind) {
        .root => "utc\nzone\nlocal\niso\n",
        .leaf => switch (s.fids[fid].leaf) {
            .utc => formatUtc(&rbuf),
            .zone => zone_name_buf[0..zone_name_len],
            .local => formatLocal(&rbuf, false),
            .iso => formatLocal(&rbuf, true),
        },
    };
    if (offset >= view.len) return 0;
    const start: usize = @intCast(offset);
    const n = @min(view.len - start, out.len);
    @memcpy(out[0..n], view[start..][0..n]);
    return n;
}

fn onWrite(s: *State, fid: u32, _: u64, data: []const u8) fs.HandlerError!u32 {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    if (s.fids[fid].kind != .leaf) return error.BadOp;
    const view = std.mem.trim(u8, data, " \t\r\n");
    switch (s.fids[fid].leaf) {
        .utc => {
            const secs = std.fmt.parseInt(u64, view, 10) catch return error.BadOp;
            epoch_anchor = secs;
            mono_anchor = ferrite.clockMono();
            return @intCast(data.len);
        },
        .zone => {
            if (view.len == 0 or view.len > ZONE_NAME_MAX) return error.BadOp;
            setZone(view);
            return @intCast(data.len);
        },
        else => return error.BadOp,
    }
}

fn currentUtc() u64 {
    if (epoch_anchor == 0) return 0;
    const now_mono = ferrite.clockMono();
    const delta_ns = now_mono -% mono_anchor;
    return epoch_anchor + delta_ns / std.time.ns_per_s;
}

fn formatUtc(buf: []u8) []const u8 {
    const t = currentUtc();
    const s = std.fmt.bufPrint(buf, "{d}\n", .{t}) catch return "";
    return s;
}

fn formatLocal(buf: []u8, iso: bool) []const u8 {
    const utc = currentUtc();
    const lookup = lookupZone(utc);
    const local = @as(i64, @intCast(utc)) + @as(i64, lookup.utoff);
    const date = civilFromDays(@divFloor(local, 86_400));
    const sod = @mod(local, 86_400);
    const hh: u8 = @intCast(@divTrunc(sod, 3600));
    const mm: u8 = @intCast(@divTrunc(@mod(sod, 3600), 60));
    const ss: u8 = @intCast(@mod(sod, 60));
    if (iso) {
        const sign: u8 = if (lookup.utoff < 0) '-' else '+';
        const abs_off: u32 = @intCast(@abs(lookup.utoff));
        const oh: u32 = abs_off / 3600;
        const om: u32 = (abs_off % 3600) / 60;
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{c}{d:0>2}{d:0>2}\n", .{
            date.year, date.month, date.day, hh, mm, ss, sign, oh, om,
        }) catch return "";
    } else {
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {s}\n", .{
            date.year, date.month, date.day, hh, mm, ss, lookup.abbr,
        }) catch return "";
    }
}

const ZoneLookup = struct {
    utoff: i32,
    abbr: []const u8,
};

fn lookupZone(utc: u64) ZoneLookup {
    const tz = loaded_tz orelse return .{ .utoff = 0, .abbr = "UTC" };
    if (tz.timetypes.len == 0) return .{ .utoff = 0, .abbr = "UTC" };

    var active: *const std.tz.Timetype = &tz.timetypes[0];
    const utc_i: i64 = @intCast(utc);
    for (tz.transitions) |t| {
        if (t.ts > utc_i) break;
        active = t.timetype;
    }
    return .{ .utoff = active.offset, .abbr = active.name() };
}

// Howard Hinnant's days_from_civil inverse; days counted from 1970-01-01.
const CivilDate = struct { year: i32, month: u8, day: u8 };

fn civilFromDays(z_in: i64) CivilDate {
    const z = z_in + 719_468;
    const era = if (z >= 0) @divTrunc(z, 146_097) else @divTrunc(z - 146_096, 146_097);
    const doe: u64 = @intCast(z - era * 146_097);
    const yoe: u64 = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const d: u64 = doy - (153 * mp + 2) / 5 + 1;
    const m: u64 = if (mp < 10) mp + 3 else mp - 9;
    const year: i32 = @intCast(y + @as(i64, if (m <= 2) 1 else 0));
    return .{ .year = year, .month = @intCast(m), .day = @intCast(d) };
}
