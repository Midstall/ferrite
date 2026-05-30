// Selector layout:
//   0x00  null
//   0x08  kernel code 64-bit  (DPL=0, L=1)
//   0x10  kernel data         (DPL=0)
//   0x1B  user code 64-bit    (DPL=3, L=1)   (raw 0x18, RPL=3)
//   0x23  user data           (DPL=3)        (raw 0x20, RPL=3)
//   0x28  TSS (16-byte system descriptor occupies two entries)

const std = @import("std");

pub const KERNEL_CS: u16 = 0x08;
pub const KERNEL_DS: u16 = 0x10;
pub const USER_CS: u16 = 0x1B;
pub const USER_DS: u16 = 0x23;
pub const TSS_SEL: u16 = 0x28;

const Entry = packed struct(u64) {
    limit_low: u16 = 0,
    base_low: u16 = 0,
    base_mid: u8 = 0,
    access: u8 = 0,
    limit_high_and_flags: u8 = 0,
    base_high: u8 = 0,
};

const SysDesc = extern struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    limit_high_and_flags: u8,
    base_high: u8,
    base_upper: u32,
    reserved: u32,
};

pub const Tss = extern struct {
    reserved0: u32 = 0,
    rsp0: u64 align(4) = 0,
    rsp1: u64 align(4) = 0,
    rsp2: u64 align(4) = 0,
    reserved1: u64 align(4) = 0,
    ist1: u64 align(4) = 0,
    ist2: u64 align(4) = 0,
    ist3: u64 align(4) = 0,
    ist4: u64 align(4) = 0,
    ist5: u64 align(4) = 0,
    ist6: u64 align(4) = 0,
    ist7: u64 align(4) = 0,
    reserved2: u64 align(4) = 0,
    reserved3: u16 = 0,
    iomap_base: u16 = @sizeOf(Tss),
};

pub var tss: Tss = .{};

// null, kcode, kdata, ucode, udata, tss_lo, tss_hi.
var gdt: [7]u64 align(16) = @splat(0);

const GdtPtr = extern struct {
    limit: u16 align(1),
    base: u64 align(1),
};
var gdt_ptr: GdtPtr = .{ .limit = 0, .base = 0 };

fn entryBits(access: u8, flags: u8) u64 {
    var e: Entry = .{};
    e.access = access;
    e.limit_high_and_flags = (flags << 4) | 0x0F;
    e.limit_low = 0xFFFF;
    return @bitCast(e);
}

pub fn install() void {
    gdt[0] = 0;
    gdt[1] = entryBits(0x9A, 0xA);
    gdt[2] = entryBits(0x92, 0xC);
    gdt[3] = entryBits(0xFA, 0xA);
    gdt[4] = entryBits(0xF2, 0xC);

    const tss_base = @intFromPtr(&tss);
    const tss_limit: u32 = @sizeOf(Tss) - 1;
    var d: SysDesc = .{
        .limit_low = @intCast(tss_limit & 0xFFFF),
        .base_low = @intCast(tss_base & 0xFFFF),
        .base_mid = @intCast((tss_base >> 16) & 0xFF),
        .access = 0x89,
        .limit_high_and_flags = @intCast((tss_limit >> 16) & 0x0F),
        .base_high = @intCast((tss_base >> 24) & 0xFF),
        .base_upper = @intCast((tss_base >> 32) & 0xFFFFFFFF),
        .reserved = 0,
    };
    const tss_slot = std.mem.sliceAsBytes(gdt[5..7]);
    @memcpy(tss_slot[0..16], std.mem.asBytes(&d)[0..16]);

    gdt_ptr.limit = @sizeOf(@TypeOf(gdt)) - 1;
    gdt_ptr.base = @intFromPtr(&gdt);

    // lgdt/ltr helpers live in isr.S. Zig 0.16 inline asm rejects their m80/m16 forms.
    do_lgdt(&gdt_ptr);
    gdt_reload(@as(u64, KERNEL_CS), KERNEL_DS);
    do_ltr(TSS_SEL);
}

extern fn do_lgdt(ptr: *const anyopaque) callconv(.c) void;
extern fn do_ltr(sel: u16) callconv(.c) void;
extern fn gdt_reload(kcs: u64, kds: u16) callconv(.c) void;

pub fn setKernelStack(rsp0: u64) void {
    tss.rsp0 = rsp0;
}
