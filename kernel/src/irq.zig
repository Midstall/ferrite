const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch");
const ipc = @import("ipc.zig");
const sync = @import("sync.zig");

pub const MAX_IRQ: u32 = 256;

pub const Error = error{ BadSource, AlreadyClaimed, Unsupported };

pub const IrqCap = struct {
    irq: u32,
    /// Null until `SYS_IRQ_LISTEN` binds.
    channel: ?*ipc.Channel = null,
    /// Next listener on the same IRQ. PCI INTx lines are shared (wire-ORed), so
    /// several devices' drivers subscribe to one GIC SPI; dispatch wakes them all.
    next: ?*IrqCap = null,
};

/// Head of the listener list per IRQ.
var caps: [MAX_IRQ]?*IrqCap = @splat(null);
/// Listeners still owing an ack for the current (masked) interrupt episode. The
/// line stays masked until this hits 0 so a shared level-triggered INTx isn't
/// re-delivered (storm) before every device has read its ISR and de-asserted.
/// REQUIRES every listener to always be waiting (a thread always blocked on recv
/// that always acks); net and input use that model. Inline request/response
/// drivers must NOT use this path: when idle they never ack (stranding the mask),
/// and unmask-on-first-ack livelocks against always-waiting siblings, so they
/// poll instead. See timer.zig pattern + ferrite-irq-userspace.
var ack_pending: [MAX_IRQ]u32 = @splat(0);
/// Serializes the listener lists + ack_pending between dispatch (IRQ context)
/// and claim/listen/ack/release (thread context). Thread paths disable IRQs
/// while held so a same-CPU dispatch can't deadlock on it.
var lock: sync.Spinlock = .{};

inline fn irqSave() bool {
    const enabled = arch.cpu.irqsEnabled();
    arch.cpu.disableIrq();
    return enabled;
}
inline fn irqRestore(prev: bool) void {
    if (prev) arch.cpu.enableIrq();
}

fn dispatch(irq: u32) void {
    if (irq >= MAX_IRQ) return;
    // IRQ context: IRQs already masked on this CPU; just serialize vs thread paths.
    lock.acquire();
    defer lock.release();

    // Mask the (possibly shared, level-triggered) line until every woken listener
    // acks. EOI without masking re-delivers immediately since each device holds
    // the line asserted until its driver reads the ISR. Waiting for all acks (not
    // just the first) avoids re-firing before a still-asserting sibling de-asserts.
    disable(irq);

    var pushed: u32 = 0;
    var node = caps[irq];
    while (node) |c| : (node = c.next) {
        const ch = c.channel orelse continue;
        ch.tryPush(.{ .payload = undefined, .payload_len = 0, .cap_xfer = null }) catch continue;
        pushed += 1;
    }

    // No one woke (no listeners, or all channels full): don't strand the line
    // masked. A full channel means that driver is behind; the line will re-fire.
    if (pushed == 0) {
        enable(irq);
        return;
    }
    ack_pending[irq] = pushed;
}

const trampolines: [MAX_IRQ]*const fn (*arch.traps.Frame) void = blk: {
    var arr: [MAX_IRQ]*const fn (*arch.traps.Frame) void = undefined;
    for (&arr, 0..) |*slot, i| {
        slot.* = &struct {
            const n: u32 = @intCast(i);
            fn h(_: *arch.traps.Frame) void {
                dispatch(n);
            }
        }.h;
    }
    break :blk arr;
};

pub fn claim(allocator: std.mem.Allocator, irq: u32) Error!*IrqCap {
    if (irq >= MAX_IRQ) return error.BadSource;

    const c = allocator.create(IrqCap) catch return error.BadSource;
    c.* = .{ .irq = irq };

    const prev = irqSave();
    defer irqRestore(prev);
    lock.acquire();
    defer lock.release();

    const first = caps[irq] == null;
    c.next = caps[irq];
    caps[irq] = c;
    // Register the dispatch trampoline once, on the first listener for this IRQ.
    if (first) arch.traps.registerIrq(irq, trampolines[irq]);
    return c;
}

pub fn listen(c: *IrqCap, channel: *ipc.Channel) void {
    const prev = irqSave();
    defer irqRestore(prev);
    lock.acquire();
    defer lock.release();

    // Hold a ref on the channel for as long as the IRQ is bound to it. Without
    // this, if the listener drops all its channel caps (e.g. the driver exits)
    // the channel buffer is freed while `dispatch` can still tryPush into it ->
    // use-after-free. release() drops this ref. (ferrite-ipc-channel-uaf.)
    if (c.channel) |old| old.unref();
    channel.ref();
    c.channel = channel;
    // Don't unmask mid-episode for a sibling listener that hasn't acked yet.
    if (ack_pending[c.irq] == 0) enable(c.irq);
}

pub fn ack(c: *IrqCap) void {
    const i = c.irq;
    if (i >= MAX_IRQ) return;
    const prev = irqSave();
    defer irqRestore(prev);
    lock.acquire();
    defer lock.release();
    if (ack_pending[i] > 0) {
        ack_pending[i] -= 1;
        if (ack_pending[i] == 0) enable(i); // last listener read its ISR: unmask
    } else {
        enable(i); // spurious/extra ack: ensure not left masked
    }
}

pub fn release(allocator: std.mem.Allocator, c: *IrqCap) void {
    const i = c.irq;
    {
        const prev = irqSave();
        defer irqRestore(prev);
        lock.acquire();
        defer lock.release();

        if (i < MAX_IRQ) {
            // Unlink c from this IRQ's listener list.
            var pp: *?*IrqCap = &caps[i];
            while (pp.*) |node| {
                if (node == c) {
                    pp.* = node.next;
                    break;
                }
                pp = &node.next;
            }
            // Last listener gone: mask the line and drop the dispatch handler.
            if (caps[i] == null) {
                disable(i);
                arch.traps.registerIrq(i, null);
                ack_pending[i] = 0;
            }
        }
    }
    if (c.channel) |ch| ch.unref(); // drop the IRQ's ref (may free the channel)
    allocator.destroy(c);
}

fn enable(irq: u32) void {
    switch (builtin.cpu.arch) {
        .aarch64 => arch.gic.enableIrq(irq),
        else => {},
    }
}

fn disable(irq: u32) void {
    switch (builtin.cpu.arch) {
        .aarch64 => arch.gic.disableIrq(irq),
        else => {},
    }
}

pub fn archSupported() bool {
    return builtin.cpu.arch == .aarch64;
}
