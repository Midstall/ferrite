// All boot paths arrange device MMIO at PA == VA, so `offset` stays 0:
//  raw: mmu.init device-maps low 1 GB; limine: stub adds Device identity maps;
//  UEFI: firmware identity-maps.

pub var offset: usize = 0;

pub inline fn read(comptime T: type, phys: usize) T {
    const ptr: *volatile T = @ptrFromInt(phys + offset);
    return ptr.*;
}

pub inline fn write(comptime T: type, phys: usize, val: T) void {
    const ptr: *volatile T = @ptrFromInt(phys + offset);
    ptr.* = val;
}
