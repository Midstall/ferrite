const std = @import("std");
const arch = @import("arch");
const heap = @import("heap.zig");
const ipc = @import("ipc.zig");
const irq = @import("irq.zig");
const sync = @import("sync.zig");

inline fn irqSave() bool {
    const prev = arch.cpu.irqsEnabled();
    arch.cpu.disableIrq();
    return prev;
}
inline fn irqRestore(prev: bool) void {
    if (prev) arch.cpu.enableIrq();
}

pub const Kind = enum(u8) {
    null,
    channel_send,
    channel_recv,
    mem_region,
    aspace,
    thread,
    process,
    irq,
};

/// Per-process opaque handle. 0 is reserved for "no handle".
pub const Handle = u32;

pub const NULL_HANDLE: Handle = 0;

pub const Rights = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    map: bool = false,
    grant: bool = false,
    spawn: bool = false,
    _pad: u27 = 0,
};

pub const Entry = struct {
    kind: Kind,
    rights: Rights,
    /// Type discriminated by `kind`.
    object: ?*anyopaque,
    /// Encodes (next_index + 1) when `kind == .null`. 0 means tail.
    next_free_plus_one: u32,
};

const empty_entry: Entry = .{
    .kind = .null,
    .rights = .{},
    .object = null,
    .next_free_plus_one = 0,
};

