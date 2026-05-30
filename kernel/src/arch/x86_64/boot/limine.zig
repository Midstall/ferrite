const std = @import("std");
const kernel = @import("kernel");
const arch = @import("arch");
const memory = @import("kernel").memory;

extern var __bss_start: u8;
extern var __bss_end: u8;

const COMMON: [2]u64 = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b };

// Limine refuses to boot kernels without a base revision marker.
export var limine_base_revision: [3]u64 align(8) linksection(".limine_requests") = .{
    0xf9562b2d5c95a6c8,
    0x6a7b384944536bdc,
    3,
};

export var limine_requests_start: [4]u64 align(8) linksection(".limine_requests_start_marker") = .{
    0xf6b8f4b39de7d1ae,
    0xfab91a6940fcb9cf,
    0x785c6ed015d3e316,
    0x181e920a7852b9d9,
};

export var limine_requests_end: [2]u64 align(8) linksection(".limine_requests_end_marker") = .{
    0xadc0e0531bb10d03,
    0x9572709f31764c62,
};

const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

const HhdmRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*const HhdmResponse,
};

export var hhdm_request: HhdmRequest align(8) linksection(".limine_requests") = .{
    .id = .{ COMMON[0], COMMON[1], 0x48dcf1cb8ad2b852, 0x63984e959a98244b },
    .revision = 0,
    .response = null,
};

pub const MemmapEntry = extern struct {
    base: u64,
    length: u64,
    // 0=usable, 1=reserved, 2=acpi_reclaimable, 3=acpi_nvs, 4=bad_memory,
    // 5=bootloader_reclaimable, 6=kernel+modules, 7=framebuffer
    kind: u64,
};

const MemmapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: [*]const *const MemmapEntry,
};

const MemmapRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*const MemmapResponse,
};

export var memmap_request: MemmapRequest align(8) linksection(".limine_requests") = .{
    .id = .{ COMMON[0], COMMON[1], 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    .revision = 0,
    .response = null,
};

const KernelAddressResponse = extern struct {
    revision: u64,
    physical_base: u64,
    virtual_base: u64,
};

const KernelAddressRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*const KernelAddressResponse,
};

export var kaddr_request: KernelAddressRequest align(8) linksection(".limine_requests") = .{
    .id = .{ COMMON[0], COMMON[1], 0x71ba76863cc55f63, 0xb2644a48c516a487 },
    .revision = 0,
    .response = null,
};

const limine_proto = @import("kernel").limine_proto;

export var module_request: limine_proto.ModuleRequest align(8) linksection(".limine_requests") = .{
    .id = .{ COMMON[0], COMMON[1], limine_proto.MODULE_REQUEST_UUID[0], limine_proto.MODULE_REQUEST_UUID[1] },
    .revision = 0,
    .response = null,
};

export var exec_file_request: limine_proto.ExecutableFileRequest align(8) linksection(".limine_requests") = .{
    .id = .{ COMMON[0], COMMON[1], limine_proto.EXECUTABLE_FILE_REQUEST_UUID[0], limine_proto.EXECUTABLE_FILE_REQUEST_UUID[1] },
    .revision = 0,
    .response = null,
};

export var rsdp_request: limine_proto.RsdpRequest align(8) linksection(".limine_requests") = .{
    .id = .{ COMMON[0], COMMON[1], limine_proto.RSDP_REQUEST_UUID[0], limine_proto.RSDP_REQUEST_UUID[1] },
    .revision = 0,
    .response = null,
};

const SmpInfo = extern struct {
    processor_id: u32,
    lapic_id: u32,
    reserved: u64,
    goto_address: ?*const fn (*SmpInfo) callconv(.c) noreturn,
    extra_argument: u64,
};

const SmpResponse = extern struct {
    revision: u64,
    flags: u32,
    bsp_lapic_id: u32,
    cpu_count: u64,
    cpus: [*]const *SmpInfo,
};

const SmpRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*SmpResponse,
    flags: u64,
};

export var smp_request: SmpRequest align(8) linksection(".limine_requests") = .{
    .id = .{ COMMON[0], COMMON[1], 0x95a67b819a1b857e, 0xa0b61b723b6a73e0 },
    .revision = 0,
    .response = null,
    .flags = 0,
};

extern fn secondaryStart(cpu_id: u64) callconv(.c) noreturn;

export fn apEntryX86_64(info: *SmpInfo) callconv(.c) noreturn {
    secondaryStart(info.extra_argument);
}

fn launchAps(r: *SmpResponse) void {
    const cpu = @import("kernel").cpu;
    var assigned_id: u32 = 1;
    var i: usize = 0;
    while (i < r.cpu_count and assigned_id < cpu.MAX_CPUS) : (i += 1) {
        const info = r.cpus[i];
        if (info.lapic_id == r.bsp_lapic_id) continue;
        info.extra_argument = assigned_id;
        info.goto_address = &apEntryX86_64;
        assigned_id += 1;
    }
    cpu.init(assigned_id);
}

pub var hhdm_offset: u64 = 0;
pub var kernel_phys_base: u64 = 0;
pub var kernel_virt_base: u64 = 0;

// Real entry is boot/limine_start.S; it switches to the kernel stack first.
export fn zigStart() callconv(.c) noreturn {
    if (hhdm_request.response) |r| hhdm_offset = r.offset;
    if (kaddr_request.response) |r| {
        kernel_phys_base = r.physical_base;
        kernel_virt_base = r.virtual_base;
    }

    if (memmap_request.response) |mm| {
        var i: usize = 0;
        while (i < mm.entry_count and i < memory.MAX_REGIONS) : (i += 1) {
            const e = mm.entries[i].*;
            const kind: memory.RegionKind = switch (e.kind) {
                0 => .usable,
                2, 5 => .reclaimable,
                else => .reserved,
            };
            memory.register(e.base, e.length, kind);
        }
    }
    memory.init(hhdm_offset);

    arch.mmu.init(.{
        .hhdm_offset = hhdm_offset,
        .alloc_page = &memory.allocPage,
        .free_page = &memory.freePage,
    });
    arch.mmu.captureKernelTtbr0();
    arch.mmu.forceWritableRange(0xffffffff80000000, 0xffffffff80100000);

    if (exec_file_request.response) |r| limine_proto.registerCmdline(r);
    if (module_request.response) |r| limine_proto.findAndRegisterInitrd(r);
    if (rsdp_request.response) |r| @import("kernel").acpi.rsdp_phys = r.address;

    if (smp_request.response) |r| launchAps(r);

    kernel.kmain();
}

pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, ra: ?usize) noreturn {
    @branchHint(.cold);
    arch.uart.write("\n[PANIC] ");
    arch.uart.write(msg);
    // Manual uart formatter (NOT std.fmt -- its Writer vtable faults on the
    // x86_64 kernel build, which would re-fault inside the panic handler).
    if (ra) |addr| arch.uart.print(" ra=0x{x}", .{addr});
    arch.uart.write("\n");
    while (true) asm volatile ("hlt");
}

// Manual ld.lld link doesn't bundle compiler_rt; pull in libc memcpy/memset
// so std.fmt's references resolve.
const libc = @import("libc");
comptime {
    _ = libc;
}
