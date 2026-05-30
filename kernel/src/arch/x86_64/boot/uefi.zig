// x86_64 UEFI entry: long mode, identity-mapped low memory, IRQs masked.
//
// The whole arch/x86_64 kernel module is built once per boot path. UEFI
// builds with abi=.msvc, so every `extern fn foo() callconv(.c)` resolves
// to MSVC ABI. The matching MSVC variants of every asm stub live in
// isr_uefi.S; the Limine path links isr.S (SysV) instead.

const std = @import("std");
const uefi = std.os.uefi;
const arch = @import("arch");
const kernel = @import("kernel");
const memory = kernel.memory;
const initrd = kernel.initrd;
const acpi = kernel.acpi;

extern var __stack_top: u8;

// Slot for the initrd loaded from ESP. Allocated as runtime-services data
// so post-ExitBootServices memory map keeps it reserved; without that the
// page allocator hands the same pages out and clobbers initrd content.
var initrd_buf_ptr: ?[*]u8 = null;
var initrd_buf_len: usize = 0;

fn findRsdpAddress() ?u64 {
    const st = uefi.system_table;
    const entries = st.configuration_table[0..st.number_of_table_entries];
    for (entries) |e| {
        if (e.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_20_table_guid))
            return @intFromPtr(e.vendor_table);
    }
    for (entries) |e| {
        if (e.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_10_table_guid))
            return @intFromPtr(e.vendor_table);
    }
    return null;
}

pub fn main() uefi.Status {
    const con_out = uefi.system_table.con_out.?;
    _ = con_out.reset(false) catch {};
    _ = con_out.outputString(std.unicode.utf8ToUtf16LeStringLiteral("ferrite: UEFI entry\r\n")) catch false;

    if (findRsdpAddress()) |rsdp| acpi.rsdp_phys = rsdp;

    loadInitrdFromEsp() catch |e| {
        _ = con_out.outputString(std.unicode.utf8ToUtf16LeStringLiteral("ferrite: initrd load failed (continuing): ")) catch false;
        const msg = switch (e) {
            error.LoadedImageProtocolFailed => "loaded-image",
            error.SimpleFsProtocolFailed => "sfs",
            error.OpenRootFailed => "open root",
            error.OpenFileFailed => "open initrd.cpio",
            error.GetInfoFailed => "GetInfo",
            error.AllocFailed => "alloc",
            error.ReadFailed => "read",
        };
        var buf16: [64]u16 = undefined;
        var i: usize = 0;
        for (msg) |c| {
            if (i >= buf16.len - 1) break;
            buf16[i] = c;
            i += 1;
        }
        buf16[i] = 0;
        _ = con_out.outputString(buf16[0..i :0]) catch false;
        _ = con_out.outputString(std.unicode.utf8ToUtf16LeStringLiteral("\r\n")) catch false;
    };

    exitBootServices() catch |e| {
        const msg = switch (e) {
            error.GetMemoryMapFailed => "GetMemoryMap failed",
            error.ExitBootServicesFailed => "ExitBootServices failed",
        };
        arch.uart.write("\nferrite: ");
        arch.uart.write(msg);
        arch.uart.write("\n");
        while (true) asm volatile ("hlt");
    };

    // UEFI identity-maps low memory; HHDM = 0 means physToVirt is the
    // identity function for any phys ≤ what UEFI mapped.
    memory.init(0);

    arch.mmu.init(.{
        .hhdm_offset = 0,
        .alloc_page = &memory.allocPage,
        .free_page = &memory.freePage,
    });
    arch.mmu.captureKernelTtbr0();

    if (initrd_buf_ptr) |p| {
        if (initrd_buf_len > 0) {
            _ = initrd.init(p[0..initrd_buf_len]) catch {};
        }
    }

    // Switch to the bootstrap stack we allocated above (256 KB instead of
    // UEFI's 4-KB-committed default). The MSVC ABI expects rsp ≡ 8 (mod 16)
    // at function entry. `call` itself pushes 8 bytes, so we set rsp ≡ 0
    // (mod 16) and use `call` (not jmp) to land at the right alignment.
    kernel.kmain();
}

const InitrdLoadError = error{
    LoadedImageProtocolFailed,
    SimpleFsProtocolFailed,
    OpenRootFailed,
    OpenFileFailed,
    GetInfoFailed,
    AllocFailed,
    ReadFailed,
};

fn loadInitrdFromEsp() InitrdLoadError!void {
    const bs = uefi.system_table.boot_services.?;
    const loaded_image_p = (bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch return error.LoadedImageProtocolFailed) orelse return error.LoadedImageProtocolFailed;
    const dev = loaded_image_p.device_handle orelse return error.LoadedImageProtocolFailed;
    const sfs_p = (bs.handleProtocol(uefi.protocol.SimpleFileSystem, dev) catch return error.SimpleFsProtocolFailed) orelse return error.SimpleFsProtocolFailed;

    var root = sfs_p.openVolume() catch return error.OpenRootFailed;
    defer _ = root.close() catch {};

    var file = root.open(std.unicode.utf8ToUtf16LeStringLiteral("initrd.cpio"), .read, .{}) catch return error.OpenFileFailed;
    defer _ = file.close() catch {};

    var info_buf: [512]u8 align(8) = undefined;
    const info = file.getInfo(.file, &info_buf) catch return error.GetInfoFailed;
    const size: usize = @intCast(info.file_size);
    if (size == 0) return;

    const PAGE: usize = 4096;
    const pages = (size + PAGE - 1) / PAGE;
    const slice = bs.allocatePages(.any, .runtime_services_data, pages) catch return error.AllocFailed;
    const ptr: [*]u8 = @ptrCast(slice.ptr);
    _ = file.read(ptr[0..size]) catch return error.ReadFailed;
    initrd_buf_ptr = ptr;
    initrd_buf_len = size;
}

