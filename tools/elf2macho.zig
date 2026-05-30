// Wraps a freestanding PIE ELF in a 64-bit Mach-O. i386 vmaddrs are zero-extended.
// Segment vmaddrs are aligned down to 64K (covers arm64 4K/16K/64K granules);
// Zig's linker emits non-page-aligned PT_LOADs, so we down-align and zero-pad.

const std = @import("std");
const Io = std.Io;
const macho = std.macho;
const elf = std.elf;
const common = @import("common");

// Page-granule for ELF segment alignment in the generated Mach-O. Must
// match the kernel-loader page size for this target - using a larger value
// causes back-to-back ELF LOADs at small offsets to all align to the same
// coarse base, and the loader's later RW segment then overwrites the
// earlier R+X mapping (init takes an instruction-page-fault on first
// U-mode fetch). Set via `--page-size=N`; defaults to 4 KB.
var page: u64 = 0x1000;
const MAX_SEGS: usize = 16;

// Ferrite-only CPU types for RISC-V. Mirrors kernel/src/macho.zig.
const CPU_TYPE_RISCV32: macho.cpu_type_t = @bitCast(@as(i32, 0x00FE0000));
const CPU_TYPE_RISCV64: macho.cpu_type_t = @bitCast(@as(i32, 0x00FE0001));

const BindSpec = struct {
    name: []const u8,
    kind: u16,
    rights: u16,
};

fn parseBindSpec(s: []const u8) !BindSpec {
    const eq = std.mem.indexOfScalar(u8, s, '=') orelse return error.BadSpec;
    const name = s[0..eq];
    const after = s[eq + 1 ..];
    const colon = std.mem.indexOfScalar(u8, after, ':') orelse return error.BadSpec;
    const kind_str = after[0..colon];
    const rights_str = after[colon + 1 ..];
    if (name.len == 0) return error.BadSpec;

    const kind: u16 = if (std.mem.eql(u8, kind_str, "channel_send"))
        1
    else if (std.mem.eql(u8, kind_str, "channel_recv"))
        2
    else if (std.mem.eql(u8, kind_str, "mem_region"))
        3
    else if (std.mem.eql(u8, kind_str, "aspace"))
        4
    else if (std.mem.eql(u8, kind_str, "thread"))
        5
    else if (std.mem.eql(u8, kind_str, "process"))
        6
    else if (std.mem.eql(u8, kind_str, "irq"))
        7
    else
        return error.BadSpec;

    var rights: u16 = 0;
    for (rights_str) |c| {
        switch (c) {
            'r' => rights |= 1 << 0,
            'w' => rights |= 1 << 1,
            'm' => rights |= 1 << 2,
            'g' => rights |= 1 << 3,
            's' => rights |= 1 << 4,
            else => return error.BadSpec,
        }
    }
    return .{ .name = name, .kind = kind, .rights = rights };
}

