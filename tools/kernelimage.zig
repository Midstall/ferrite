// Build a ferrite-on-ESP32-C6 kernel image: a small manifest + IROM
// payload (XIP'd from flash via cache) + .data initial values.
//
// Layout in the produced binary:
//   [0..40]:                manifest header
//   [40..0x10000]:          zero padding (manifest fits comfortably in
//                           the first MMU page; IROM payload begins on
//                           the next 64 KB boundary so the chip's MMU
//                           can map page-aligned flash -> page-aligned
//                           virtual addresses with no offset trickery)
//   [0x10000..0x10000+I]:   IROM payload (kernel .text + .rodata)
//   [pad to 4-byte align]
//   [next..next+D]:         .data initial values (LMA -> VMA copy source
//                           the bootloader uses to populate IRAM)
//
// Once flashed at offset 0x10000 of the chip flash, IROM payload sits
// at absolute flash 0x20000 - both page-aligned. Bootloader programs
// the flash MMU so virtual page N (0x42000000 + N*64K) -> flash page
// (0x20000/64K + N).

const std = @import("std");
const elf = std.elf;
const Io = std.Io;
const common = @import("common");

const MAGIC: u32 = 0xFE_71_C6_E1;
const SOC_IROM_LOW: u32 = 0x4200_0000;
const SOC_IRAM_LOW: u32 = 0x4080_0000;
const SOC_IRAM_HIGH: u32 = 0x4088_0000;
const MMU_PAGE_SIZE: usize = 0x1_0000; // 64 KB
const IROM_PAYLOAD_OFFSET: usize = 0x1_0000; // payload at next page after manifest

