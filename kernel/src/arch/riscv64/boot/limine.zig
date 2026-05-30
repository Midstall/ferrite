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
    // RISC-V needs base revision 6+.
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
    processor_id: u64,
    hartid: u64,
    reserved: u64,
    goto_address: ?*const fn (*SmpInfo) callconv(.c) noreturn,
    extra_argument: u64,
};

const SmpResponse = extern struct {
    revision: u64,
    flags: u64,
    bsp_hartid: u64,
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

export fn apEntryRiscv64(info: *SmpInfo) callconv(.c) noreturn {
    secondaryStart(info.extra_argument);
}

fn launchAps(r: *SmpResponse) void {
    const cpu = @import("kernel").cpu;
    var assigned_id: u32 = 1;
    var i: usize = 0;
    while (i < r.cpu_count and assigned_id < cpu.MAX_CPUS) : (i += 1) {
        const info = r.cpus[i];
        if (info.hartid == r.bsp_hartid) continue;
        info.extra_argument = assigned_id;
        info.goto_address = &apEntryRiscv64;
        assigned_id += 1;
    }
    cpu.init(assigned_id);
}

pub var hhdm_offset: u64 = 0;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ la sp, __stack_top
        \\ // Install stvec early; Limine leaves it unset, so MMIO faults
        \\ // before traps.init vector to 0.
        \\ la t0, s_trap_entry
        \\ csrw stvec, t0
        \\ call zigStart
        \\0: wfi
        \\   j 0b
    );
}

export fn zigStart(hartid: u64) noreturn {
    // Zero BSS. Limine doesn't guarantee it.
    const bss_start: [*]u8 = @ptrCast(&__bss_start);
    const bss_end: [*]u8 = @ptrCast(&__bss_end);
    const len = @intFromPtr(bss_end) - @intFromPtr(bss_start);
    @memset(bss_start[0..len], 0);

    arch.cpu.boot_hartid = @intCast(hartid);

    if (hhdm_request.response) |r| hhdm_offset = r.offset;

    // Register memmap before MMU walking. MMIO mappings consume page-table pages.
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
    // Register initrd as reserved BEFORE memory.init carves usable ranges,
    // else page allocator hands out initrd PAs and signature.verify sees
    // corrupted bytes. Same root cause as the M-mode (raw) boot path.
    // Limine reports module addresses as HHDM VAs; translate back to PA.
    if (module_request.response) |r| limine_proto.findAndRegisterInitrd(r);
    if (limine_proto.initrdRegion()) |reg| {
        const pa = reg.phys -% @as(u64, @intCast(hhdm_offset));
        memory.register(pa, reg.len, .reserved);
    }
    memory.init(@intCast(hhdm_offset));

    arch.mmu.configureWalker(.{
        .hhdm_offset = @intCast(hhdm_offset),
        .alloc_page = &memory.allocPage,
        .free_page = &memory.freePage,
    });

    // QEMU virt rv64: CLINT at 0x0200_0000, UART at 0x1000_0000.
    arch.mmu.mapIdentity2m(0x0200_0000) catch reportWalkerFail("clint");
    arch.mmu.mapIdentity2m(0x1000_0000) catch reportWalkerFail("uart");
    arch.mmio.offset = 0;

    // userTableCreate copies the top-level kernel entries from satp at the
    // time of capture; without this, switching to a user pagetable unmaps
    // the kernel itself and execution dies the moment userBootstrap runs.
    arch.mmu.captureKernelTtbr0();

    if (exec_file_request.response) |r| limine_proto.registerCmdline(r);
    // initrd already registered above (pre-memory.init), don't re-register.

    if (smp_request.response) |r| launchAps(r);
    if (dtb_request.response) |r| @import("kernel").dtb.dtb_phys = r.dtb_ptr;
    if (rsdp_request.response) |r| @import("kernel").acpi.rsdp_phys = r.address;

    kernel.kmain();
}

fn reportWalkerFail(label: []const u8) noreturn {
    arch.sbi.legacyPutchar('M');
    arch.sbi.legacyPutchar('!');
    for (label) |c| arch.sbi.legacyPutchar(c);
    arch.sbi.legacyPutchar('\n');
    while (true) asm volatile ("wfi");
}

pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    arch.uart.write("\n[PANIC] ");
    arch.uart.write(msg);
    arch.uart.write("\n");
    while (true) asm volatile ("wfi");
}