const Seg = struct {
    vaddr: u64,
    aligned_vaddr: u64,
    aligned_vmsize: u64,
    macho_filesize: u64,
    leading_pad: u64,
    file_off: u64,
    filesz: u64,
    flags: u32,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var unsigned = false;
    var authority: u32 = 0;
    var binds: std.array_list.Aligned(BindSpec, null) = .empty;
    var pos: [3]?[]const u8 = .{ null, null, null };
    var n: usize = 0;
    var ai: usize = 1;
    while (ai < args.len) : (ai += 1) {
        const a = args[ai];
        if (std.mem.eql(u8, a, "--unsigned")) {
            unsigned = true;
        } else if (std.mem.startsWith(u8, a, "--authority=")) {
            const v = a["--authority=".len..];
            authority = std.fmt.parseInt(u32, v, 0) catch {
                common.stdoutPrint(io, "bad --authority value: {s}\n", .{v});
                return error.BadUsage;
            };
        } else if (std.mem.startsWith(u8, a, "--page-size=")) {
            const v = a["--page-size=".len..];
            page = std.fmt.parseInt(u64, v, 0) catch {
                common.stdoutPrint(io, "bad --page-size value: {s}\n", .{v});
                return error.BadUsage;
            };
            if (page == 0 or (page & (page - 1)) != 0) {
                common.stdoutPrint(io, "--page-size must be a non-zero power of two\n", .{});
                return error.BadUsage;
            }
        } else if (std.mem.startsWith(u8, a, "--bind=")) {
            const spec = parseBindSpec(a["--bind=".len..]) catch {
                common.stdoutPrint(io, "bad --bind spec: {s}\n", .{a});
                common.stdoutPrint(io, "  expected `name=kind:rights` where kind is one of\n", .{});
                common.stdoutPrint(io, "  channel_send/channel_recv/mem_region/aspace/thread/process/irq\n", .{});
                common.stdoutPrint(io, "  and rights is a subset of letters r/w/m/g/s\n", .{});
                return error.BadUsage;
            };
            try binds.append(arena, spec);
        } else {
            if (n >= pos.len) {
                common.stdoutPrint(io, "usage: {s} [--unsigned] [--authority=BITS] [--bind=name=kind:rights]* <key.key> <input.elf> <out.macho>\n", .{args[0]});
                return error.BadUsage;
            }
            pos[n] = a;
            n += 1;
        }
    }
    if (n != 3) {
        common.stdoutPrint(io, "usage: {s} [--unsigned] [--authority=BITS] [--bind=name=kind:rights]* <key.key> <input.elf> <out.macho>\n", .{args[0]});
        return error.BadUsage;
    }
    const key_path = pos[0].?;
    const elf_path = pos[1].?;
    const out_path = pos[2].?;

    const cwd: Io.Dir = .cwd();
    const kp = try common.loadKey(cwd, io, key_path);
    const pub_bytes = kp.public_key.toBytes();
    var keyid: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&pub_bytes, &keyid, .{});

    const elf_bytes = try common.readAll(arena, cwd, io, elf_path);

    if (elf_bytes.len < 64) return error.NotElf;
    if (!std.mem.eql(u8, elf_bytes[0..4], "\x7fELF")) return error.NotElf;
    const class = elf_bytes[elf.EI_CLASS];

    var entry_va: u64 = 0;
    var machine: elf.EM = .NONE;
    var segs: [MAX_SEGS]Seg = undefined;
    var nsegs: usize = 0;

    switch (class) {
        elf.ELFCLASS64 => {
            if (elf_bytes.len < @sizeOf(elf.Elf64_Ehdr)) return error.NotElf;
            const ehdr = std.mem.bytesAsValue(elf.Elf64_Ehdr, elf_bytes[0..@sizeOf(elf.Elf64_Ehdr)]).*;
            entry_va = ehdr.e_entry;
            machine = ehdr.e_machine;
            var i: usize = 0;
            while (i < ehdr.e_phnum) : (i += 1) {
                const off = @as(usize, @intCast(ehdr.e_phoff)) + i * @as(usize, ehdr.e_phentsize);
                if (off + @sizeOf(elf.Elf64_Phdr) > elf_bytes.len) return error.Truncated;
                const phdr = std.mem.bytesAsValue(elf.Elf64_Phdr, elf_bytes[off..][0..@sizeOf(elf.Elf64_Phdr)]).*;
                if (phdr.p_type != elf.PT_LOAD) continue;
                if (phdr.p_memsz == 0) continue;
                try pushSeg(&segs, &nsegs, phdr.p_vaddr, phdr.p_memsz, phdr.p_offset, phdr.p_filesz, phdr.p_flags);
            }
        },
        elf.ELFCLASS32 => {
            if (elf_bytes.len < @sizeOf(elf.Elf32_Ehdr)) return error.NotElf;
            const ehdr = std.mem.bytesAsValue(elf.Elf32_Ehdr, elf_bytes[0..@sizeOf(elf.Elf32_Ehdr)]).*;
            entry_va = ehdr.e_entry;
            machine = ehdr.e_machine;
            var i: usize = 0;
            while (i < ehdr.e_phnum) : (i += 1) {
                const off = @as(usize, @intCast(ehdr.e_phoff)) + i * @as(usize, ehdr.e_phentsize);
                if (off + @sizeOf(elf.Elf32_Phdr) > elf_bytes.len) return error.Truncated;
                const phdr = std.mem.bytesAsValue(elf.Elf32_Phdr, elf_bytes[off..][0..@sizeOf(elf.Elf32_Phdr)]).*;
                if (phdr.p_type != elf.PT_LOAD) continue;
                if (phdr.p_memsz == 0) continue;
                try pushSeg(&segs, &nsegs, phdr.p_vaddr, phdr.p_memsz, phdr.p_offset, phdr.p_filesz, phdr.p_flags);
            }
        },
        else => return error.NotElf,
    }
    if (nsegs == 0) return error.NoLoadSegments;

    const cputype: macho.cpu_type_t = switch (machine) {
        .AARCH64 => macho.CPU_TYPE_ARM64,
        .X86_64 => macho.CPU_TYPE_X86_64,
        .RISCV => if (class == elf.ELFCLASS64) CPU_TYPE_RISCV64 else CPU_TYPE_RISCV32,
        .@"386" => 0x00000007, // CPU_TYPE_X86
        else => return error.WrongMachine,
    };

    const rebases = try collectRebases(arena, elf_bytes, machine, class);
    const rebase_lc_size: u32 = if (rebases.len == 0)
        0
    else
        @intCast(@sizeOf(common.FerriteRebaseCommand) + rebases.len * @sizeOf(common.FerriteRebaseEntry));
    const rebase_lc_count: u32 = if (rebases.len == 0) 0 else 1;

    // Manifest entry: {kind:u16, rights:u16, path_len:u32}+path, padded to 8.
    var manifest_bytes: u32 = 0;
    for (binds.items) |b| {
        manifest_bytes += @intCast(common.alignUp(@as(u64, 8) + b.name.len, 8));
    }

    const ncmds: u32 = @intCast(nsegs + 1 + 1 + 1 + 1 + rebase_lc_count);
    const fixed_cmds_size: usize = nsegs * @sizeOf(macho.segment_command_64) +
        @sizeOf(macho.segment_command_64) +
        @sizeOf(macho.entry_point_command) +
        @sizeOf(common.FerriteAuthCommand) +
        @sizeOf(macho.linkedit_data_command);
    const cmds_size: u32 = @intCast(fixed_cmds_size + rebase_lc_size + manifest_bytes);

    var macho_file_offs: [MAX_SEGS]u64 = undefined;
    var cursor: u64 = page;
    for (segs[0..nsegs], 0..) |s, k| {
        macho_file_offs[k] = cursor;
        cursor += s.aligned_vmsize;
    }
    const linkedit_file_off = cursor;
    const total_size = linkedit_file_off + common.SIG_BLOB_SIZE;

    var max_vaddr_end: u64 = 0;
    for (segs[0..nsegs]) |s| {
        const e = s.aligned_vaddr + s.aligned_vmsize;
        if (e > max_vaddr_end) max_vaddr_end = e;
    }
    const linkedit_vmaddr = max_vaddr_end;

    var buf = try arena.alloc(u8, @intCast(total_size));
    @memset(buf, 0);

    const header: macho.mach_header_64 = .{
        .magic = macho.MH_MAGIC_64,
        .cputype = cputype,
        .cpusubtype = 0,
        .filetype = macho.MH_EXECUTE,
        .ncmds = ncmds,
        .sizeofcmds = cmds_size,
        .flags = macho.MH_PIE | macho.MH_NOUNDEFS,
        .reserved = 0,
    };
    @memcpy(buf[0..@sizeOf(macho.mach_header_64)], std.mem.asBytes(&header));

    var lc_cur: usize = @sizeOf(macho.mach_header_64);

    for (segs[0..nsegs], 0..) |s, k| {
        const prot = protFromElfFlags(s.flags);
        const macho_off = macho_file_offs[k];
        // filesize = aligned_vmsize: the file actually has the full zero-
        // padded vmsize bytes (we layout segments back-to-back at
        // page-aligned offsets). Setting it to just `macho_filesize` would
        // leave e_entry pointing into the zero-pad region unreachable from
        // the kernel loader's `[fileoff, fileoff+filesize)` check (which
        // happens on architectures where Zig parks code past .text's
        // file-backed bytes - observed on riscv64 PIE).
        const seg_cmd: macho.segment_command_64 = .{
            .cmd = .SEGMENT_64,
            .cmdsize = @sizeOf(macho.segment_command_64),
            .segname = segName(k),
            .vmaddr = s.aligned_vaddr,
            .vmsize = s.aligned_vmsize,
            .fileoff = macho_off,
            .filesize = s.aligned_vmsize,
            .maxprot = prot,
            .initprot = prot,
            .nsects = 0,
            .flags = 0,
        };
        @memcpy(buf[lc_cur..][0..@sizeOf(macho.segment_command_64)], std.mem.asBytes(&seg_cmd));
        lc_cur += @sizeOf(macho.segment_command_64);

        const lp: usize = @intCast(s.leading_pad);
        const dst_lo: usize = @intCast(macho_off);
        @memset(buf[dst_lo .. dst_lo + lp], 0);

        const lo: usize = @intCast(s.file_off);
        const hi: usize = lo + @as(usize, @intCast(s.filesz));
        if (hi > elf_bytes.len) return error.Truncated;
        @memcpy(buf[dst_lo + lp .. dst_lo + lp + @as(usize, @intCast(s.filesz))], elf_bytes[lo..hi]);
    }

    const linkedit_cmd: macho.segment_command_64 = .{
        .cmd = .SEGMENT_64,
        .cmdsize = @sizeOf(macho.segment_command_64),
        .segname = common.strName("__LINKEDIT"),
        .vmaddr = linkedit_vmaddr,
        .vmsize = page,
        .fileoff = linkedit_file_off,
        .filesize = common.SIG_BLOB_SIZE,
        .maxprot = .{ .READ = true },
        .initprot = .{ .READ = true },
        .nsects = 0,
        .flags = 0,
    };
    @memcpy(buf[lc_cur..][0..@sizeOf(macho.segment_command_64)], std.mem.asBytes(&linkedit_cmd));
    lc_cur += @sizeOf(macho.segment_command_64);

    const entry_macho_off = mapVaToMachoOff(entry_va, segs[0..nsegs], &macho_file_offs) orelse return error.BadEntry;
    const main_cmd: macho.entry_point_command = .{
        .cmd = .MAIN,
        .cmdsize = @sizeOf(macho.entry_point_command),
        .entryoff = entry_macho_off,
        .stacksize = 0,
    };
    @memcpy(buf[lc_cur..][0..@sizeOf(macho.entry_point_command)], std.mem.asBytes(&main_cmd));
    lc_cur += @sizeOf(macho.entry_point_command);

    const auth_cmd: common.FerriteAuthCommand = .{
        .cmdsize = @intCast(@sizeOf(common.FerriteAuthCommand) + manifest_bytes),
        .authority = authority,
        .manifest_count = @intCast(binds.items.len),
    };
    @memcpy(buf[lc_cur..][0..@sizeOf(common.FerriteAuthCommand)], std.mem.asBytes(&auth_cmd));
    lc_cur += @sizeOf(common.FerriteAuthCommand);
    for (binds.items) |b| {
        std.mem.writeInt(u16, buf[lc_cur..][0..2], b.kind, .little);
        std.mem.writeInt(u16, buf[lc_cur + 2 ..][0..2], b.rights, .little);
        std.mem.writeInt(u32, buf[lc_cur + 4 ..][0..4], @intCast(b.name.len), .little);
        @memcpy(buf[lc_cur + 8 ..][0..b.name.len], b.name);
        const entry_bytes = common.alignUp(@as(u64, 8) + b.name.len, 8);
        lc_cur += @intCast(entry_bytes);
    }

    if (rebases.len != 0) {
        const rebase_cmd: common.FerriteRebaseCommand = .{
            .cmdsize = rebase_lc_size,
            .count = @intCast(rebases.len),
        };
        @memcpy(buf[lc_cur..][0..@sizeOf(common.FerriteRebaseCommand)], std.mem.asBytes(&rebase_cmd));
        lc_cur += @sizeOf(common.FerriteRebaseCommand);
        for (rebases) |r| {
            @memcpy(buf[lc_cur..][0..@sizeOf(common.FerriteRebaseEntry)], std.mem.asBytes(&r));
            lc_cur += @sizeOf(common.FerriteRebaseEntry);
        }
    }

    const sig_cmd: macho.linkedit_data_command = .{
        .cmd = .CODE_SIGNATURE,
        .cmdsize = @sizeOf(macho.linkedit_data_command),
        .dataoff = @intCast(linkedit_file_off),
        .datasize = common.SIG_BLOB_SIZE,
    };
    @memcpy(buf[lc_cur..][0..@sizeOf(macho.linkedit_data_command)], std.mem.asBytes(&sig_cmd));

    const blob_hdr: common.SigBlobHeader = .{
        .magic = common.SIG_MAGIC,
        .version = 1,
        .algo = if (unsigned) @intFromEnum(common.SigAlgo.none) else @intFromEnum(common.SigAlgo.ed25519),
        .keyid = if (unsigned) @splat(0) else keyid,
        .sig_len = if (unsigned) 0 else 64,
    };
    @memcpy(buf[@intCast(linkedit_file_off)..][0..@sizeOf(common.SigBlobHeader)], std.mem.asBytes(&blob_hdr));

    if (!unsigned) try common.signInPlace(buf, &kp);

    try common.writeAll(.cwd(), io, out_path, buf);
}

