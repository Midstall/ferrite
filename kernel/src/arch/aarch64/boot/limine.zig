const std = @import("std");
const kernel = @import("kernel");
const arch = @import("arch");
const memory = @import("kernel").memory;

extern var __bss_start: u8;
extern var __bss_end: u8;
extern const __stack_top: u8;

const COMMON: [2]u64 = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b };

export var limine_base_revision: [3]u64 align(8) linksection(".limine_requests") = .{
    0xf9562b2d5c95a6c8,
    0x6a7b384944536bdc,
    // aarch64 needs >= 6 per Limine 9+.
    6,
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

const SmpInfo = extern struct {
    processor_id: u32,
    gic_iface_no: u32,
    mpidr: u64,
    reserved: u64,
    goto_address: ?*const fn (*SmpInfo) callconv(.c) noreturn,
    extra_argument: u64,
};

const SmpResponse = extern struct {
    revision: u64,
    flags: u32,
    _pad: u32,
    bsp_mpidr: u64,
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

const DtbResponse = extern struct {
    revision: u64,
    dtb_ptr: u64,
};

const DtbRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*DtbResponse,
};

export var dtb_request: DtbRequest align(8) linksection(".limine_requests") = .{
    .id = .{ COMMON[0], COMMON[1], 0xb40ddb48fb1ab1ca, 0xb71e0d4f5a8ac0d7 },
    .revision = 0,
    .response = null,
};

export var rsdp_request: limine_proto.RsdpRequest align(8) linksection(".limine_requests") = .{
    .id = .{ COMMON[0], COMMON[1], limine_proto.RSDP_REQUEST_UUID[0], limine_proto.RSDP_REQUEST_UUID[1] },
    .revision = 0,
    .response = null,
};

extern fn secondaryStart(cpu_id: u64) callconv(.c) noreturn;

export fn apEntryAarch64(info: *SmpInfo) callconv(.c) noreturn {
    asm volatile (
        \\ msr  spsel, #1
        \\ isb
        \\ mov  x2, #(3 << 20)
        \\ msr  cpacr_el1, x2
        \\ isb
        ::: .{ .x2 = true });
    secondaryStart(info.extra_argument);
}

fn launchAps(r: *SmpResponse) void {
    const cpu = kernel.cpu;
    // Pass 1: pre-allocate each AP's bootstrap/idle thread on the boot CPU (so the
    // AP never touches the heap before its per-CPU pointer is live). Don't start
    // the AP yet (setting goto_address is what triggers it).
    var assigned_id: u32 = 1;
    var i: usize = 0;
    while (i < r.cpu_count and assigned_id < cpu.MAX_CPUS) : (i += 1) {
        const info = r.cpus[i];
        if (info.mpidr == r.bsp_mpidr) continue;
        const boot_t = kernel.thread.Thread.initBootstrap() catch break;
        cpu.cpus[assigned_id].bootstrap = boot_t;
        cpu.cpus[assigned_id].current = boot_t;
        info.extra_argument = assigned_id;
        assigned_id += 1;
    }
    cpu.init(assigned_id);

    // Pass 2: hand each AP its entry point, which makes Limine release it.
    assigned_id = 1;
    i = 0;
    while (i < r.cpu_count and assigned_id < cpu.MAX_CPUS) : (i += 1) {
        const info = r.cpus[i];
        if (info.mpidr == r.bsp_mpidr) continue;
        info.goto_address = &apEntryAarch64;
        assigned_id += 1;
    }
}

pub var hhdm_offset: u64 = 0;
pub var kernel_phys_base: u64 = 0;
pub var kernel_virt_base: u64 = 0;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ // Force SPSel = 1: Limine doesn't guarantee SP_EL1 is selected on entry.
        \\ msr  spsel, #1
        \\ isb
        \\ adrp x1, __stack_top
        \\ add  x1, x1, :lo12:__stack_top
        \\ mov  sp, x1
        \\ // Enable FP/SIMD at EL1; Limine leaves CPACR_EL1.FPEN = 0.
        \\ mov  x2, #(3 << 20)
        \\ msr  cpacr_el1, x2
        \\ isb
        \\ bl zigStart
        \\0: wfe
        \\   b 0b
    );
}

export fn zigStart() noreturn {
    // TPIDR_EL1 (our per-CPU pointer) has an architecturally UNKNOWN reset
    // value on real hardware. The scheduler's pre-setThisCpu guards rely on it
    // reading 0 (true under TCG, garbage under KVM) - so zero it before any
    // timer IRQ can call schedTick/maybePreempt and @alignCast that garbage.
    asm volatile ("msr tpidr_el1, xzr");

    // Zero BSS. Limine doesn't guarantee it.
    const bss_start: [*]u8 = @ptrCast(&__bss_start);
    const bss_end: [*]u8 = @ptrCast(&__bss_end);
    const len = @intFromPtr(bss_end) - @intFromPtr(bss_start);
    @memset(bss_start[0..len], 0);

    if (hhdm_request.response) |r| hhdm_offset = r.offset;
    if (kaddr_request.response) |r| {
        kernel_phys_base = r.physical_base;
        kernel_virt_base = r.virtual_base;
    }
    if (dtb_request.response) |r| @import("kernel").dtb.dtb_phys = r.dtb_ptr;
    if (rsdp_request.response) |r| @import("kernel").acpi.rsdp_phys = r.address;

    // Register memmap before mmu walking. MMIO mappings allocate page-table pages.
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
    memory.init(@intCast(hhdm_offset));

    arch.mmu.configureWalker(.{
        .hhdm_offset = @intCast(hhdm_offset),
        .alloc_page = &memory.allocPage,
        .free_page = &memory.freePage,
    });

    // PL011 UART (0x09000000) + GIC v2 (0x08000000). Limine doesn't map MMIO.
    arch.mmu.mapDeviceIdentity2m(0x0900_0000) catch {};
    arch.mmu.mapDeviceIdentity2m(0x0800_0000) catch {};
    arch.mmio.offset = 0;

    arch.mmu.captureKernelTtbr0();

    if (exec_file_request.response) |r| limine_proto.registerCmdline(r);
    if (module_request.response) |r| limine_proto.findAndRegisterInitrd(r);

    if (smp_request.response) |r| launchAps(r);

    kernel.kmain();
}

pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, ra: ?usize) noreturn {
    @branchHint(.cold);
    arch.uart.write("\n[PANIC] ");
    arch.uart.write(msg);
    if (ra) |addr| {
        arch.uart.print(" ra=0x{x}", .{addr});
    }
    arch.uart.write("\n");
    while (true) asm volatile ("wfe");
}
