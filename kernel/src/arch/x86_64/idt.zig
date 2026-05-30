// x86_64 IDT (16-byte gate descriptors).

pub const Gate = extern struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32,
};

const empty_gate: Gate = .{
    .offset_low = 0,
    .selector = 0,
    .ist = 0,
    .type_attr = 0,
    .offset_mid = 0,
    .offset_high = 0,
    .reserved = 0,
};

pub var idt: [256]Gate align(16) = @splat(empty_gate);

const IdtPtr = extern struct {
    limit: u16 align(1),
    base: u64 align(1),
};

var idt_ptr: IdtPtr = .{ .limit = 0, .base = 0 };

pub fn setGate(vec: u8, handler: u64, selector: u16) void {
    idt[vec] = .{
        .offset_low = @intCast(handler & 0xFFFF),
        .selector = selector,
        .ist = 0,
        .type_attr = 0x8E, // P=1, DPL=0, type=0xE (64-bit interrupt gate)
        .offset_mid = @intCast((handler >> 16) & 0xFFFF),
        .offset_high = @intCast((handler >> 32) & 0xFFFFFFFF),
        .reserved = 0,
    };
}

extern fn do_lidt(ptr: *const anyopaque) callconv(.c) void;

/// Populate the IDTR struct and return its address. Callers can hand this to
/// the appropriate `lidt` helper for their ABI (SysV via `do_lidt`, MSVC via
/// `do_lidt_ms`).
pub fn prepareIdtPtr() *const IdtPtr {
    idt_ptr = .{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };
    return &idt_ptr;
}

pub fn load() void {
    do_lidt(prepareIdtPtr());
}
