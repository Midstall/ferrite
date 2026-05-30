// `offset` is the kernel mapping offset added to a phys address. Stays
// 0 on all current riscv boot paths because device MMIO is identity-
// mapped (raw: satp=Bare or no MMU; Limine: stub identity-maps device
// ranges, HHDM skips MMIO).
pub var offset: usize = 0;

pub inline fn read(comptime T: type, phys: usize) T {
    const ptr: *volatile T = @ptrFromInt(phys + offset);
    return ptr.*;
}

pub inline fn write(comptime T: type, phys: usize, val: T) void {
    const ptr: *volatile T = @ptrFromInt(phys + offset);
    ptr.* = val;
}
