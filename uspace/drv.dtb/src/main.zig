const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const p9 = ferrite.p9;
const fs = ferrite.fs;

const DEV_NAME = "dtb";

const MAX_FIDS = 16;

const Fid = struct {
    used: bool = false,
    opened: bool = false,
};

const State = struct {
    fids: [MAX_FIDS]Fid = @splat(.{}),
    size: u64 = 0,
};

var state: State = .{};

pub fn main() void {
    const total = ferrite.dtbSize();
    if (total <= 0) {
        ferrite.console.print("[drv.dtb] no DTB present. Exiting\n", .{}) catch {};
        return;
    }
    state.size = @intCast(total);
    state.fids[0] = .{ .used = true, .opened = true };

    const ch = ferrite.channelCreate(0);
    if (ch < 0) return;
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);

    fs.registerDevice(DEV_NAME, .char, svc_send) catch |e| {
        ferrite.console.print("[drv.dtb] registerDevice failed: {t}\n", .{e}) catch {};
        return;
    };

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

fn onWalk(s: *State, fid: u32, path: []const u8) fs.HandlerError!fs.WalkResult {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    if (it.next() != null) return error.NotFound;
    var i: u32 = 1;
    while (i < MAX_FIDS) : (i += 1) {
        if (!s.fids[i].used) {
            s.fids[i] = .{ .used = true, .opened = false };
            return .{ .bound = i };
        }
    }
    return error.ServerBusy;
}

fn onOpen(s: *State, fid: u32, _: p9.Mode) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    s.fids[fid].opened = true;
}

fn onRead(s: *State, fid: u32, offset: u64, out: []u8) fs.HandlerError!usize {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    if (offset >= s.size) return 0;
    const n = ferrite.dtbRead(offset, out);
    if (n < 0) return error.BadOp;
    return @intCast(n);
}

fn onWrite(_: *State, _: u32, _: u64, _: []const u8) fs.HandlerError!u32 {
    return error.BadOp;
}

fn onClose(s: *State, fid: u32) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    if (fid != 0) s.fids[fid] = .{};
}

fn onStatus(s: *State, fid: u32) fs.HandlerError!p9.StatusReply {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    return .{ .kind = .file, .size = s.size };
}
