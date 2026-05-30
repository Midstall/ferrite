// Selectors:
//   0x00  null
//   0x08  kernel code (DPL=0)
//   0x10  kernel data (DPL=0)
//   0x1B  user code   (DPL=3, raw 0x18, RPL=3)
//   0x23  user data   (DPL=3, raw 0x20, RPL=3)
//   0x28  TSS (DPL=0, available 32-bit)

const std = @import("std");

pub const KERNEL_CS: u16 = 0x08;
pub const KERNEL_DS: u16 = 0x10;
pub const USER_CS: u16 = 0x1B;
pub const USER_DS: u16 = 0x23;
pub const TSS_SEL: u16 = 0x28;

pub const Tss = extern struct {
    prev_link: u32 = 0,
    esp0: u32 = 0,
    ss0: u32 = 0,
    esp1: u32 = 0,
    ss1: u32 = 0,
    esp2: u32 = 0,
    ss2: u32 = 0,
    cr3: u32 = 0,
    eip: u32 = 0,
    eflags: u32 = 0,
    eax: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = 0,
    ebx: u32 = 0,
    esp: u32 = 0,
    ebp: u32 = 0,
    esi: u32 = 0,
    edi: u32 = 0,
    es: u32 = 0,
    cs: u32 = 0,
    ss: u32 = 0,
    ds: u32 = 0,
    fs: u32 = 0,
    gs: u32 = 0,
    ldt: u32 = 0,
    trap: u16 = 0,
    iomap_base: u16 = @sizeOf(Tss),
};

pub var tss: Tss = .{};

// null, kcode, kdata, ucode, udata, tss.
var gdt: [6]u64 align(16) = @splat(0);

const GdtPtr = extern struct {
    limit: u16 align(1),
    base: u32 align(1),
};
var gdt_ptr: GdtPtr = .{ .limit = 0, .base = 0 };

fn entry(base: u32, limit: u32, access: u8, flags: u4) u64 {
    var e: u64 = 0;
    e |= (limit & 0xFFFF);
    e |= @as(u64, base & 0xFFFF) << 16;
    e |= @as(u64, (base >> 16) & 0xFF) << 32;
    e |= @as(u64, access) << 40;
    e |= @as(u64, (limit >> 16) & 0xF) << 48;
    e |= @as(u64, flags) << 52;
    e |= @as(u64, (base >> 24) & 0xFF) << 56;
    return e;
}

pub fn install() void {
    gdt[0] = 0;
    gdt[1] = entry(0, 0xFFFFF, 0x9A, 0xC);
    gdt[2] = entry(0, 0xFFFFF, 0x92, 0xC);
    gdt[3] = entry(0, 0xFFFFF, 0xFA, 0xC);
    gdt[4] = entry(0, 0xFFFFF, 0xF2, 0xC);
    const tss_base = @intFromPtr(&tss);
    const tss_limit: u32 = @sizeOf(Tss) - 1;
    gdt[5] = entry(tss_base, tss_limit, 0x89, 0x0);

    gdt_ptr.limit = @sizeOf(@TypeOf(gdt)) - 1;
    gdt_ptr.base = @intFromPtr(&gdt);

    do_lgdt(&gdt_ptr);
    gdt_reload(KERNEL_CS, KERNEL_DS);
    do_ltr(TSS_SEL);

    tss.ss0 = KERNEL_DS;
}

pub fn setKernelStack(esp0: u32) void {
    tss.esp0 = esp0;
}

extern fn do_lgdt(ptr: *const anyopaque) callconv(.c) void;
extern fn do_ltr(sel: u16) callconv(.c) void;
extern fn gdt_reload(kcs: u16, kds: u16) callconv(.c) void;
