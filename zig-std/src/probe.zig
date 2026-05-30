const std = @import("std");
const p9 = @import("p9.zig");
const syscall = @import("syscall.zig");

const AUTHORITY = "com.midstall.ferrite.probe@v0";

pub const DeviceInfo = p9.ProbeDeviceReply;

pub const Error = error{
    NoProbeService,
    NoMemory,
    SendFailed,
    RecvFailed,
    Protocol,
};

var cached_probe_cap: u32 = 0;

pub fn invalidateCache() void {
    if (cached_probe_cap != 0) {
        _ = syscall.capRelease(cached_probe_cap);
        cached_probe_cap = 0;
    }
}

fn getProbeCap() Error!u32 {
    if (cached_probe_cap != 0) return cached_probe_cap;

    const ns_h = syscall.nsLookup("nameserver");
    if (ns_h < 0) return error.NoProbeService;

    const lookup_packed = syscall.channelCreate(0);
    if (lookup_packed < 0) return error.NoMemory;
    const lookup_send: u32 = @truncate(@as(u64, @bitCast(lookup_packed)));
    const lookup_recv: u32 = @truncate(@as(u64, @bitCast(lookup_packed)) >> 32);
    defer _ = syscall.capRelease(lookup_recv);

    var req: [p9.MAX_MSG]u8 = undefined;
    const rlen = p9.encodeLookup(&req, 1, AUTHORITY) catch return error.Protocol;
    if (syscall.send(@intCast(ns_h), req[0..rlen], lookup_send) != 0) {
        _ = syscall.capRelease(lookup_send);
        return error.SendFailed;
    }
    var resp: [p9.MAX_MSG]u8 = undefined;
    var svc_cap: u32 = 0;
    const rn = syscall.recv(lookup_recv, &resp, &svc_cap);
    if (rn < 0) return error.RecvFailed;
    const looked = p9.decodeResponse(resp[0..@intCast(rn)]) catch return error.Protocol;
    switch (looked.resp) {
        .lookup => {},
        else => {
            if (svc_cap != 0) _ = syscall.capRelease(svc_cap);
            return error.NoProbeService;
        },
    }
    cached_probe_cap = svc_cap;
    return svc_cap;
}

/// null when no device matches; error if probe service is unreachable.
pub fn findDevice(compat: []const u8, index: u32) Error!?DeviceInfo {
    const svc_cap = try getProbeCap();

    const reply_packed = syscall.channelCreate(0);
    if (reply_packed < 0) return error.NoMemory;
    const reply_send: u32 = @truncate(@as(u64, @bitCast(reply_packed)));
    const reply_recv: u32 = @truncate(@as(u64, @bitCast(reply_packed)) >> 32);
    defer _ = syscall.capRelease(reply_recv);

    var req: [p9.MAX_MSG]u8 = undefined;
    const rlen = p9.encodeProbeDevice(&req, 1, .{ .compat = compat, .index = index }) catch return error.Protocol;
    if (syscall.send(svc_cap, req[0..rlen], reply_send) != 0) {
        _ = syscall.capRelease(reply_send);
        return error.SendFailed;
    }

    var probe_resp: [p9.MAX_MSG]u8 = undefined;
    var dummy_cap: u32 = 0;
    const prn = syscall.recv(reply_recv, &probe_resp, &dummy_cap);
    if (prn < 0) return error.RecvFailed;
    const decoded = p9.decodeResponse(probe_resp[0..@intCast(prn)]) catch return error.Protocol;
    return switch (decoded.resp) {
        .probe_device => |m| m,
        .err => null,
        else => error.Protocol,
    };
}
