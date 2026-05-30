// riscv32 thread support. Two surfaces coexist:
//
//   - `contextSwitch` + `initStack`: the cooperative kernel-thread API
//     the shared kernel/src/sched.zig + thread.zig call into.
//   - `Thread` + `threads[2]`: the IRQ-frame switch demo used during
//     bring-up. Kept available for board diagnostics but unused once
//     kmain takes over.

const std = @import("std");
const traps = @import("traps.zig");
const pmp = @import("board/esp32c6/pmp.zig");

extern fn context_switch(prev_sp: *usize, next_sp: *const usize) callconv(.c) void;

pub const contextSwitch = context_switch;

/// Build a fake context_switch frame at the top of a fresh kernel-thread
/// stack so the first switch-to lands at `entry`. Layout matches the
/// 14-slot frame in `context_switch.S` (ra + s0..s11 + 1 pad slot).
pub fn initStack(stack_top: usize, entry: usize) usize {
    const frame_bytes: usize = 14 * 4;
    const sp = (stack_top - frame_bytes) & ~@as(usize, 15);
    const slots: [*]usize = @ptrFromInt(sp);
    var i: usize = 0;
    while (i < 14) : (i += 1) slots[i] = 0;
    slots[0] = entry; // ra slot - first ret in context_switch lands here
    return sp;
}

const STACK_SIZE: usize = 0x1000;

pub const Thread = struct {
    saved_sp: u32,
    aspace: ?*const pmp.Aspace = null,
    // NAPOT PMP entries require base aligned to size. If the stack
    // isn't `align(STACK_SIZE)`-aligned, U-mode pushes near the top
    // fall outside the encoded NAPOT region and trap.
    stack: [STACK_SIZE]u8 align(STACK_SIZE),

    pub fn initIn(
        self: *Thread,
        entry: *const fn () callconv(.c) noreturn,
        priv: Priv,
    ) void {
        const stack_top = @intFromPtr(&self.stack) + STACK_SIZE;
        const frame_addr = stack_top - @sizeOf(traps.Frame);
        const frame: *traps.Frame = @ptrFromInt(frame_addr);
        frame.* = std.mem.zeroes(traps.Frame);
        frame.mepc = @intCast(@intFromPtr(entry));
        const mpp: u32 = switch (priv) {
            .machine => 0b11 << 11,
            .user => 0b00 << 11,
        };
        frame.mstatus = (1 << 7) | mpp;
        self.saved_sp = @intCast(frame_addr);
        self.aspace = null;
    }

    pub fn init(self: *Thread, entry: *const fn () callconv(.c) noreturn) void {
        self.initIn(entry, .machine);
    }

    pub fn setAspace(self: *Thread, aspace: *const pmp.Aspace) void {
        self.aspace = aspace;
    }

    pub fn stackRegion(self: *const Thread) pmp.Region {
        return .{
            .base = @intCast(@intFromPtr(&self.stack)),
            .size = STACK_SIZE,
            .perms = .{ .r = true, .w = true },
        };
    }
};

pub const Priv = enum { machine, user };

pub var threads: [2]Thread align(STACK_SIZE) = undefined;
pub var current: u32 = 0;

pub fn nextThread() *Thread {
    current = (current + 1) % @as(u32, @intCast(threads.len));
    return &threads[current];
}

pub fn currentThread() *Thread {
    return &threads[current];
}
