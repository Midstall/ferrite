const std = @import("std");
const macho = std.macho;
const builtin = @import("builtin");

pub const LC_FERRITE_AUTH: u32 = 0x1000;

pub const ferrite_auth_command = extern struct {
    cmd: u32 = LC_FERRITE_AUTH,
    cmdsize: u32 = @sizeOf(ferrite_auth_command),
    authority: u32 = 0,
    manifest_count: u32 = 0,
};

/// Path bytes follow inline, padded to 8-byte alignment before the next
/// entry.
pub const ManifestEntry = extern struct {
    kind: u16,
    rights: u16,
    /// No terminator.
    path_len: u32,
};

pub const LC_FERRITE_REBASE: u32 = 0x1001;

pub const ferrite_rebase_command = extern struct {
    cmd: u32 = LC_FERRITE_REBASE,
    cmdsize: u32 = @sizeOf(ferrite_rebase_command),
    count: u32 = 0,
    _pad: u32 = 0,
};

pub const FerriteRebaseEntry = extern struct {
    r_offset: u64,
    r_addend: u64,
};

pub const CPU_TYPE_X86: macho.cpu_type_t = 0x00000007;
pub const CPU_TYPE_X86_64: macho.cpu_type_t = 0x01000007;
pub const CPU_TYPE_ARM64: macho.cpu_type_t = 0x0100000C;
/// Ferrite-only. Apple has no official RISC-V value, so we invent ones
/// that share the high-bits 0x00FE_xxxx prefix. RISCV64 keeps bit 0 set
/// to follow the LP64 convention CPU_TYPE_X86_64 uses.
pub const CPU_TYPE_RISCV32: macho.cpu_type_t = @bitCast(@as(i32, 0x00FE0000));
pub const CPU_TYPE_RISCV64: macho.cpu_type_t = @bitCast(@as(i32, 0x00FE0001));

pub inline fn nativeCpuType() macho.cpu_type_t {
    return switch (builtin.cpu.arch) {
        .aarch64 => CPU_TYPE_ARM64,
        .x86_64 => CPU_TYPE_X86_64,
        .x86 => CPU_TYPE_X86,
        .riscv32 => CPU_TYPE_RISCV32,
        .riscv64 => CPU_TYPE_RISCV64,
        else => @compileError("macho.nativeCpuType: unsupported arch"),
    };
}

pub const Error = error{
    Truncated,
    BadMagic,
    NotExecutable,
    NoMatchingSlice,
    Unsupported,
    TooManyCommands,
    BadCommand,
};

// Fat (universal) binary.

/// Returns `bytes` unchanged if the image is already thin. Fat headers
/// are big-endian on disk.
pub fn pickArch(bytes: []const u8, want: macho.cpu_type_t) Error![]const u8 {
    if (bytes.len < @sizeOf(macho.fat_header)) return error.Truncated;
    const magic = std.mem.readInt(u32, bytes[0..4], .little);

    switch (magic) {
        macho.MH_MAGIC_64, macho.MH_CIGAM_64 => {
            if (bytes.len < @sizeOf(macho.mach_header_64)) return error.Truncated;
            const hdr = std.mem.bytesAsValue(macho.mach_header_64, bytes[0..@sizeOf(macho.mach_header_64)]).*;
            if (hdr.cputype != want) return error.NoMatchingSlice;
            return bytes;
        },
        macho.FAT_MAGIC, macho.FAT_CIGAM => {},
        else => return error.BadMagic,
    }

    const nfat = std.mem.readInt(u32, bytes[4..8], .big);
    var off: usize = @sizeOf(macho.fat_header);
    var i: u32 = 0;
    while (i < nfat) : (i += 1) {
        const end = off + @sizeOf(macho.fat_arch);
        if (end > bytes.len) return error.Truncated;
        const cputype: macho.cpu_type_t = @bitCast(std.mem.readInt(u32, bytes[off..][0..4], .big));
        const slice_off = std.mem.readInt(u32, bytes[off + 8 ..][0..4], .big);
        const slice_size = std.mem.readInt(u32, bytes[off + 12 ..][0..4], .big);
        off = end;

        if (cputype != want) continue;
        const lo: usize = @intCast(slice_off);
        const hi: usize = @intCast(slice_off + slice_size);
        if (hi > bytes.len) return error.Truncated;
        return bytes[lo..hi];
    }
    return error.NoMatchingSlice;
}

// Thin parser.

pub const SegmentView = struct {
    name: [16]u8,
    vmaddr: u64,
    vmsize: u64,
    fileoff: u64,
    filesize: u64,
    /// Apple's maxprot encoding: 0x1=R, 0x2=W, 0x4=X.
    maxprot: u32,
};

pub const Image = struct {
    bytes: []const u8,
    cputype: macho.cpu_type_t,
    pie: bool,
    /// File offset of the entry function (LC_MAIN.entryoff).
    entry_off: u64,
    /// 0 means loader default.
    stack_size: u64,
    /// Empty slice means unsigned.
    signature: []const u8,
    sig_off: u64,
    sig_size: u64,
    /// Cast to `process.Authority`.
    authority_bits: u32,
    manifest_blob: []const u8,
    manifest_count: u32,
    n_segments: u32,
    /// Byte-aligned slice into the raw load-command stream.
    rebases: []align(1) const FerriteRebaseEntry,
};