pub const Table = struct {
    entries: []Entry,
    /// 1-based index of the first free slot (0 = no free slots).
    free_head_plus_one: u32,
    /// IRQ-safe lock: a process's threads (and IPC transfers into it) mutate
    /// the free list concurrently. Without this, two mints race `free_head`,
    /// hand out the SAME slot, and the double-allocated entry becomes a cap
    /// alias / use-after-free when one side revokes. Held ONLY across free-list
    /// + entry mutation, never across object unref/destroy (which take other
    /// locks). See [[ferrite-audio-sink-refactor]].
    lock: sync.Spinlock = .{},

    pub const Error = error{ OutOfHandles, BadHandle, WrongKind, OutOfMemory };

    pub fn init(capacity: usize) Error!Table {
        const entries = heap.allocator().alloc(Entry, capacity) catch return error.OutOfMemory;
        entries[0] = empty_entry;
        var i: usize = 1;
        while (i < capacity) : (i += 1) {
            entries[i] = empty_entry;
            entries[i].next_free_plus_one = if (i + 1 < capacity) @intCast(i + 1) else 0;
        }
        return .{
            .entries = entries,
            .free_head_plus_one = if (capacity > 1) 1 else 0,
        };
    }

    pub fn deinit(self: *Table) void {
        // Release every held cap so the underlying objects' refcounts drop -
        // otherwise channels held by an exiting process leak and, worse, never
        // reach send_refs/recv_refs 0, so pipe readers/writers never get EOF.
        for (self.entries) |slot| {
            if (slot.kind != .null) unrefObject(slot.kind, slot.object);
        }
        heap.allocator().free(self.entries);
    }

    pub fn mint(self: *Table, kind: Kind, rights: Rights, object: ?*anyopaque) Error!Handle {
        const prev = irqSave();
        self.lock.acquire();
        if (self.free_head_plus_one == 0) {
            self.lock.release();
            irqRestore(prev);
            return error.OutOfHandles;
        }
        const idx = self.free_head_plus_one;
        const slot = &self.entries[idx];
        self.free_head_plus_one = slot.next_free_plus_one;
        slot.* = .{
            .kind = kind,
            .rights = rights,
            .object = object,
            .next_free_plus_one = 0,
        };
        refObject(kind, object); // atomic refcount bump; no nested lock
        self.lock.release();
        irqRestore(prev);
        return @intCast(idx);
    }

    fn refObject(kind: Kind, object: ?*anyopaque) void {
        const obj = object orelse return;
        switch (kind) {
            .channel_send => {
                const ch: *ipc.Channel = @ptrCast(@alignCast(obj));
                ch.refSend();
            },
            .channel_recv => {
                const ch: *ipc.Channel = @ptrCast(@alignCast(obj));
                ch.refRecv();
            },
            else => {},
        }
    }

    fn unrefObject(kind: Kind, object: ?*anyopaque) void {
        const obj = object orelse return;
        switch (kind) {
            .channel_send => {
                const ch: *ipc.Channel = @ptrCast(@alignCast(obj));
                ch.unrefSend();
            },
            .channel_recv => {
                const ch: *ipc.Channel = @ptrCast(@alignCast(obj));
                ch.unrefRecv();
            },
            .irq => {
                const ic: *irq.IrqCap = @ptrCast(@alignCast(obj));
                irq.release(heap.allocator(), ic);
            },
            else => {},
        }
    }

    pub fn get(self: *const Table, h: Handle, expect: Kind) Error!*const Entry {
        if (h == NULL_HANDLE or h >= self.entries.len) return error.BadHandle;
        const slot = &self.entries[h];
        if (slot.kind == .null) return error.BadHandle;
        if (slot.kind != expect) return error.WrongKind;
        return slot;
    }

    pub fn getMut(self: *Table, h: Handle, expect: Kind) Error!*Entry {
        if (h == NULL_HANDLE or h >= self.entries.len) return error.BadHandle;
        const slot = &self.entries[h];
        if (slot.kind == .null) return error.BadHandle;
        if (slot.kind != expect) return error.WrongKind;
        return slot;
    }

    pub fn revoke(self: *Table, h: Handle) void {
        if (h == NULL_HANDLE or h >= self.entries.len) return;
        const prev = irqSave();
        self.lock.acquire();
        const slot = &self.entries[h];
        if (slot.kind == .null) {
            self.lock.release();
            irqRestore(prev);
            return;
        }
        // Capture the object, free the slot under the lock, THEN unref outside
        // it - unrefObject can destroy (freePages + heap), which take other
        // locks and must never run under this spinlock.
        const kind = slot.kind;
        const object = slot.object;
        slot.* = .{
            .kind = .null,
            .rights = .{},
            .object = null,
            .next_free_plus_one = self.free_head_plus_one,
        };
        self.free_head_plus_one = @intCast(h);
        self.lock.release();
        irqRestore(prev);
        unrefObject(kind, object);
    }

    /// Caller assumes ownership of the ref. Pair with `mintNoRef` on the
    /// receiver or `dropTransferred` if nobody claims it.
    pub fn clearNoUnref(self: *Table, h: Handle) void {
        if (h == NULL_HANDLE or h >= self.entries.len) return;
        const prev = irqSave();
        self.lock.acquire();
        defer {
            self.lock.release();
            irqRestore(prev);
        }
        const slot = &self.entries[h];
        if (slot.kind == .null) return;
        slot.* = .{
            .kind = .null,
            .rights = .{},
            .object = null,
            .next_free_plus_one = self.free_head_plus_one,
        };
        self.free_head_plus_one = @intCast(h);
    }

    /// For a cap that already holds its ref (came in via IPC transfer).
    pub fn mintNoRef(self: *Table, kind: Kind, rights: Rights, object: ?*anyopaque) Error!Handle {
        const prev = irqSave();
        self.lock.acquire();
        if (self.free_head_plus_one == 0) {
            self.lock.release();
            irqRestore(prev);
            return error.OutOfHandles;
        }
        const idx = self.free_head_plus_one;
        const slot = &self.entries[idx];
        self.free_head_plus_one = slot.next_free_plus_one;
        slot.* = .{
            .kind = kind,
            .rights = rights,
            .object = object,
            .next_free_plus_one = 0,
        };
        self.lock.release();
        irqRestore(prev);
        return @intCast(idx);
    }

    pub fn dropTransferred(kind: Kind, object: ?*anyopaque) void {
        unrefObject(kind, object);
    }

    pub fn transfer(src: *Table, dst: *Table, h: Handle) Error!Handle {
        if (h == NULL_HANDLE or h >= src.entries.len) return error.BadHandle;
        const src_slot = &src.entries[h];
        if (src_slot.kind == .null) return error.BadHandle;
        const new_handle = try dst.mint(src_slot.kind, src_slot.rights, src_slot.object);
        src.revoke(h);
        return new_handle;
    }
};
