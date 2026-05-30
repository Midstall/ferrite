// ESP32-C6 2nd-stage bootloader. ROM loads us to upper SRAM via the
// Espressif image format, we set up XIP for the kernel + initrd via
// the flash MMU, finish the kernel's .data/.bss prep, and jump.

const uart = @import("uart.zig");
const part = @import("partition.zig");

const MANIFEST_MAGIC: u32 = 0xFE_71_C6_E1;

const MMU_PAGE_SIZE: u32 = 0x1_0000;
const SOC_MMU_VALID: u32 = 1 << 9;

// Initrd lives inside the IROM-cacheable / PMP-permitted window
// [0x42000000, 0x42800000); placed 4 MB above kernel TEXT (~370 KB)
// so they don't collide. Addresses above 0x42800000 read as zeros on
// c6 since the chip's default cache window doesn't cover them.
const INITRD_VA_BASE: u32 = 0x4240_0000;

const SPI_MEM_MMU_ITEM_CONTENT_REG: *volatile u32 = @ptrFromInt(0x6000_237C);
const SPI_MEM_MMU_ITEM_INDEX_REG: *volatile u32 = @ptrFromInt(0x6000_2380);

const Cache_Suspend_ICache: *const fn () callconv(.c) u32 = @ptrFromInt(0x4000_0698);
const Cache_Resume_ICache: *const fn (u32) callconv(.c) void = @ptrFromInt(0x4000_069C);
const Cache_Invalidate_ICache_All: *const fn () callconv(.c) void = @ptrFromInt(0x4000_064C);
const esp_rom_spiflash_read: *const fn (u32, [*]u32, u32) callconv(.c) i32 = @ptrFromInt(0x4000_0150);

const Manifest = extern struct {
    magic: u32,
    entry_va: u32,
    irom_va: u32,
    irom_flash_offset: u32,
    irom_size: u32,
    data_flash_offset: u32,
    data_vma: u32,
    data_size: u32,
    bss_vma: u32,
    bss_size: u32,
};

extern var __bss_start: u8;
extern var __bss_end: u8;
extern const __stack_top: u8;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\ la sp, __stack_top
        \\ j  bootloaderMain
    );
}

fn fatal(msg: []const u8) noreturn {
    uart.write("\n[BOOTLOADER FATAL] ");
    uart.write(msg);
    uart.write("\n");
    while (true) asm volatile ("wfi");
}

fn flashRead(comptime T: type, flash_off: u32) T {
    var buf: T = undefined;
    const buf_ptr: [*]u32 = @ptrCast(@alignCast(&buf));
    const rc = esp_rom_spiflash_read(flash_off, buf_ptr, @sizeOf(T));
    if (rc != 0) fatal("flash read failed");
    return buf;
}

fn flashReadBuf(flash_off: u32, dst: [*]u8, len: u32) void {
    const buf_ptr: [*]u32 = @ptrCast(@alignCast(dst));
    const rc = esp_rom_spiflash_read(flash_off, buf_ptr, len);
    if (rc != 0) fatal("flash read failed");
}

fn mmuMapPage(vpage_id: u32, fpage_id: u32) void {
    SPI_MEM_MMU_ITEM_INDEX_REG.* = vpage_id;
    SPI_MEM_MMU_ITEM_CONTENT_REG.* = fpage_id | SOC_MMU_VALID;
    SPI_MEM_MMU_ITEM_INDEX_REG.* = vpage_id;
}

/// Map `size_bytes` of flash at `flash_off` to virtual pages starting at
/// `va_base`. Both must be MMU_PAGE_SIZE (64 KB) aligned.
fn mmuMapRange(va_base: u32, flash_off: u32, size_bytes: u32) void {
    const num_pages = (size_bytes + MMU_PAGE_SIZE - 1) / MMU_PAGE_SIZE;
    const vpage_base = (va_base - 0x4200_0000) / MMU_PAGE_SIZE;
    const fpage_base = flash_off / MMU_PAGE_SIZE;
    var p: u32 = 0;
    while (p < num_pages) : (p += 1) {
        mmuMapPage(vpage_base + p, fpage_base + p);
    }
}

export fn bootloaderMain() callconv(.c) noreturn {
    const bl_bss_start: [*]u8 = @ptrCast(&__bss_start);
    const bl_bss_end: [*]u8 = @ptrCast(&__bss_end);
    const bl_bss_len = @intFromPtr(bl_bss_end) - @intFromPtr(bl_bss_start);
    @memset(bl_bss_start[0..bl_bss_len], 0);

    const table = flashRead(part.Table, part.TABLE_FLASH_OFFSET);
    if (table.magic != part.MAGIC) fatal("bad partition table magic");
    if (table.version != part.VERSION) fatal("unsupported partition table version");

    const kpart = part.find(&table, .kernel) orelse fatal("no kernel partition");
    const ipart_opt = part.find(&table, .initrd);

    const manifest = flashRead(Manifest, kpart.offset);
    if (manifest.magic != MANIFEST_MAGIC) fatal("bad kernel manifest magic");

    const autoload = Cache_Suspend_ICache();

    const kernel_irom_flash = kpart.offset + manifest.irom_flash_offset;
    mmuMapRange(manifest.irom_va, kernel_irom_flash, manifest.irom_size);

    var initrd_va: u32 = 0;
    var initrd_size: u32 = 0;
    if (ipart_opt) |ipart| {
        mmuMapRange(INITRD_VA_BASE, ipart.offset, ipart.size);
        initrd_va = INITRD_VA_BASE;
        initrd_size = ipart.size;
    }

    Cache_Invalidate_ICache_All();
    Cache_Resume_ICache(autoload);

    if (manifest.data_size > 0) {
        const data_abs_flash = kpart.offset + manifest.data_flash_offset;
        const dst: [*]u8 = @ptrFromInt(manifest.data_vma);
        flashReadBuf(data_abs_flash, dst, manifest.data_size);
    }
    if (manifest.bss_size > 0) {
        const bss: [*]u8 = @ptrFromInt(manifest.bss_vma);
        @memset(bss[0..manifest.bss_size], 0);
    }

    const entry: *const fn (u32, u32) callconv(.c) noreturn = @ptrFromInt(manifest.entry_va);
    entry(initrd_va, initrd_size);
}
