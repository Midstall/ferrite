// Flattened Device Tree parser.
// Assumes QEMU virt convention (#address-cells = 2, #size-cells = 2)
// for any node not explicitly sniffed. `parseCpus` honours
// `/cpus/#address-cells` at runtime.

const std = @import("std");
const memory = @import("memory.zig");

/// 0 if no DTB was provided.
pub var dtb_phys: u64 = 0;

pub fn rawImage() ?[]const u8 {
    if (dtb_phys == 0) return null;
    const base: usize = @intCast(dtb_phys);
    if (beU32At(base) != FDT_MAGIC) return null;
    const total: usize = @intCast(beU32At(base + 4));
    const ptr: [*]const u8 = @ptrFromInt(base);
    return ptr[0..total];
}

pub const DeviceInfo = extern struct {
    phys: u64,
    size: u64,
    irq: u32,
    /// 1 if the node carried an `interrupts` property.
    has_irq: u32,
};

/// Only inspects direct children of root.
pub fn findCompatible(compatible_name: []const u8, index: u32) ?DeviceInfo {
    var w = open(dtb_phys) orelse return null;
    var depth: u32 = 0;
    var in_target = false;
    var compatible_match = false;
    var have_reg = false;
    var have_irq = false;
    var node_phys: u64 = 0;
    var node_size: u64 = 0;
    var node_irq: u32 = 0;
    var found_count: u32 = 0;

    while (w.next()) |ev| switch (ev) {
        .begin => |n| {
            depth = n.depth;
            if (n.depth == 2) {
                in_target = true;
                compatible_match = false;
                have_reg = false;
                have_irq = false;
            }
        },
        .prop => |p| {
            if (!in_target or p.depth != 2) continue;
            if (std.mem.eql(u8, p.name, "compatible")) {
                var pos: usize = 0;
                while (pos < p.data.len) {
                    var end = pos;
                    while (end < p.data.len and p.data[end] != 0) : (end += 1) {}
                    if (std.mem.eql(u8, p.data[pos..end], compatible_name)) {
                        compatible_match = true;
                        break;
                    }
                    pos = end + 1;
                }
            } else if (std.mem.eql(u8, p.name, "reg")) {
                if (p.data.len >= 16) {
                    node_phys = readBe64(p.data[0..8]);
                    node_size = readBe64(p.data[8..16]);
                    have_reg = true;
                }
            } else if (std.mem.eql(u8, p.name, "interrupts")) {
                // GIC: 3 cells per IRQ. SPIs add 32, PPIs add 16.
                if (p.data.len >= 12) {
                    const itype = readBe32(p.data[0..4]);
                    const inum = readBe32(p.data[4..8]);
                    node_irq = if (itype == 0) inum + 32 else inum + 16;
                    have_irq = true;
                }
            }
        },
        .end => {
            if (depth == 2 and in_target) {
                if (compatible_match and have_reg) {
                    if (found_count == index) {
                        return .{
                            .phys = node_phys,
                            .size = node_size,
                            .irq = node_irq,
                            .has_irq = if (have_irq) 1 else 0,
                        };
                    }
                    found_count += 1;
                }
                in_target = false;
            }
            if (depth > 0) depth -= 1;
        },
    };
    return null;
}

const FDT_MAGIC: u32 = 0xD00DFEED;
const FDT_BEGIN_NODE: u32 = 1;
const FDT_END_NODE: u32 = 2;
const FDT_PROP: u32 = 3;
const FDT_NOP: u32 = 4;
const FDT_END: u32 = 9;

inline fn beU32At(addr: usize) u32 {
    return std.mem.readInt(u32, @ptrFromInt(addr), .big);
}

inline fn align4(x: usize) usize {
    return (x + 3) & ~@as(usize, 3);
}

fn cstring(addr: usize) [:0]const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrFromInt(addr)));
}

// Token iterator.

pub const Node = struct {
    /// 1 = root, 2 = direct child of root, ...
    depth: u32,
    name: []const u8,
};

pub const Prop = struct {
    depth: u32,
    name: []const u8,
    data: []const u8,
};

pub const Event = union(enum) {
    begin: Node,
    end,
    prop: Prop,
};

pub const Walker = struct {
    base: usize,
    strings_off: u32,
    cursor: usize,
    /// 0 = before root opens.
    depth: u32,

    pub fn next(self: *Walker) ?Event {
        while (true) {
            const token = beU32At(self.cursor);
            self.cursor += 4;
            switch (token) {
                FDT_BEGIN_NODE => {
                    const name = cstring(self.cursor);
                    self.cursor += align4(name.len + 1);
                    self.depth += 1;
                    return .{ .begin = .{ .depth = self.depth, .name = name } };
                },
                FDT_END_NODE => {
                    if (self.depth > 0) self.depth -= 1;
                    return .end;
                },
                FDT_PROP => {
                    const prop_len = beU32At(self.cursor);
                    const prop_nameoff = beU32At(self.cursor + 4);
                    self.cursor += 8;
                    const data_addr = self.cursor;
                    self.cursor += align4(prop_len);
                    const name = cstring(self.base + self.strings_off + prop_nameoff);
                    const data: [*]const u8 = @ptrFromInt(data_addr);
                    return .{ .prop = .{
                        .depth = self.depth,
                        .name = name,
                        .data = data[0..prop_len],
                    } };
                },
                FDT_NOP => continue,
                else => return null,
            }
        }
    }
};

