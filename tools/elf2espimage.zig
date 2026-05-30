// Wraps an ELF into an Espressif v3 image (header + segments + SHA-256).
// Used by the ESP32-C6 ROM bootloader to load segments to SRAM and jump
// to the entry point.
//
// Image layout (per esp-idf esp_image_format.h):
//   [0]      magic = 0xE9
//   [1]      segment_count
//   [2]      flash_mode
//   [3]      flash_size_freq
//   [4..8]   entry_addr (LE u32)
//   [8]      wp_pin (0xEE = "do not modify")
//   [9..12]  SPI pin drive settings (zeros)
//   [12..14] chip_id (LE u16; ESP32-C6 = 13)
//   [14]     min_chip_rev_old
//   [15..17] min_chip_rev (LE u16)
//   [17..19] max_chip_rev (LE u16)
//   [19..23] reserved (zeros)
//   [23]     hash_appended (1)
// per segment:
//   load_addr (LE u32) | seg_size (LE u32) | data
// after segments: pad to 15 mod 16, then 1 checksum byte, then 32 B SHA-256.
//
// Checksum = 0xEF XOR (each byte of segment data, in order).

const std = @import("std");
const elf = std.elf;
const Io = std.Io;
const sha2 = std.crypto.hash.sha2;
const common = @import("common");

const ESP_IMAGE_MAGIC: u8 = 0xE9;
const ESP_CHECKSUM_INIT: u8 = 0xEF;
const CHIP_ID_ESP32_C6: u16 = 13;

const FlashMode = enum(u8) { qio = 0, qout = 1, dio = 2, dout = 3 };
// Flash size (high nibble) and frequency (low nibble) per esp-idf docs.
const FLASH_SIZE_FREQ: u8 = 0x20 | 0x02; // 4 MB, 40 MHz.

// Plain byte buffer, because `extern struct` would pad u16 fields and break
// the on-disk layout. Build the 24-byte header by hand.
fn buildHeader(out: *[24]u8, segment_count: u8, entry_addr: u32, chip_id: u16) void {
    out[0] = ESP_IMAGE_MAGIC;
    out[1] = segment_count;
    out[2] = @intFromEnum(FlashMode.dio);
    out[3] = FLASH_SIZE_FREQ;
    std.mem.writeInt(u32, out[4..8], entry_addr, .little);
    out[8] = 0xEE; // wp_pin: don't touch
    out[9] = 0;
    out[10] = 0;
    out[11] = 0;
    std.mem.writeInt(u16, out[12..14], chip_id, .little);
    out[14] = 0; // min_chip_rev_old
    std.mem.writeInt(u16, out[15..17], 0, .little);
    std.mem.writeInt(u16, out[17..19], 0xFFFF, .little);
    out[19] = 0;
    out[20] = 0;
    out[21] = 0;
    out[22] = 0;
    out[23] = 1; // hash_appended
}

const Segment = struct {
    load_addr: u32,
    data: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;
    const cwd: Io.Dir = .cwd();

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var chip_id: u16 = CHIP_ID_ESP32_C6;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--input")) {
            i += 1;
            input_path = args[i];
        } else if (std.mem.eql(u8, a, "--output")) {
            i += 1;
            output_path = args[i];
        } else if (std.mem.eql(u8, a, "--chip-id")) {
            i += 1;
            chip_id = try std.fmt.parseInt(u16, args[i], 0);
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

    var segments: std.array_list.Aligned(Segment, null) = .empty;

    var phi: u16 = 0;
    while (phi < ehdr.e_phnum) : (phi += 1) {
        const off: usize = @as(usize, @intCast(ehdr.e_phoff)) + phi * @as(usize, ehdr.e_phentsize);
        if (off + @sizeOf(elf.Elf32_Phdr) > elf_bytes.len) return error.Truncated;
        const ph = std.mem.bytesAsValue(elf.Elf32_Phdr, elf_bytes[off..][0..@sizeOf(elf.Elf32_Phdr)]).*;
        if (ph.p_type != elf.PT_LOAD) continue;
        if (ph.p_filesz == 0) continue;
        const data = elf_bytes[ph.p_offset..][0..ph.p_filesz];
        try segments.append(arena, .{ .load_addr = ph.p_vaddr, .data = data });
    }
    if (segments.items.len == 0) return error.NoSegments;
    if (segments.items.len > 16) return error.TooManySegments;

    var image: std.array_list.Aligned(u8, null) = .empty;

    var hdr_bytes: [24]u8 = undefined;
    buildHeader(&hdr_bytes, @intCast(segments.items.len), @intCast(ehdr.e_entry), chip_id);
    try image.appendSlice(arena, &hdr_bytes);

    var checksum: u8 = ESP_CHECKSUM_INIT;
    for (segments.items) |seg| {
        // ROM bootloader rejects images whose segment data isn't 4-byte
        // aligned ("Invalid image block, can't boot."). Pad with zeros.
        const padded_len = std.mem.alignForward(usize, seg.data.len, 4);
        var seg_hdr: [8]u8 = undefined;
        std.mem.writeInt(u32, seg_hdr[0..4], seg.load_addr, .little);
        std.mem.writeInt(u32, seg_hdr[4..8], @intCast(padded_len), .little);
        try image.appendSlice(arena, &seg_hdr);
        try image.appendSlice(arena, seg.data);
        for (seg.data) |b| checksum ^= b;
        var pad: usize = seg.data.len;
        while (pad < padded_len) : (pad += 1) {
            try image.append(arena, 0);
            checksum ^= 0;
        }
    }

    while ((image.items.len + 1) % 16 != 0) try image.append(arena, 0);
    try image.append(arena, checksum);

    var digest: [sha2.Sha256.digest_length]u8 = undefined;
    sha2.Sha256.hash(image.items, &digest, .{});
    try image.appendSlice(arena, &digest);

    try common.writeAll(cwd, io, out_path, image.items);
}
