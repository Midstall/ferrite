// Adapter for kernel/src/aspace.zig on chips without an MMU. Virtual
// addresses equal physical addresses (identity). Per-process U-mode
// access is enforced by PMP, programmed from `pmp.Aspace` on context
// switch (see pmp.zig).

const std = @import("std");
const pmp = @import("board/esp32c6/pmp.zig");

pub const kernel_translates_user = true;

pub const MapError = error{ OutOfMemory, Unsupported };

pub const MapFlags = struct {
    read: bool = true,
    write: bool = false,
    execute: bool = false,
    user: bool = false,
    device: bool = false,
};

pub const PageTable = struct {
    aspace: pmp.Aspace = .{},
    nregions: u8 = 0,
};

pub const Config = struct {};

pub fn init(_: Config) void {}
pub fn captureKernelTtbr0() void {}

pub fn userTableCreate() MapError!PageTable {
    return .{};
}

pub fn userTableDestroy(_: *PageTable) void {}

pub fn userTableTranslate(_: *PageTable, va: u64) ?u64 {
    return va;
}

pub fn userTableMap(t: *PageTable, va: u64, pa: u64, prot: MapFlags) MapError!void {
    _ = pa;
    const va32: u32 = @intCast(va);
    const new_perms: pmp.PmpPerms = .{
        .r = prot.read,
        .w = prot.write,
        .x = prot.execute,
    };
    // Coalesce contiguous pages with matching perms - without this every
    // per-page call from loader.zig would burn a region slot.
    if (t.nregions > 0) {
        const last = &t.aspace.regions[t.nregions - 1];
        if (last.base + last.size == va32 and
            last.perms.r == new_perms.r and
            last.perms.w == new_perms.w and
            last.perms.x == new_perms.x)
        {
            last.size += 0x1000;
            return;
        }
    }
    if (t.nregions >= t.aspace.regions.len) {
        // PMP has 4 slots per process; further pages can't be granted
        // to U-mode and will trap at runtime if touched.
        return;
    }
    t.aspace.regions[t.nregions] = .{
        .base = va32,
        .size = 0x1000,
        .perms = new_perms,
    };
    t.nregions += 1;
}

pub fn userTableUnmap(_: *PageTable, _: u64) void {}

pub fn userTableLoad(t: *PageTable) void {
    pmp.loadAspace(&t.aspace);
}