const Manifest = extern struct {
    magic: u32,
    entry_va: u32,
    irom_va: u32, // typically 0x42000000
    irom_flash_offset: u32, // relative to start of this file
    irom_size: u32,
    data_flash_offset: u32, // relative to start of this file
    data_vma: u32,
    data_size: u32,
    bss_vma: u32,
    bss_size: u32,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;
    const cwd: Io.Dir = .cwd();

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--input")) {
            i += 1;
            input_path = args[i];
        } else if (std.mem.eql(u8, a, "--output")) {
            i += 1;
            output_path = args[i];
        } else {
            return error.BadArgs;
        }
    }
    const in_path = input_path orelse return error.NoInput;
    const out_path = output_path orelse return error.NoOutput;

    const elf_bytes = try common.readAll(arena, cwd, io, in_path);
    if (elf_bytes.len < @sizeOf(elf.Elf32_Ehdr)) return error.NotElf;
    const ehdr = std.mem.bytesAsValue(elf.Elf32_Ehdr, elf_bytes[0..@sizeOf(elf.Elf32_Ehdr)]).*;
    if (ehdr.e_ident[elf.EI_CLASS] != elf.ELFCLASS32) return error.NotElf32;
    if (ehdr.e_machine != .RISCV) return error.NotRiscv;

    // Walk PT_LOADs. We expect:
    //  - One or more loads with VA in [0x42000000, 0x42xxxxxx)  -> IROM
    //  - One load with VA in IRAM + PA elsewhere               -> .data
    //    (linker emits VMA in IRAM, LMA in IROM via "AT > irom")
    //  - Optionally a load with FileSiz=0 in IRAM              -> .bss
    var irom_low: u32 = 0xFFFF_FFFF;
    var irom_high: u32 = 0;
    var data_lma: u32 = 0;
    var data_vma: u32 = 0;
    var data_size: u32 = 0;
    var bss_vma: u32 = 0;
    var bss_size: u32 = 0;

    var phi: u16 = 0;
    while (phi < ehdr.e_phnum) : (phi += 1) {
        const off: usize = @as(usize, @intCast(ehdr.e_phoff)) + phi * @as(usize, ehdr.e_phentsize);
        const ph = std.mem.bytesAsValue(elf.Elf32_Phdr, elf_bytes[off..][0..@sizeOf(elf.Elf32_Phdr)]).*;
        if (ph.p_type != elf.PT_LOAD) continue;
        if (ph.p_memsz == 0) continue;

        const va = ph.p_vaddr;
        const pa = ph.p_paddr;
        const fz = ph.p_filesz;
        const mz = ph.p_memsz;

        if (va >= SOC_IROM_LOW and va < SOC_IROM_LOW + 0x1000_0000) {
            // IROM (XIP) segment
            if (va < irom_low) irom_low = va;
            if (va + mz > irom_high) irom_high = va + mz;
        } else if (va >= SOC_IRAM_LOW and va < SOC_IRAM_HIGH) {
            if (fz == 0) {
                // .bss
                bss_vma = va;
                bss_size = mz;
            } else {
                // .data - VMA in IRAM, LMA in IROM (init values stored
                // in flash, copied by bootloader)
                data_vma = va;
                data_lma = pa;
                data_size = fz;
            }
        }
    }
    if (irom_low == 0xFFFF_FFFF) return error.NoIromSegment;
    if (irom_low != SOC_IROM_LOW) return error.IromMisaligned; // we hardcoded 0x42000000

    // Extract IROM bytes from the ELF. The PT_LOADs at IROM VAs have
    // p_offset pointing to the bytes in the ELF.
    var irom_bytes: std.array_list.Aligned(u8, null) = .empty;
    try irom_bytes.appendNTimes(arena, 0, irom_high - irom_low);
    phi = 0;
    while (phi < ehdr.e_phnum) : (phi += 1) {
        const off: usize = @as(usize, @intCast(ehdr.e_phoff)) + phi * @as(usize, ehdr.e_phentsize);
        const ph = std.mem.bytesAsValue(elf.Elf32_Phdr, elf_bytes[off..][0..@sizeOf(elf.Elf32_Phdr)]).*;
        if (ph.p_type != elf.PT_LOAD) continue;
        if (ph.p_filesz == 0) continue;
        const va = ph.p_vaddr;
        if (va >= SOC_IROM_LOW and va < SOC_IROM_LOW + 0x1000_0000) {
            const dst_off = va - irom_low;
            @memcpy(irom_bytes.items[dst_off .. dst_off + ph.p_filesz], elf_bytes[ph.p_offset .. ph.p_offset + ph.p_filesz]);
        }
    }

    // Extract .data initial values (from the IROM-side LMA in the ELF).
    var data_bytes: []const u8 = &[_]u8{};
    if (data_size > 0) {
        // The .data segment has p_paddr = LMA in IROM. Its p_offset in
        // the ELF still points to where the bytes live in the ELF file.
        phi = 0;
        while (phi < ehdr.e_phnum) : (phi += 1) {
            const off: usize = @as(usize, @intCast(ehdr.e_phoff)) + phi * @as(usize, ehdr.e_phentsize);
            const ph = std.mem.bytesAsValue(elf.Elf32_Phdr, elf_bytes[off..][0..@sizeOf(elf.Elf32_Phdr)]).*;
            if (ph.p_type != elf.PT_LOAD) continue;
            if (ph.p_vaddr == data_vma and ph.p_filesz == data_size) {
                data_bytes = elf_bytes[ph.p_offset .. ph.p_offset + ph.p_filesz];
                break;
            }
        }
    }

    // Build the output image.
    var image: std.array_list.Aligned(u8, null) = .empty;

    const irom_size: u32 = @intCast(irom_bytes.items.len);
    const data_flash_offset: u32 = @intCast(IROM_PAYLOAD_OFFSET + std.mem.alignForward(usize, irom_size, 4));

    const manifest: Manifest = .{
        .magic = MAGIC,
        .entry_va = @intCast(ehdr.e_entry),
        .irom_va = SOC_IROM_LOW,
        .irom_flash_offset = @intCast(IROM_PAYLOAD_OFFSET),
        .irom_size = irom_size,
        .data_flash_offset = data_flash_offset,
        .data_vma = data_vma,
        .data_size = data_size,
        .bss_vma = bss_vma,
        .bss_size = bss_size,
    };
    try image.appendSlice(arena, std.mem.asBytes(&manifest));

    // Pad to IROM payload offset.
    while (image.items.len < IROM_PAYLOAD_OFFSET) try image.append(arena, 0);

    // IROM payload at page-aligned offset.
    try image.appendSlice(arena, irom_bytes.items);

    // Align IROM payload tail to 4 bytes.
    while (image.items.len % 4 != 0) try image.append(arena, 0);

    // .data init values.
    try image.appendSlice(arena, data_bytes);

    try common.writeAll(cwd, io, out_path, image.items);
}
