// aarch64 UEFI entry: EL1, MMU on with low PA identity-mapped, IRQs masked.

const std = @import("std");
const uefi = std.os.uefi;
const arch = @import("arch");
const memory = @import("kernel").memory;
const initrd = @import("kernel").initrd;
const acpi = @import("kernel").acpi;

extern var __stack_top: u8;

// Slot for the initrd loaded from ESP. Kernel pool keeps a single static
// buffer below the kernel BSS so we can register the bytes after
// ExitBootServices without doing any further UEFI allocations.
var initrd_buf_ptr: ?[*]u8 = null;
var initrd_buf_len: usize = 0;

// RSDP physical address from UEFI's configuration_table. The kernel's
// drv.pci walks ACPI MCFG to find the PCIe ECAM range; without this it
// reports "no virtio-net device on PCI" even when virtio-net-pci is on
// the bus.
fn findRsdpAddress() ?u64 {
    const st = uefi.system_table;
    const entries = st.configuration_table[0..st.number_of_table_entries];
    // ACPI 2.0 preferred; fall back to 1.0.
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
        const msg = switch (e) {
            error.LoadedImageProtocolFailed => "Loaded-image protocol failed",
            error.SimpleFsProtocolFailed => "SFS protocol failed",
            error.OpenRootFailed => "open root failed",
            error.OpenFileFailed => "open initrd.cpio failed",
            error.GetInfoFailed => "GetInfo failed",
            error.AllocFailed => "alloc failed",
            error.ReadFailed => "read failed",
        };
        _ = con_out.outputString(std.unicode.utf8ToUtf16LeStringLiteral("ferrite: initrd load failed (continuing): ")) catch false;
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
        while (true) asm volatile ("wfe");
    };

    // Firmware identity-maps UART/GIC; VA == PA.
    arch.mmio.offset = 0;

    // Enable FP/SIMD at EL1 (std.fmt emits q-register loads).
    asm volatile (
        \\ mov  x2, #(3 << 20)
        \\ msr  cpacr_el1, x2
        \\ isb
        ::: .{ .x2 = true });

    // Patch MAIR_EL1 so index 0 = Normal (matches arch/aarch64/mmu.zig's
    // leafEntry which uses attrIndex(0) for Normal memory) and index 1 =
    // Device-nGnRnE, without disturbing the other indices UEFI's identity
    // mapping relies on. mmu.init() is *not* called on the UEFI path, so
    // without this our new user page-table leaves get whatever attribute
    // UEFI put at index 0 (often Device), and unaligned writes fault.
    asm volatile (
        \\ mrs  x2, mair_el1
        \\ // mask out attrs for index 0 and 1 (low 16 bits)
        \\ mov  x3, #0xff
        \\ orr  x3, x3, #0xff00
        \\ bic  x2, x2, x3
        \\ // attr0 = 0xFF (Normal WB), attr1 = 0x00 (Device nGnRnE)
        \\ orr  x2, x2, #0xff
        \\ msr  mair_el1, x2
        \\ // table walks cache attrs, so flush TLB; D/I cache use PA, no
        \\ // flush needed for already-mapped kernel/UEFI ranges.
        \\ dsb  ish
        \\ tlbi vmalle1
        \\ dsb  ish
        \\ isb
        ::: .{ .x2 = true, .x3 = true, .memory = true });

    memory.init(0);

    // Wire the MMU's walker. Without this, every userTableCreate hits
    // the unsetAlloc stub and OOMs even though regions are populated.
    arch.mmu.configureWalker(.{
        .hhdm_offset = 0,
        .alloc_page = &memory.allocPage,
        .free_page = &memory.freePage,
    });
    arch.mmu.captureKernelTtbr0();

    // Register initrd now that BootServices are torn down. Safe because the
    // buffer is in the UEFI loaded-image memory which became `usable` in
    // the memory map post-exit.
    if (initrd_buf_ptr) |p| {
        if (initrd_buf_len > 0) {
            _ = initrd.init(p[0..initrd_buf_len]) catch {};
        }
    }

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
    // runtime_services_data so the post-ExitBootServices memmap reports
    // these pages as reserved. Otherwise our allocator hands them back
    // out and clobbers initrd content before runInit parses it.
    const slice = bs.allocatePages(.any, .runtime_services_data, pages) catch return error.AllocFailed;
    const ptr: [*]u8 = @ptrCast(slice.ptr);
    _ = file.read(ptr[0..size]) catch return error.ReadFailed;
    initrd_buf_ptr = ptr;
    initrd_buf_len = size;
}

const kernel = @import("kernel");

fn exitBootServices() !void {
    const bs = uefi.system_table.boot_services.?;
    const MemoryDescriptor = uefi.tables.MemoryDescriptor;

    var memmap_buf: [16384]u8 align(@alignOf(MemoryDescriptor)) = undefined;
    const slice = bs.getMemoryMap(&memmap_buf) catch return error.GetMemoryMapFailed;

    var it = slice.iterator();
    while (it.next()) |desc| {
        const kind: memory.RegionKind = switch (desc.type) {
            .conventional_memory,
            .boot_services_code,
            .boot_services_data,
            .loader_code,
            .loader_data,
            => .usable,
            .acpi_reclaim_memory => .reclaimable,
            else => .reserved,
        };
        memory.register(desc.physical_start, desc.number_of_pages * 4096, kind);
    }

    bs.exitBootServices(uefi.handle, slice.info.key) catch return error.ExitBootServicesFailed;
}

pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, ra: ?usize) noreturn {
    @branchHint(.cold);
    arch.uart.write("\n[PANIC] ");
    arch.uart.write(msg);
    if (ra) |addr| {
        var buf: [32]u8 = undefined;
        arch.uart.write(std.fmt.bufPrint(&buf, " ra=0x{x}", .{addr}) catch "");
    }
    arch.uart.write("\n");
    while (true) asm volatile ("wfe");
}