fn pushSeg(
    segs: *[MAX_SEGS]Seg,
    nsegs: *usize,
    vaddr: u64,
    memsz: u64,
    file_off: u64,
    filesz: u64,
    flags: u32,
) !void {
    if (nsegs.* >= MAX_SEGS) return error.TooManySegments;
    const aligned_va = vaddr & ~(page - 1);
    const leading_pad = vaddr - aligned_va;
    const aligned_size = common.alignUp(leading_pad + memsz, page);
    const macho_filesz = leading_pad + filesz;
    segs[nsegs.*] = .{
        .vaddr = vaddr,
        .aligned_vaddr = aligned_va,
        .aligned_vmsize = aligned_size,
        .macho_filesize = macho_filesz,
        .leading_pad = leading_pad,
        .file_off = file_off,
        .filesz = filesz,
        .flags = flags,
    };
    nsegs.* += 1;
}

fn protFromElfFlags(flags: u32) macho.vm_prot_t {
    return .{
        .READ = (flags & elf.PF_R) != 0,
        .WRITE = (flags & elf.PF_W) != 0,
        .EXEC = (flags & elf.PF_X) != 0,
    };
}

fn segName(idx: usize) [16]u8 {
    return switch (idx) {
        0 => common.strName("__TEXT"),
        1 => common.strName("__DATA"),
        2 => common.strName("__BSS"),
        else => blk: {
            var out: [16]u8 = @splat(0);
            _ = std.fmt.bufPrint(&out, "__SEG{d}", .{idx}) catch {};
            break :blk out;
        },
    };
}