fn exitBootServices() !void {
    const bs = uefi.system_table.boot_services.?;
    const MemoryDescriptor = uefi.tables.MemoryDescriptor;

    // UEFI loads the running kernel image into LoaderCode/LoaderData and
    // its initial stack into BootServicesData. Both get re-registered as
    // .usable below; carve them out so the page allocator can't hand the
    // running .text/.data/stack pages to other code (which then writes to
    // them and we crash with weird addresses at runtime).
    var image_lo: u64 = 0;
    var image_hi: u64 = 0;
    if (bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch null) |li| {
        image_lo = @intFromPtr(li.image_base);
        image_hi = image_lo + li.image_size;
    }

    // Snapshot current rsp; treat ±256 KB around it as reserved stack pages.
    // UEFI commits stack on demand via guard pages but those die after
    // ExitBootServices, so we have to size for the worst case ourselves.
    var cur_rsp: u64 = 0;
    asm volatile ("mov %%rsp, %[r]"
        : [r] "=r" (cur_rsp),
    );
    const STACK_GUARD: u64 = 256 * 1024;
    const stack_lo: u64 = (cur_rsp -% STACK_GUARD) & ~@as(u64, 0xFFF);
    const stack_hi: u64 = (cur_rsp +% STACK_GUARD + 0xFFF) & ~@as(u64, 0xFFF);

    var memmap_buf: [16384]u8 align(@alignOf(MemoryDescriptor)) = undefined;
    const slice = bs.getMemoryMap(&memmap_buf) catch return error.GetMemoryMapFailed;

    var it = slice.iterator();
    while (it.next()) |desc| {
        const phys = desc.physical_start;
        const len = desc.number_of_pages * 4096;
        // Only conventional_memory is unambiguously safe to hand to the
        // page allocator. boot_services_code/data and loader_code/data CAN
        // be reclaimed per the UEFI spec, but in practice they overlap the
        // running kernel image AND its initial stack (too many footguns).
        // ACPI reclaim is tagged separately so acpi.zig can release it
        // after parsing.
        const default_kind: memory.RegionKind = switch (desc.type) {
            .conventional_memory => .usable,
            .acpi_reclaim_memory => .reclaimable,
            else => .reserved,
        };
        if (default_kind == .usable) {
            // UEFI on QEMU marks several conv-memory regions read-only at
            // the 2 MB page level. Limit registered usable to phys < 192 MB
            // (kernel image lives at 0xe000000 = 224 MB, so this also
            // excludes pages near the kernel that UEFI loaded as RO).
            const SAFE_HI: u64 = 0x0c000000;
            const reg_end = phys + len;
            if (phys >= SAFE_HI) {
                memory.register(phys, len, .reserved);
            } else if (reg_end <= SAFE_HI) {
                registerCarved(phys, len, image_lo, image_hi, stack_lo, stack_hi);
            } else {
                registerCarved(phys, SAFE_HI - phys, image_lo, image_hi, stack_lo, stack_hi);
                memory.register(SAFE_HI, reg_end - SAFE_HI, .reserved);
            }
        } else {
            memory.register(phys, len, default_kind);
        }
    }

    bs.exitBootServices(uefi.handle, slice.info.key) catch return error.ExitBootServicesFailed;
}

fn registerCarved(phys: u64, len: u64, hole1_lo: u64, hole1_hi: u64, hole2_lo: u64, hole2_hi: u64) void {
    var lo = phys;
    const hi = phys + len;
    // Process holes in ascending order so disjoint pieces register cleanly.
    var holes: [2]struct { lo: u64, hi: u64 } = .{
        .{ .lo = hole1_lo, .hi = hole1_hi },
        .{ .lo = hole2_lo, .hi = hole2_hi },
    };
    if (holes[0].lo > holes[1].lo) std.mem.swap(@TypeOf(holes[0]), &holes[0], &holes[1]);
    for (holes) |h| {
        if (h.lo >= h.hi) continue;
        if (h.hi <= lo or h.lo >= hi) continue;
        const ov_lo = if (h.lo < lo) lo else h.lo;
        const ov_hi = if (h.hi > hi) hi else h.hi;
        if (lo < ov_lo) memory.register(lo, ov_lo - lo, .usable);
        memory.register(ov_lo, ov_hi - ov_lo, .reserved);
        lo = ov_hi;
    }
    if (lo < hi) memory.register(lo, hi - lo, .usable);
}

pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    arch.uart.write("\n[PANIC] ");
    arch.uart.write(msg);
    arch.uart.write("\n");
    while (true) asm volatile ("hlt");
}
