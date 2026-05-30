//! ferrite-gpu: client library for drv.virtio-gpu.
//!
//! DRM-inspired, zero-copy: the driver allocates a framebuffer's backing as
//! coherent DMA, mints a `mem_region` capability over it, and grants it to the
//! client over IPC. The client maps that cap and draws directly into the
//! shared backing; `present` tells the driver to transfer+flush a damage rect
//! to the host. No pixel copies cross the process boundary.
//!
//! Supports multiple scanouts (displays) and a hardware cursor. Transport
//! mirrors fs.File.rpc: the client sends a fixed-layout request plus a
//! reply-channel send cap; create-buffer/create-cursor replies also carry the
//! backing's mem_region cap.

const std = @import("std");
const ferrite = std.os.ferrite;
const syscall = ferrite.syscall;
const p9 = ferrite.p9;

/// Nameserver URI the driver registers under.
pub const URI = "com.midstall.ferrite.gpu@v0";

/// Hardware cursor images are 64x64 (virtio-gpu fixed size).
pub const CURSOR_SIZE: u32 = 64;

pub const Op = enum(u32) {
    /// a = display id. Reply: status (0 enabled, <0 disabled/oob), width,
    /// height, count = total scanouts.
    info = 1,
    /// a = display id, b = width (0 = display width), c = height (0 = display
    /// height). Reply + mem_region cap; binds the buffer to that scanout.
    create_buffer = 2,
    /// a = display id, b = x, c = y, d = w, e = h. Transfer + flush damage.
    present = 3,
    /// Reply (64x64 B8G8R8A8) + mem_region cap. Draw the cursor with alpha.
    create_cursor = 4,
    /// a = display id, b = x, c = y, d = hot_x, e = hot_y. Upload + show.
    set_cursor = 5,
    /// a = display id, b = x, c = y. Reposition without re-upload.
    move_cursor = 6,
};

const Request = extern struct {
    op: u32,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    d: u32 = 0,
    e: u32 = 0,
};

const Reply = extern struct {
    status: i32,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    count: u32 = 0,
    _pad: u32 = 0,
};

pub const Error = error{ NoNameserver, NoService, Rpc, Denied, MapFailed };

pub const DisplayInfo = struct { width: u32, height: u32 };

pub const Buffer = struct {
    /// Mapped, writable backing. Framebuffers are XRGB (0x00RRGGBB); the cursor
    /// is ARGB (0xAARRGGBB, alpha 0 = transparent).
    pixels: []u32,
    width: u32,
    height: u32,
    stride: u32,
    cap: u32,
};