pub fn parseThin(bytes: []const u8) Error!Image {
    if (bytes.len < @sizeOf(macho.mach_header_64)) return error.Truncated;
    const hdr = std.mem.bytesAsValue(macho.mach_header_64, bytes[0..@sizeOf(macho.mach_header_64)]).*;
    if (hdr.magic != macho.MH_MAGIC_64) return error.BadMagic;
    if (hdr.filetype != macho.MH_EXECUTE) return error.NotExecutable;

    var image: Image = .{
        .bytes = bytes,
        .cputype = hdr.cputype,
        .pie = (hdr.flags & macho.MH_PIE) != 0,
        .entry_off = 0,
        .stack_size = 0,
        .signature = &.{},
        .sig_off = 0,
        .sig_size = 0,
        .authority_bits = 0,
        .manifest_blob = &.{},
        .manifest_count = 0,
        .n_segments = 0,
        .rebases = &.{},
    };

    var cur: usize = @sizeOf(macho.mach_header_64);
    var i: u32 = 0;
    while (i < hdr.ncmds) : (i += 1) {
        if (cur + @sizeOf(macho.load_command) > bytes.len) return error.Truncated;
        const lc = std.mem.bytesAsValue(macho.load_command, bytes[cur..][0..@sizeOf(macho.load_command)]).*;
        if (lc.cmdsize < @sizeOf(macho.load_command)) return error.BadCommand;
        const end = cur + lc.cmdsize;
        if (end > bytes.len) return error.Truncated;

        switch (@intFromEnum(lc.cmd)) {
            @intFromEnum(macho.LC.SEGMENT_64) => image.n_segments += 1,
            @intFromEnum(macho.LC.MAIN) => {
                if (lc.cmdsize < @sizeOf(macho.entry_point_command)) return error.BadCommand;
                const ep = std.mem.bytesAsValue(
                    macho.entry_point_command,
                    bytes[cur..][0..@sizeOf(macho.entry_point_command)],
                ).*;
                image.entry_off = ep.entryoff;
                image.stack_size = ep.stacksize;
            },
            @intFromEnum(macho.LC.CODE_SIGNATURE) => {
                if (lc.cmdsize < @sizeOf(macho.linkedit_data_command)) return error.BadCommand;
                const led = std.mem.bytesAsValue(
                    macho.linkedit_data_command,
                    bytes[cur..][0..@sizeOf(macho.linkedit_data_command)],
                ).*;
                const sig_lo: usize = @intCast(led.dataoff);
                const sig_hi: usize = @intCast(@as(u64, led.dataoff) + @as(u64, led.datasize));
                if (sig_hi > bytes.len) return error.Truncated;
                image.signature = bytes[sig_lo..sig_hi];
                image.sig_off = led.dataoff;
                image.sig_size = led.datasize;
            },
            LC_FERRITE_AUTH => {
                if (lc.cmdsize < @sizeOf(ferrite_auth_command)) return error.BadCommand;
                const auth = std.mem.bytesAsValue(
                    ferrite_auth_command,
                    bytes[cur..][0..@sizeOf(ferrite_auth_command)],
                ).*;
                image.authority_bits = auth.authority;
                image.manifest_count = auth.manifest_count;
                image.manifest_blob = bytes[cur + @sizeOf(ferrite_auth_command) .. end];
            },
            LC_FERRITE_REBASE => {
                if (lc.cmdsize < @sizeOf(ferrite_rebase_command)) return error.BadCommand;
                const reb = std.mem.bytesAsValue(
                    ferrite_rebase_command,
                    bytes[cur..][0..@sizeOf(ferrite_rebase_command)],
                ).*;
                const lo = cur + @sizeOf(ferrite_rebase_command);
                const expected = @as(usize, reb.count) * @sizeOf(FerriteRebaseEntry);
                if (lo + expected > end) return error.BadCommand;
                const entry_bytes = bytes[lo .. lo + expected];
                image.rebases = std.mem.bytesAsSlice(FerriteRebaseEntry, entry_bytes);
            },
            else => {},
        }

        cur = end;
        if (i == std.math.maxInt(u32) - 1) return error.TooManyCommands;
    }

    return image;
}

/// Stops on the first callback error.
pub fn forEachSegment(
    image: *const Image,
    ctx: anytype,
    comptime cb: fn (@TypeOf(ctx), SegmentView) anyerror!void,
) (Error || anyerror)!void {
    const bytes = image.bytes;
    const hdr = std.mem.bytesAsValue(macho.mach_header_64, bytes[0..@sizeOf(macho.mach_header_64)]).*;
    var cur: usize = @sizeOf(macho.mach_header_64);
    var i: u32 = 0;
    while (i < hdr.ncmds) : (i += 1) {
        const lc = std.mem.bytesAsValue(macho.load_command, bytes[cur..][0..@sizeOf(macho.load_command)]).*;
        const end = cur + lc.cmdsize;
        if (@intFromEnum(lc.cmd) == @intFromEnum(macho.LC.SEGMENT_64)) {
            if (lc.cmdsize < @sizeOf(macho.segment_command_64)) return error.BadCommand;
            const seg = std.mem.bytesAsValue(
                macho.segment_command_64,
                bytes[cur..][0..@sizeOf(macho.segment_command_64)],
            ).*;
            try cb(ctx, .{
                .name = seg.segname,
                .vmaddr = seg.vmaddr,
                .vmsize = seg.vmsize,
                .fileoff = seg.fileoff,
                .filesize = seg.filesize,
                .maxprot = @bitCast(seg.maxprot),
            });
        }
        cur = end;
    }
}
