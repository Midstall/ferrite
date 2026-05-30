const std = @import("std");
const arch = @import("arch");
const cap = @import("cap.zig");
const cpu = @import("cpu.zig");
const heap = @import("heap.zig");
const memory = @import("memory.zig");
const process = @import("process.zig");
const sched = @import("sched.zig");
const sync = @import("sync.zig");
const thread = @import("thread.zig");

inline fn irqSave() bool {
    const prev = arch.cpu.irqsEnabled();
    arch.cpu.disableIrq();
    return prev;
}

inline fn irqRestore(prev: bool) void {
    if (prev) arch.cpu.enableIrq();
}

pub const MAX_INLINE: usize = 16 * 1024;

pub const CapXfer = struct {
    kind: cap.Kind,
    rights: cap.Rights,
    object: ?*anyopaque,
};

pub const Message = struct {
    payload: [MAX_INLINE]u8,
    payload_len: u16,
    cap_xfer: ?CapXfer,
};

pub const Channel = struct {
    buf: []Message,
    pages: usize,
    head: usize,
    tail: usize,
    count: usize,
    recv_waiters: ?*thread.Thread,
    send_waiters: ?*thread.Thread,
    closed: bool,
    /// Freed when this hits zero.
    refcount: u32,
    /// Per-direction cap counts. When senders hit zero the channel is closed so
    /// blocked readers get EOF (and vice versa) - this is what makes pipes work.
    send_refs: u32,
    recv_refs: u32,
    /// Process that paid for `buf`. Refunded on destroy. Null = kernel-only
    /// channel (e.g., bootstrap before any process exists).
    owner: ?*process.Process,
    /// IRQ-safe; wake/block must be atomic via `sched.blockReleasing`.
    lock: sync.Spinlock,

    pub const Error = error{ OutOfMemory, Closed };

    pub fn create(capacity: usize) Error!*Channel {
        if (capacity == 0) return error.OutOfMemory;
        const a = heap.allocator();
        const ch = a.create(Channel) catch return error.OutOfMemory;
        errdefer a.destroy(ch);

        const ps = memory.pageSize();
        const bytes = capacity * @sizeOf(Message);
        const npages = (bytes + @as(usize, @intCast(ps)) - 1) / @as(usize, @intCast(ps));
        const pa = memory.allocPages(npages) orelse {
            a.destroy(ch);
            return error.OutOfMemory;
        };
        const buf_ptr: [*]Message = @ptrFromInt(memory.physToVirt(pa));
        const buf = buf_ptr[0..capacity];

        const owner: ?*process.Process = if (cpu.current()) |t| process.fromThread(t) else null;
        const buf_bytes: u64 = @as(u64, npages) * @as(u64, ps);
        process.chargeKmem(owner, buf_bytes);

        ch.* = .{
            .buf = buf,
            .pages = npages,
            .head = 0,
            .tail = 0,
            .count = 0,
            .recv_waiters = null,
            .send_waiters = null,
            .closed = false,
            .refcount = 0,
            .send_refs = 0,
            .recv_refs = 0,
            .owner = owner,
            .lock = .{},
        };
        return ch;
    }

    pub fn ref(self: *Channel) void {
        _ = @atomicRmw(u32, &self.refcount, .Add, 1, .acq_rel);
    }

    pub fn unref(self: *Channel) void {
        const prev = @atomicRmw(u32, &self.refcount, .Sub, 1, .acq_rel);
        if (prev == 1) self.destroy();
    }

    // Per-direction ref tracking. A send/recv cap bumps both the total refcount
    // and its direction count; dropping the last cap of a direction closes the
    // channel so the other side unblocks with EOF (pipe semantics).
    pub fn refSend(self: *Channel) void {
        _ = @atomicRmw(u32, &self.send_refs, .Add, 1, .acq_rel);
        self.ref();
    }
    pub fn refRecv(self: *Channel) void {
        _ = @atomicRmw(u32, &self.recv_refs, .Add, 1, .acq_rel);
        self.ref();
    }
    pub fn unrefSend(self: *Channel) void {
        if (@atomicRmw(u32, &self.send_refs, .Sub, 1, .acq_rel) == 1) self.close();
        self.unref();
    }
    pub fn unrefRecv(self: *Channel) void {
        if (@atomicRmw(u32, &self.recv_refs, .Sub, 1, .acq_rel) == 1) self.close();
        self.unref();
    }

    pub fn destroy(self: *Channel) void {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const slot = (self.head + i) % self.buf.len;
            if (self.buf[slot].cap_xfer) |xf| {
                cap.Table.dropTransferred(xf.kind, xf.object);
            }
        }
        const buf_va = @intFromPtr(self.buf.ptr);
        const pa = memory.virtToPhys(buf_va);
        const ps = memory.pageSize();
        memory.freePages(pa, self.pages);
        process.refundKmem(self.owner, @as(u64, self.pages) * @as(u64, ps));
        const a = heap.allocator();
        a.destroy(self);
    }

    pub fn send(self_in: *Channel, msg: Message) Error!void {
        // Pin `self` in a register across irqSave() / blockReleasing /
        // resumed lock.acquire. Zig 0.16 ReleaseFast on x86_64 was reusing
        // the pointer's stack slot for `prev_irq: bool`, and after the byte
        // write the reloaded `self` reads 0x1. See
        // [[ferrite-zig-stack-slot-reuse-bug]].
        var self: *Channel = self_in;
        asm volatile (""
            : [out] "+r" (self),
        );
        const prev_irq = irqSave();
        self.lock.acquire();
        while (self.count == self.buf.len) {
            if (self.closed) {
                self.lock.release();
                irqRestore(prev_irq);
                return error.Closed;
            }
            const cur = cpu.current() orelse @panic("ipc.send: no current thread");
            cur.wait_next = self.send_waiters;
            self.send_waiters = cur;
            sched.blockReleasing(&self.lock);
            irqRestore(prev_irq);
            _ = irqSave();
            self.lock.acquire();
        }
        if (self.closed) {
            self.lock.release();
            irqRestore(prev_irq);
            return error.Closed;
        }

        self.buf[self.tail] = msg;
        self.tail = (self.tail + 1) % self.buf.len;
        self.count += 1;

        const w = self.recv_waiters;
        if (w) |waiter| {
            self.recv_waiters = waiter.wait_next;
            waiter.wait_next = null;
        }
        self.lock.release();
        irqRestore(prev_irq);

        // Not switchTo: preempt between pushTo(cur) and handoff(target) would lose the wake.
        if (w) |waiter| sched.wake(waiter);
    }

    pub fn recv(self_in: *Channel) Error!Message {
        var self: *Channel = self_in;
        asm volatile (""
            : [out] "+r" (self),
        );
        const prev_irq = irqSave();
        self.lock.acquire();
        while (self.count == 0) {
            if (self.closed) {
                self.lock.release();
                irqRestore(prev_irq);
                return error.Closed;
            }
            const cur = cpu.current() orelse @panic("ipc.recv: no current thread");
            cur.wait_next = self.recv_waiters;
            self.recv_waiters = cur;
            sched.blockReleasing(&self.lock);
            irqRestore(prev_irq);
            _ = irqSave();
            self.lock.acquire();
        }

        const msg = self.buf[self.head];
        self.head = (self.head + 1) % self.buf.len;
        self.count -= 1;

        const w = self.send_waiters;
        if (w) |waiter| {
            self.send_waiters = waiter.wait_next;
            waiter.wait_next = null;
        }
        self.lock.release();
        irqRestore(prev_irq);

        if (w) |waiter| sched.wake(waiter);
        return msg;
    }

    /// Safe from IRQ context. IRQs are already disabled by the trap handler.
    pub fn tryPush(self: *Channel, msg: Message) error{ Closed, WouldBlock }!void {
        self.lock.acquire();
        if (self.closed) {
            self.lock.release();
            return error.Closed;
        }
        if (self.count == self.buf.len) {
            self.lock.release();
            return error.WouldBlock;
        }
        self.buf[self.tail] = msg;
        self.tail = (self.tail + 1) % self.buf.len;
        self.count += 1;
        const w = self.recv_waiters;
        if (w) |waiter| {
            self.recv_waiters = waiter.wait_next;
            waiter.wait_next = null;
        }
        self.lock.release();
        if (w) |waiter| sched.wake(waiter);
    }

    pub fn close(self: *Channel) void {
        const prev_irq = irqSave();
        self.lock.acquire();
        self.closed = true;
        var rw = self.recv_waiters;
        self.recv_waiters = null;
        var sw = self.send_waiters;
        self.send_waiters = null;
        self.lock.release();
        irqRestore(prev_irq);
        while (rw) |w| {
            const nxt = w.wait_next;
            w.wait_next = null;
            sched.wake(w);
            rw = nxt;
        }
        while (sw) |w| {
            const nxt = w.wait_next;
            w.wait_next = null;
            sched.wake(w);
            sw = nxt;
        }
    }
};