pub const Device = struct {
    svc: u32,
    reply_send: u32,
    reply_recv: u32,

    pub fn connect() Error!Device {
        const ns_h = syscall.nsLookup("nameserver");
        if (ns_h < 0) return error.NoNameserver;

        const lk = syscall.channelCreate(0);
        if (lk < 0) return error.NoService;
        const lk_send: u32 = @truncate(@as(u64, @bitCast(lk)));
        const lk_recv: u32 = @truncate(@as(u64, @bitCast(lk)) >> 32);
        defer _ = syscall.capRelease(lk_recv);

        var req: [p9.MAX_MSG]u8 = undefined;
        const n = p9.encodeLookup(&req, 1, URI) catch return error.NoService;
        if (syscall.send(@intCast(ns_h), req[0..n], lk_send) != 0) {
            _ = syscall.capRelease(lk_send);
            return error.NoService;
        }
        var resp: [p9.MAX_MSG]u8 = undefined;
        var svc: u32 = 0;
        const rn = syscall.recv(lk_recv, &resp, &svc);
        if (rn < 0) return error.NoService;
        const decoded = p9.decodeResponse(resp[0..@intCast(rn)]) catch return error.NoService;
        switch (decoded.resp) {
            .lookup => {},
            else => return error.NoService,
        }
        if (svc == 0) return error.NoService;

        const rc = syscall.channelCreate(0);
        if (rc < 0) {
            _ = syscall.capRelease(svc);
            return error.NoService;
        }
        return .{
            .svc = svc,
            .reply_send = @truncate(@as(u64, @bitCast(rc))),
            .reply_recv = @truncate(@as(u64, @bitCast(rc)) >> 32),
        };
    }

    fn rpc(self: *const Device, req: Request, out_cap: ?*u32) Error!Reply {
        const dup = syscall.capDup(self.reply_send);
        if (dup < 0) return error.Rpc;
        if (syscall.send(self.svc, std.mem.asBytes(&req), @intCast(dup)) != 0) {
            _ = syscall.capRelease(@intCast(dup));
            return error.Rpc;
        }
        var buf: [@sizeOf(Reply)]u8 = undefined;
        var cap: u32 = 0;
        const rn = syscall.recv(self.reply_recv, &buf, &cap);
        if (rn < @sizeOf(Reply)) return error.Rpc;
        const reply: *const Reply = @ptrCast(@alignCast(&buf));
        if (out_cap) |p| p.* = cap else if (cap != 0) _ = syscall.capRelease(cap);
        if (reply.status < 0) return error.Denied;
        return reply.*;
    }

    /// Number of scanouts the device exposes.
    pub fn displayCount(self: *const Device) Error!u32 {
        const r = try self.rpc(.{ .op = @intFromEnum(Op.info), .a = 0 }, null);
        return r.count;
    }

    /// Geometry of scanout `id`, or null if that scanout is disabled.
    pub fn displayInfo(self: *const Device, id: u32) ?DisplayInfo {
        const r = self.rpc(.{ .op = @intFromEnum(Op.info), .a = id }, null) catch return null;
        if (r.width == 0 or r.height == 0) return null;
        return .{ .width = r.width, .height = r.height };
    }

    /// Allocate a scanout-attached framebuffer for `display_id` and map it.
    pub fn createBuffer(self: *const Device, display_id: u32, width: u32, height: u32) Error!Buffer {
        var cap: u32 = 0;
        const r = try self.rpc(.{
            .op = @intFromEnum(Op.create_buffer),
            .a = display_id,
            .b = width,
            .c = height,
        }, &cap);
        return finishBuffer(r, cap);
    }

    /// Allocate + map a 64x64 ARGB hardware-cursor image buffer.
    pub fn createCursor(self: *const Device) Error!Buffer {
        var cap: u32 = 0;
        const r = try self.rpc(.{ .op = @intFromEnum(Op.create_cursor) }, &cap);
        return finishBuffer(r, cap);
    }

    pub fn present(self: *const Device, display_id: u32, x: u32, y: u32, w: u32, h: u32) Error!void {
        _ = try self.rpc(.{
            .op = @intFromEnum(Op.present),
            .a = display_id,
            .b = x,
            .c = y,
            .d = w,
            .e = h,
        }, null);
    }

    /// Upload the cursor image and show it at (x,y) with the given hotspot.
    pub fn setCursor(self: *const Device, display_id: u32, x: u32, y: u32, hot_x: u32, hot_y: u32) Error!void {
        _ = try self.rpc(.{
            .op = @intFromEnum(Op.set_cursor),
            .a = display_id,
            .b = x,
            .c = y,
            .d = hot_x,
            .e = hot_y,
        }, null);
    }

    pub fn moveCursor(self: *const Device, display_id: u32, x: u32, y: u32) Error!void {
        _ = try self.rpc(.{
            .op = @intFromEnum(Op.move_cursor),
            .a = display_id,
            .b = x,
            .c = y,
        }, null);
    }
};

fn finishBuffer(r: Reply, cap: u32) Error!Buffer {
    if (cap == 0) return error.MapFailed;
    const va = syscall.mmap(cap, syscall.PROT_READ | syscall.PROT_WRITE);
    if (va < 0 and va > -64) {
        _ = syscall.capRelease(cap);
        return error.MapFailed;
    }
    const base: usize = @bitCast(@as(isize, va));
    const px: [*]u32 = @ptrFromInt(base);
    return .{
        .pixels = px[0 .. (@as(usize, r.stride) * @as(usize, r.height)) / 4],
        .width = r.width,
        .height = r.height,
        .stride = r.stride,
        .cap = cap,
    };
}

// The driver imports these to decode requests / encode replies.
pub const wire = struct {
    pub const Req = Request;
    pub const Resp = Reply;
};
