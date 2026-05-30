// Build a Ferrite ESP32-C6 partition table .bin from --entry= args.
//
// Format (see kernel/src/arch/riscv32/partition.zig):
//   16-byte header (magic, version, entry_count, reserved) +
//   16 x 32-byte entries (type, subtype, offset, size, label, flags).
//
// Example:
//   ferrite-partitiontable --output table.bin \
//       --entry kernel,offset=0x10000,size=0x80000,label=kernel \
//       --entry initrd,offset=0x90000,size=0x100000,label=initrd

const std = @import("std");
const Io = std.Io;
const common = @import("common");
const part = @import("partition");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;
    const cwd: Io.Dir = .cwd();

    var output_path: ?[]const u8 = null;
    var entries: std.array_list.Aligned(part.Entry, null) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--output")) {
            i += 1;
            output_path = args[i];
        } else if (std.mem.eql(u8, a, "--entry")) {
            i += 1;
            try entries.append(arena, try parseEntry(args[i]));
        } else {
            return error.BadArgs;
        }
    }
    const out_path = output_path orelse return error.NoOutput;

    var table: part.Table = .{
        .magic = part.MAGIC,
        .version = part.VERSION,
        .entry_count = @intCast(entries.items.len),
        ._reserved = 0,
        .entries = std.mem.zeroes([part.MAX_ENTRIES]part.Entry),
    };
    if (entries.items.len > part.MAX_ENTRIES) return error.TooManyEntries;
    for (entries.items, 0..) |e, idx| table.entries[idx] = e;

    try common.writeAll(cwd, io, out_path, std.mem.asBytes(&table));
}

/// Parse "TYPE,offset=N,size=N,label=NAME[,subtype=N]".
fn parseEntry(spec: []const u8) !part.Entry {
    var iter = std.mem.splitScalar(u8, spec, ',');
    const type_str = iter.next() orelse return error.BadSpec;

    const t: part.Type = if (std.mem.eql(u8, type_str, "kernel"))
        .kernel
    else if (std.mem.eql(u8, type_str, "initrd"))
        .initrd
    else if (std.mem.eql(u8, type_str, "data"))
        .data
    else
        return error.BadType;

    var e: part.Entry = .{
        .type_raw = @intFromEnum(t),
        .subtype = 0,
        .offset = 0,
        .size = 0,
        .label = std.mem.zeroes([16]u8),
        .flags = 0,
    };

    while (iter.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.BadKV;
        const k = kv[0..eq];
        const v = kv[eq + 1 ..];
        if (std.mem.eql(u8, k, "offset")) {
            e.offset = try parseInt(v);
        } else if (std.mem.eql(u8, k, "size")) {
            e.size = try parseInt(v);
        } else if (std.mem.eql(u8, k, "label")) {
            const n = @min(v.len, 15);
            @memcpy(e.label[0..n], v[0..n]);
        } else if (std.mem.eql(u8, k, "subtype")) {
            e.subtype = @intCast(try parseInt(v));
        } else if (std.mem.eql(u8, k, "flags")) {
            e.flags = try parseInt(v);
        } else {
            return error.BadKey;
        }
    }
    return e;
}

fn parseInt(s: []const u8) !u32 {
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X'))
        return std.fmt.parseInt(u32, s[2..], 16);
    return std.fmt.parseInt(u32, s, 10);
}
