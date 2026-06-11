//! Ferrite's own conduit discovery backend, over the kernel's `dtb.zig` walker.
//!
//! This is the extension point conduit is designed for: rather than use conduit's
//! bundled device-tree backend, Ferrite plugs its existing kernel FDT walker into
//! the `conduit.Backend` contract, so the kernel can drive conduit's match-rule
//! Registry (and, later, the device-class drivers) over the device tree it already
//! parses. ACPI / the userspace 9P probe model can supply further backends the
//! same way.
//!
//! Foundation scope: lowers `reg` into MMIO resources (with parent-cell
//! awareness). `ranges` translation and interrupt decoding are follow-ups.

const std = @import("std");
const conduit = @import("conduit");
const dtb = @import("dtb.zig");

const max_depth = 32;
const Cells = struct { addr: u32 = 2, size: u32 = 1 };

pub const FdtBackend = struct {
    walker: dtb.Walker,
    base_ptr: u64,
    stack: [max_depth]Cells = undefined,
    depth: usize = 0,
    cur_cells: Cells = .{},
    cur_res: conduit.ResourceList = .{},

    pub fn init() ?FdtBackend {
        const img = dtb.rawImage() orelse return null;
        const ptr: u64 = @intFromPtr(img.ptr);
        const w = dtb.open(ptr) orelse return null;
        return .{ .walker = w, .base_ptr = ptr };
    }

    pub fn any(self: *FdtBackend) conduit.Backend {
        return conduit.backend.fromImpl(self);
    }

    pub fn reset(self: *FdtBackend) void {
        self.walker = dtb.open(self.base_ptr).?;
        self.depth = 0;
        self.cur_cells = .{};
        self.cur_res = .{};
    }

    pub fn next(self: *FdtBackend) conduit.backend.Error!?conduit.backend.Node {
        while (self.walker.next()) |ev| {
            switch (ev) {
                .end => {
                    if (self.depth > 0) self.depth -= 1;
                },
                .prop => {}, // a node's props are consumed in the begin arm
                .begin => |nd| {
                    self.cur_cells = if (self.depth > 0) self.stack[self.depth - 1] else Cells{};
                    var ids = conduit.IdList{};
                    var child = Cells{};
                    self.cur_res = .{};
                    try self.scanProps(&ids, &child);
                    if (self.depth < max_depth) {
                        self.stack[self.depth] = child;
                        self.depth += 1;
                    }
                    return .{ .ids = ids, .name = nd.name };
                },
            }
        }
        return null;
    }

    pub fn resources(self: *FdtBackend, node: conduit.backend.Node, out: *conduit.ResourceList) conduit.backend.Error!void {
        _ = node;
        out.* = self.cur_res;
    }

    /// Consume the current node's props (which, in this walker, share the node's
    /// begin depth and precede any subnode). Peek non-prop tokens by save/restore.
    fn scanProps(self: *FdtBackend, ids: *conduit.IdList, child: *Cells) conduit.backend.Error!void {
        while (true) {
            const saved = self.walker;
            const ev = self.walker.next() orelse break;
            if (ev != .prop) {
                self.walker = saved;
                break;
            }
            const p = ev.prop;
            if (std.mem.eql(u8, p.name, "compatible")) {
                var it = std.mem.splitScalar(u8, p.data, 0);
                while (it.next()) |s| if (s.len != 0) ids.append(s);
            } else if (std.mem.eql(u8, p.name, "#address-cells")) {
                child.addr = beCell(p.data) orelse child.addr;
            } else if (std.mem.eql(u8, p.name, "#size-cells")) {
                child.size = beCell(p.data) orelse child.size;
            } else if (std.mem.eql(u8, p.name, "reg")) {
                try lowerReg(p.data, self.cur_cells, &self.cur_res);
            }
        }
    }
};

fn beCell(data: []const u8) ?u32 {
    if (data.len < 4) return null;
    return std.mem.readInt(u32, data[0..4], .big);
}

fn readCells(data: []const u8, count: u32) u64 {
    var v: u64 = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const off = i * 4;
        if (off + 4 > data.len) break;
        v = (v << 32) | std.mem.readInt(u32, data[off..][0..4], .big);
    }
    return v;
}

fn lowerReg(data: []const u8, cells: Cells, out: *conduit.ResourceList) conduit.backend.Error!void {
    const stride = (cells.addr + cells.size) * 4;
    if (stride == 0) return;
    var off: usize = 0;
    while (off + stride <= data.len) : (off += stride) {
        const base = readCells(data[off..], cells.addr);
        const size = readCells(data[off + cells.addr * 4 ..], cells.size);
        try out.append(.{ .mmio = .{ .base = base, .size = size } });
    }
}

/// Discover the base address of the first device of `class` matching any of
/// `compats`, via Ferrite's FDT backend driving conduit's Registry.
pub fn findBase(class: conduit.Class, compats: []const []const u8) ?u64 {
    var be = FdtBackend.init() orelse return null;
    const matchers = [_]conduit.Matcher{.{ .class = class, .dt_compatible = compats }};
    const registry = conduit.Registry.init(be.any(), &matchers);
    const m = (registry.find(class) catch return null) orelse return null;
    return if (m.mmio()) |r| r.base else null;
}

/// Every MMIO window of the first device of `class` matching `compats`. Devices
/// like a GICv2 (distributor + CPU interface) or GICv3 (distributor +
/// redistributor) expose more than one `reg` window; callers index them in DT
/// order. `len` is 0 when nothing matched or there is no device tree.
pub const Bases = struct {
    items: [4]u64 = @splat(0),
    len: usize = 0,

    pub fn at(self: Bases, n: usize) ?u64 {
        return if (n < self.len) self.items[n] else null;
    }
};

pub fn findBases(class: conduit.Class, compats: []const []const u8) Bases {
    var out = Bases{};
    var be = FdtBackend.init() orelse return out;
    const matchers = [_]conduit.Matcher{.{ .class = class, .dt_compatible = compats }};
    const registry = conduit.Registry.init(be.any(), &matchers);
    const m = (registry.find(class) catch return out) orelse return out;
    while (out.len < out.items.len) : (out.len += 1) {
        const r = m.mmioAt(out.len) orelse break;
        out.items[out.len] = r.base;
    }
    return out;
}