/// PT_LOAD VA -> file offset for SHT_REL addend reads on 32-bit ELF.
fn vaToFileOff32(elf_bytes: []const u8, ehdr: elf.Elf32_Ehdr, va: u64) ?usize {
    var i: usize = 0;
    while (i < ehdr.e_phnum) : (i += 1) {
        const off = @as(usize, @intCast(ehdr.e_phoff)) + i * @as(usize, ehdr.e_phentsize);
        if (off + @sizeOf(elf.Elf32_Phdr) > elf_bytes.len) return null;
        const phdr = std.mem.bytesAsValue(elf.Elf32_Phdr, elf_bytes[off..][0..@sizeOf(elf.Elf32_Phdr)]).*;
        if (phdr.p_type != elf.PT_LOAD) continue;
        const lo: u64 = phdr.p_vaddr;
        const hi: u64 = phdr.p_vaddr + phdr.p_filesz;
        if (va >= lo and va < hi) {
            return @as(usize, @intCast(phdr.p_offset + (va - phdr.p_vaddr)));
        }
    }
    return null;
}

fn mapVaToMachoOff(va: u64, segs: anytype, macho_offs: *const [MAX_SEGS]u64) ?u64 {
    for (segs, 0..) |s, k| {
        if (va >= s.aligned_vaddr and va < s.aligned_vaddr + s.aligned_vmsize) {
            return macho_offs[k] + (va - s.aligned_vaddr);
        }
    }
    return null;
}