pub fn open(dtb_ptr: u64) ?Walker {
    if (dtb_ptr == 0) return null;
    const base: usize = @intCast(dtb_ptr);
    if (beU32At(base) != FDT_MAGIC) return null;
    const struct_off = beU32At(base + 8);
    const strings_off = beU32At(base + 12);
    return .{
        .base = base,
        .strings_off = strings_off,
        .cursor = base + struct_off,
        .depth = 0,
    };
}

// Slice-based BE int readers.

fn readBe32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

fn readBe64(b: []const u8) u64 {
    return std.mem.readInt(u64, b[0..8], .big);
}

fn readCells(b: []const u8, cells: u32) ?u64 {
    return switch (cells) {
        1 => @as(u64, readBe32(b)),
        2 => readBe64(b),
        else => null,
    };
}

// High-level queries.

pub fn parseMemory(dtb_ptr: u64) bool {
    var w = open(dtb_ptr) orelse return false;
    var in_memory = false;
    var found = false;
    while (w.next()) |ev| switch (ev) {
        .begin => |n| {
            in_memory = n.depth == 2 and std.mem.startsWith(u8, n.name, "memory") and
                (n.name.len == 6 or n.name[6] == '@');
        },
        .end => in_memory = false,
        .prop => |p| {
            if (!in_memory or !std.mem.eql(u8, p.name, "reg")) continue;
            var off: usize = 0;
            while (off + 16 <= p.data.len) : (off += 16) {
                const base = readBe64(p.data[off..]);
                const size = readBe64(p.data[off + 8 ..]);
                memory.register(base, size, .usable);
                found = true;
            }
        },
    };
    return found;
}

pub fn parseBootargs(dtb_ptr: u64) ?[]const u8 {
    var w = open(dtb_ptr) orelse return null;
    var in_chosen = false;
    while (w.next()) |ev| switch (ev) {
        .begin => |n| in_chosen = n.depth == 2 and std.mem.eql(u8, n.name, "chosen"),
        .end => in_chosen = false,
        .prop => |p| {
            if (!in_chosen or !std.mem.eql(u8, p.name, "bootargs")) continue;
            var len: usize = p.data.len;
            if (len > 0 and p.data[len - 1] == 0) len -= 1;
            return p.data[0..len];
        },
    };
    return null;
}

/// Works for raw boot paths where VA == PA.
pub fn parseInitrd(dtb_ptr: u64) ?[]const u8 {
    var w = open(dtb_ptr) orelse return null;
    var in_chosen = false;
    var start: ?u64 = null;
    var end: ?u64 = null;
    while (w.next()) |ev| switch (ev) {
        .begin => |n| in_chosen = n.depth == 2 and std.mem.eql(u8, n.name, "chosen"),
        .end => in_chosen = false,
        .prop => |p| {
            if (!in_chosen) continue;
            if (std.mem.eql(u8, p.name, "linux,initrd-start")) {
                start = readCells(p.data, @intCast(p.data.len / 4));
            } else if (std.mem.eql(u8, p.name, "linux,initrd-end")) {
                end = readCells(p.data, @intCast(p.data.len / 4));
            }
        },
    };

    const s = start orelse return null;
    const e = end orelse return null;
    if (e <= s) return null;
    const ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(s)));
    return ptr[0..@intCast(e - s)];
}

/// First value wins.
pub fn parseTimebaseFrequency(dtb_ptr: u64) ?u64 {
    var w = open(dtb_ptr) orelse return null;
    var in_cpus = false;
    var freq: ?u64 = null;
    while (w.next()) |ev| switch (ev) {
        .begin => |n| {
            if (n.depth == 2 and std.mem.eql(u8, n.name, "cpus")) in_cpus = true;
        },
        .end => {
            if (in_cpus and w.depth < 2) in_cpus = false;
        },
        .prop => |p| {
            if (!in_cpus or freq != null) continue;
            if (std.mem.eql(u8, p.name, "timebase-frequency")) {
                freq = readCells(p.data, @intCast(p.data.len / 4));
            }
        },
    };
    return freq;
}

/// FDT default for `#address-cells` is 2 if the property is absent.
pub fn parseCpus(dtb_ptr: u64, out: []u64) usize {
    var w = open(dtb_ptr) orelse return 0;
    var in_cpus = false;
    var in_cpu_child = false;
    var address_cells: u32 = 2;
    var cur_reg: ?u64 = null;
    var found: usize = 0;
    while (w.next()) |ev| switch (ev) {
        .begin => |n| {
            if (n.depth == 2 and std.mem.eql(u8, n.name, "cpus")) {
                in_cpus = true;
                address_cells = 2;
            } else if (in_cpus and n.depth == 3 and std.mem.startsWith(u8, n.name, "cpu") and
                (n.name.len == 3 or n.name[3] == '@'))
            {
                in_cpu_child = true;
                cur_reg = null;
            }
        },
        .end => {
            if (in_cpu_child and w.depth < 3) {
                if (cur_reg) |r| {
                    if (found < out.len) {
                        out[found] = r;
                        found += 1;
                    }
                }
                in_cpu_child = false;
            }
            if (in_cpus and w.depth < 2) in_cpus = false;
        },
        .prop => |p| {
            if (in_cpus and !in_cpu_child) {
                if (std.mem.eql(u8, p.name, "#address-cells")) {
                    address_cells = readBe32(p.data);
                }
            } else if (in_cpu_child and std.mem.eql(u8, p.name, "reg")) {
                cur_reg = readCells(p.data, address_cells);
            }
        },
    };
    return found;
}
