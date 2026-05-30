const std = @import("std");
const arch = @import("arch");
const memory = @import("memory.zig");

pub var rsdp_phys: u64 = 0;

// Limine on aarch64 returns table pointers already in the kernel half. Treat
// any address with the top bit set as already-virtual; otherwise translate
// through HHDM. On UEFI x86_64, HHDM does not always cover the ACPI region;
// when arch.mmu exposes ensurePhysMapped we eagerly demand-map.
inline fn mapPhys(addr: u64) usize {
    if (addr >= 0xffff_0000_0000_0000) return @intCast(addr);
    if (@hasDecl(arch.mmu, "ensurePhysMapped")) {
        arch.mmu.ensurePhysMapped(addr, 0x40);
    }
    return memory.physToVirt(addr);
}

// Captured tables packed as records: 4-byte signature, u32 LE length,
// then `length` bytes. Iteration uses these record headers, not the
// physical pointers in XSDT (which mean nothing once copied here).
const TABLES_MAX: usize = 64 * 1024;
var tables_buf: [TABLES_MAX]u8 = undefined;
var tables_len: usize = 0;

pub fn rawImage() ?[]const u8 {
    if (tables_len == 0) return null;
    return tables_buf[0..tables_len];
}

const SDT_HEADER = 36;

const Rsdp1 = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_address: u32,
};

const Rsdp2 = extern struct {
    v1: Rsdp1,
    length: u32,
    xsdt_address: u64,
    extended_checksum: u8,
    reserved: [3]u8,
};

pub fn init() void {
    if (rsdp_phys == 0) return;
    const rsdp: *align(1) const Rsdp1 = @ptrFromInt(mapPhys(rsdp_phys));
    if (!std.mem.eql(u8, &rsdp.signature, "RSD PTR ")) return;

    const root_phys: u64 = if (rsdp.revision >= 2) blk: {
        const r2: *align(1) const Rsdp2 = @ptrFromInt(mapPhys(rsdp_phys));
        break :blk r2.xsdt_address;
    } else rsdp.rsdt_address;
    if (root_phys == 0) return;

    appendTable(rsdp_phys, @sizeOf(Rsdp2));

    const root = sdtAt(root_phys) orelse return;
    if (root.length < SDT_HEADER) return;
    appendTable(root_phys, root.length);

    const is_xsdt = std.mem.eql(u8, &root.signature, "XSDT");
    const entry_size: usize = if (is_xsdt) 8 else 4;
    const after_header: [*]const u8 = @ptrFromInt(mapPhys(root_phys) + SDT_HEADER);
    const entries_bytes: usize = @as(usize, root.length) - SDT_HEADER;
    var off: usize = 0;
    while (off + entry_size <= entries_bytes) : (off += entry_size) {
        const phys: u64 = if (is_xsdt)
            std.mem.readInt(u64, after_header[off..][0..8], .little)
        else
            std.mem.readInt(u32, after_header[off..][0..4], .little);
        if (phys == 0) continue;
        const t = sdtAt(phys) orelse continue;
        if (t.length < SDT_HEADER) continue;
        appendTable(phys, t.length);
    }
}

const Sdt = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,
};

fn sdtAt(phys: u64) ?*align(1) const Sdt {
    if (phys == 0) return null;
    return @ptrFromInt(mapPhys(phys));
}

fn appendTable(phys: u64, length: u32) void {
    const sig: *const [4]u8 = @ptrFromInt(mapPhys(phys));
    const header = 4 + 4;
    if (tables_len + header + length > tables_buf.len) return;
    @memcpy(tables_buf[tables_len..][0..4], sig);
    std.mem.writeInt(u32, tables_buf[tables_len + 4 ..][0..4], length, .little);
    const src: [*]const u8 = @ptrFromInt(mapPhys(phys));
    @memcpy(tables_buf[tables_len + header ..][0..length], src[0..length]);
    tables_len += header + length;
}