/// Statically-linked PIE only emits R_*_RELATIVE; the kernel loader can't resolve others.
fn relativeRelocType(machine: elf.EM) ?u32 {
    return switch (machine) {
        .AARCH64 => @intFromEnum(elf.R_AARCH64.RELATIVE),
        .X86_64 => 8, // R_X86_64_RELATIVE
        .@"386" => 8, // R_386_RELATIVE
        .RISCV => 3, // R_RISCV_RELATIVE
        else => null,
    };
}

/// Rejects any non-RELATIVE reloc - see relativeRelocType.
fn collectRebases(
    arena: std.mem.Allocator,
    elf_bytes: []const u8,
    machine: elf.EM,
    class: u8,
) ![]common.FerriteRebaseEntry {
    var list: std.array_list.Aligned(common.FerriteRebaseEntry, null) = .empty;
    const rel_type = relativeRelocType(machine) orelse return list.toOwnedSlice(arena);

    switch (class) {
        elf.ELFCLASS64 => {
            const ehdr = std.mem.bytesAsValue(elf.Elf64_Ehdr, elf_bytes[0..@sizeOf(elf.Elf64_Ehdr)]).*;
            const shoff: usize = @intCast(ehdr.e_shoff);
            const shentsize: usize = ehdr.e_shentsize;
            const shnum: usize = ehdr.e_shnum;
            var si: usize = 0;
            while (si < shnum) : (si += 1) {
                const off = shoff + si * shentsize;
                if (off + @sizeOf(elf.Elf64_Shdr) > elf_bytes.len) break;
                const shdr = std.mem.bytesAsValue(elf.Elf64_Shdr, elf_bytes[off..][0..@sizeOf(elf.Elf64_Shdr)]).*;
                if (shdr.sh_type != elf.SHT_RELA) continue;
                const rela_off: usize = @intCast(shdr.sh_offset);
                const rela_size: usize = @intCast(shdr.sh_size);
                const ent_size: usize = @intCast(shdr.sh_entsize);
                if (ent_size < @sizeOf(elf.Elf64_Rela)) continue;
                var rp: usize = 0;
                while (rp + ent_size <= rela_size) : (rp += ent_size) {
                    if (rela_off + rp + @sizeOf(elf.Elf64_Rela) > elf_bytes.len) break;
                    const rel = std.mem.bytesAsValue(
                        elf.Elf64_Rela,
                        elf_bytes[rela_off + rp ..][0..@sizeOf(elf.Elf64_Rela)],
                    ).*;
                    const r_type = rel.r_type();
                    if (r_type == 0) continue; // R_*_NONE
                    if (r_type != rel_type) return error.UnresolvedReloc;
                    try list.append(arena, .{
                        .r_offset = rel.r_offset,
                        .r_addend = @bitCast(rel.r_addend),
                    });
                }
            }
        },
        elf.ELFCLASS32 => {
            // Two relocation formats hit this path:
            //  - i386 uses SHT_REL (no explicit addend; addend lives at
            //    the target memory location, must be read by translating
            //    r_offset (a VA) -> file offset via PT_LOAD).
            //  - riscv32 uses SHT_RELA (explicit r_addend in the record).
            // Walk both kinds.
            const ehdr = std.mem.bytesAsValue(elf.Elf32_Ehdr, elf_bytes[0..@sizeOf(elf.Elf32_Ehdr)]).*;
            const shoff: usize = @intCast(ehdr.e_shoff);
            const shentsize: usize = ehdr.e_shentsize;
            const shnum: usize = ehdr.e_shnum;
            var si: usize = 0;
            while (si < shnum) : (si += 1) {
                const off = shoff + si * shentsize;
                if (off + @sizeOf(elf.Elf32_Shdr) > elf_bytes.len) break;
                const shdr = std.mem.bytesAsValue(elf.Elf32_Shdr, elf_bytes[off..][0..@sizeOf(elf.Elf32_Shdr)]).*;
                if (shdr.sh_type == elf.SHT_REL) {
                    const rel_off: usize = @intCast(shdr.sh_offset);
                    const rel_size: usize = @intCast(shdr.sh_size);
                    const ent_size: usize = @intCast(shdr.sh_entsize);
                    if (ent_size < @sizeOf(elf.Elf32_Rel)) continue;
                    var rp: usize = 0;
                    while (rp + ent_size <= rel_size) : (rp += ent_size) {
                        if (rel_off + rp + @sizeOf(elf.Elf32_Rel) > elf_bytes.len) break;
                        const rel = std.mem.bytesAsValue(
                            elf.Elf32_Rel,
                            elf_bytes[rel_off + rp ..][0..@sizeOf(elf.Elf32_Rel)],
                        ).*;
                        const r_type = rel.r_type();
                        if (r_type == 0) continue;
                        if (r_type != rel_type) return error.UnresolvedReloc;
                        const va: u64 = @intCast(rel.r_offset);
                        const file_off = vaToFileOff32(elf_bytes, ehdr, va) orelse return error.UnresolvedReloc;
                        if (file_off + 4 > elf_bytes.len) return error.UnresolvedReloc;
                        const addend_le = std.mem.readInt(u32, elf_bytes[file_off..][0..4], .little);
                        try list.append(arena, .{
                            .r_offset = va,
                            .r_addend = @as(u64, addend_le),
                        });
                    }
                } else if (shdr.sh_type == elf.SHT_RELA) {
                    const rela_off: usize = @intCast(shdr.sh_offset);
                    const rela_size: usize = @intCast(shdr.sh_size);
                    const ent_size: usize = @intCast(shdr.sh_entsize);
                    if (ent_size < @sizeOf(elf.Elf32_Rela)) continue;
                    var rp: usize = 0;
                    while (rp + ent_size <= rela_size) : (rp += ent_size) {
                        if (rela_off + rp + @sizeOf(elf.Elf32_Rela) > elf_bytes.len) break;
                        const rel = std.mem.bytesAsValue(
                            elf.Elf32_Rela,
                            elf_bytes[rela_off + rp ..][0..@sizeOf(elf.Elf32_Rela)],
                        ).*;
                        const r_type = rel.r_type();
                        if (r_type == 0) continue;
                        if (r_type != rel_type) return error.UnresolvedReloc;
                        try list.append(arena, .{
                            .r_offset = @as(u64, rel.r_offset),
                            .r_addend = @as(u64, @bitCast(@as(i64, rel.r_addend))),
                        });
                    }
                }
            }
        },
        else => return error.NotElf,
    }

    return list.toOwnedSlice(arena);
}
