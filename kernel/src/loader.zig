// Native Mach-O loader; statically-bound only.

const std = @import("std");
const arch = @import("arch");
const aspace = @import("aspace.zig");
const cap = @import("cap.zig");
const macho_mod = @import("macho.zig");
const memory = @import("memory.zig");
const process = @import("process.zig");
const sched = @import("sched.zig");
const signature = @import("signature.zig");
const std_macho = std.macho;

const DEFAULT_STACK_PAGES: u64 = 256;

pub const Error = error{
    OutOfMemory,
    BadImage,
    BadEntry,
    SigRejected,
    ArchUnsupported,
};

pub const Loaded = struct {
    proc: *process.Process,
    thread: *@import("thread.zig").Thread,
};

pub const LoadOpts = struct {
    /// If false, the child gets an empty namespace instead of a clone
    /// of the parent's. Manifest binds still apply.
    clone_namespace: bool = true,
};

pub fn load(
    bytes: []const u8,
    parent: *process.Process,
    /// argv slices only need to live for this call. Copied into the new
    /// process's user stack.
    argv: []const []const u8,
) Error!Loaded {
    return loadWith(bytes, parent, argv, .{});
}

pub fn loadWith(
    bytes: []const u8,
    parent: *process.Process,
    argv: []const []const u8,
    opts: LoadOpts,
) Error!Loaded {
    const slice = macho_mod.pickArch(bytes, macho_mod.nativeCpuType()) catch |e| return mapMachoError(e);

    const image = macho_mod.parseThin(slice) catch |e| return mapMachoError(e);

    signature.verify(image.bytes, image.sig_off, image.sig_size) catch |e| {
        arch.uart.print("[loader] signature rejected: {s}\n", .{@errorName(e)});
        return error.SigRejected;
    };

    // authority = parent intersect declared.
    const declared: process.Authority = @bitCast(image.authority_bits);
    const granted = parent.authority.intersect(declared);

    const proc = process.Process.create() catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.ArchUnsupported => error.ArchUnsupported,
        error.TableFull => error.OutOfMemory,
    };
    errdefer proc.destroy();
    proc.authority = granted;
    proc.uid = parent.uid;
    proc.pgid = parent.pgid; // inherit the parent's process group (POSIX); setpgid can move it
    if (argv.len > 0) proc.setName(basename(argv[0]));
    if (opts.clone_namespace) {
        proc.namespace = parent.namespace.clone() catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadImage,
        };
    }

    if (image.manifest_count != 0) {
        applyManifest(&image, parent, proc) catch |e| {
            arch.uart.print("[loader] manifest error: {s}\n", .{@errorName(e)});
            return error.BadImage;
        };
    }

    // PIE: slide so lowest non-empty vmaddr lands at USER_VA_BASE.
    var slide_ctx = SlideCtx{ .min_vmaddr = std.math.maxInt(u64) };
    if (image.pie) {
        macho_mod.forEachSegment(&image, &slide_ctx, SlideCtx.observe) catch |e| return mapMachoErrorErased(e);
    }
    const slide: u64 = if (image.pie and slide_ctx.min_vmaddr != std.math.maxInt(u64))
        aspace.USER_VA_BASE -% slide_ctx.min_vmaddr
    else
        0;

    var ctx = MapCtx{ .image = &image, .proc = proc, .slide = slide, .err = null };
    macho_mod.forEachSegment(&image, &ctx, MapCtx.mapOne) catch |e| {
        if (ctx.err) |held| return held;
        return mapMachoErrorErased(e);
    };
    if (ctx.err) |held| return held;

    // LC_FERRITE_REBASE: must run after segments are mapped, before stack setup.
    // Write a pointer-sized value so 32-bit targets (i386) don't smear 4 bytes
    // of zero into the next slot.
    for (image.rebases) |r| {
        const target_va = r.r_offset +% slide;
        const value: u64 = r.r_addend +% slide;
        if (target_va < aspace.USER_VA_BASE) return error.BadImage;
        if (@sizeOf(usize) == 8) {
            writeUser(proc, target_va, std.mem.asBytes(&value)) catch return error.BadImage;
        } else {
            const v32: u32 = @truncate(value);
            writeUser(proc, target_va, std.mem.asBytes(&v32)) catch return error.BadImage;
        }
    }

    const page_size = memory.pageSize();
    const stack_bytes = if (image.stack_size != 0)
        std.mem.alignForward(u64, image.stack_size, page_size)
    else
        DEFAULT_STACK_PAGES * page_size;

    const stack_top: u64 = aspace.USER_STACK_TOP;
    const stack_base: u64 = stack_top - stack_bytes;
    mapBlank(proc, stack_base, stack_bytes, .{ .read = true, .write = true, .user = true }) catch |e| return e;

    // SysV/Mach-O startup block: argc | argv | NULL | envp | NULL | apple | NULL | strings.
    const initial_sp = buildArgsBlock(proc, stack_top, argv) catch |e| return e;
    if (initial_sp < stack_base) return error.OutOfMemory;

    // LC_MAIN.entryoff is a file offset; resolve via containing segment's vmaddr-fileoff + slide.
    var entry_ctx = EntryCtx{ .entry_off = image.entry_off, .resolved = null };
    macho_mod.forEachSegment(&image, &entry_ctx, EntryCtx.observe) catch |e| return mapMachoErrorErased(e);
    const entry_pc = (entry_ctx.resolved orelse return error.BadEntry) +% slide;
    if (entry_pc < aspace.USER_VA_BASE) return error.BadEntry;
    const t = proc.spawnUser(entry_pc, initial_sp) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.ArchUnsupported => error.ArchUnsupported,
    };
    // NOTE: the thread is created but NOT scheduled. The caller must bind any
    // inherited state (e.g. stdio caps) and then `sched.add(loaded.thread)` so
    // the child can't start (possibly on another CPU) before that setup lands.
    return .{ .proc = proc, .thread = t };
}

// Segment mapping.

const MapCtx = struct {
    image: *const macho_mod.Image,
    proc: *process.Process,
    slide: u64,
    err: ?Error,

    fn mapOne(self: *MapCtx, seg: macho_mod.SegmentView) !void {
        if (seg.vmsize == 0) return;
        const vmaddr = seg.vmaddr +% self.slide;
        if (vmaddr < aspace.USER_VA_BASE) {
            self.err = error.BadImage;
            return error.BadImage;
        }
        const page_size = memory.pageSize();
        if ((vmaddr & (page_size - 1)) != 0) {
            self.err = error.BadImage;
            return error.BadImage;
        }

        const prot = protFromMaxProt(seg.maxprot);
        const vmsize = std.mem.alignForward(u64, seg.vmsize, page_size);
        mapImage(self.proc, vmaddr, vmsize, self.image.bytes, seg.fileoff, seg.filesize, prot) catch |e| {
            self.err = e;
            return e;
        };
    }
};

const SlideCtx = struct {
    min_vmaddr: u64,

    fn observe(self: *SlideCtx, seg: macho_mod.SegmentView) !void {
        if (seg.vmsize == 0) return;
        if (seg.vmaddr < self.min_vmaddr) self.min_vmaddr = seg.vmaddr;
    }
};

const EntryCtx = struct {
    entry_off: u64,
    resolved: ?u64,

    fn observe(self: *EntryCtx, seg: macho_mod.SegmentView) !void {
        if (self.resolved != null) return;
        const lo = seg.fileoff;
        const hi = seg.fileoff + seg.filesize;
        if (self.entry_off >= lo and self.entry_off < hi) {
            self.resolved = seg.vmaddr + (self.entry_off - seg.fileoff);
        }
    }
};

fn protFromMaxProt(mp: u32) aspace.Prot {
    return .{
        .read = (mp & 0x1) != 0,
        .write = (mp & 0x2) != 0,
        .execute = (mp & 0x4) != 0,
        .user = true,
    };
}

fn mapImage(
    proc: *process.Process,
    vmaddr: u64,
    vmsize: u64,
    file_bytes: []const u8,
    fileoff: u64,
    filesize: u64,
    prot: aspace.Prot,
) Error!void {
    const flags = arch.mmu.MapFlags{
        .read = prot.read,
        .write = prot.write,
        .execute = prot.execute,
        .user = true,
        .device = false,
    };
    const page_size = memory.pageSize();
    var off: u64 = 0;
    while (off < vmsize) : (off += page_size) {
        const pa = memory.allocPage() orelse return error.OutOfMemory;
        const page_va = memory.physToVirt(pa);
        const page_ptr: [*]u8 = @ptrFromInt(page_va);
        @memset(page_ptr[0..@intCast(page_size)], 0);
        if (off < filesize) {
            const file_lo: usize = @intCast(fileoff + off);
            const remaining_in_seg = filesize - off;
            const copy_len: usize = @intCast(@min(page_size, remaining_in_seg));
            const file_hi = file_lo + copy_len;
            if (file_hi > file_bytes.len) return error.BadImage;
            @memcpy(page_ptr[0..copy_len], file_bytes[file_lo..file_hi]);
        }
        arch.mmu.userTableMap(&proc.aspace.table, vmaddr + off, pa, flags) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return error.ArchUnsupported;
        };
    }
}

fn mapBlank(
    proc: *process.Process,
    vmaddr: u64,
    vmsize: u64,
    prot: aspace.Prot,
) Error!void {
    return mapImage(proc, vmaddr, vmsize, &.{}, 0, 0, prot);
}

// Stack-resident argv / envp / apple block (Mach-O / SysV process startup).

const MAX_ARGV: usize = 64;

/// Returns the new `sp` value, 16-byte aligned per the SysV requirement
/// aarch64 enforces.
fn buildArgsBlock(
    proc: *process.Process,
    stack_top: u64,
    argv: []const []const u8,
) Error!u64 {
    if (argv.len > MAX_ARGV) return error.OutOfMemory;
    const ptr_size: u64 = @sizeOf(usize);

    var str_bytes: u64 = 0;
    for (argv) |s| str_bytes += s.len + 1;

    // argc + argv ptrs + argv NULL + envp NULL + apple NULL.
    const array_bytes = ptr_size * (1 + @as(u64, argv.len) + 1 + 1 + 1);

    const str_lo_aligned: u64 = (stack_top - str_bytes) & ~(ptr_size - 1);
    const sp: u64 = (str_lo_aligned - array_bytes) & ~@as(u64, 0xF);

    var argv_vas: [MAX_ARGV]u64 = undefined;
    var str_va: u64 = stack_top - str_bytes;
    for (argv, 0..) |s, i| {
        argv_vas[i] = str_va;
        try writeUser(proc, str_va, s);
        try writeUser(proc, str_va + s.len, &.{0});
        str_va += s.len + 1;
    }

    var pos: u64 = sp;
    try writeUserPtr(proc, pos, @intCast(argv.len));
    pos += ptr_size;
    for (argv_vas[0..argv.len]) |v| {
        try writeUserPtr(proc, pos, v);
        pos += ptr_size;
    }
    try writeUserPtr(proc, pos, 0);
    pos += ptr_size;
    try writeUserPtr(proc, pos, 0);
    pos += ptr_size;
    try writeUserPtr(proc, pos, 0);

    return sp;
}

/// Reaches the backing physical pages via HHDM, so it doesn't depend on
/// the new aspace being active.
fn writeUser(proc: *process.Process, va: u64, bytes: []const u8) Error!void {
    const page_size = memory.pageSize();
    var off: u64 = 0;
    while (off < bytes.len) {
        const cur = va + off;
        const page_va = cur & ~(page_size - 1);
        const page_off = cur - page_va;
        const remaining = @as(u64, bytes.len) - off;
        const chunk = @min(remaining, page_size - page_off);
        const pa = arch.mmu.userTableTranslate(&proc.aspace.table, page_va) orelse
            return error.BadImage;
        const dst: [*]u8 = @ptrFromInt(memory.physToVirt(pa) + @as(usize, @intCast(page_off)));
        const lo: usize = @intCast(off);
        const hi: usize = @intCast(off + chunk);
        @memcpy(dst[0..@intCast(chunk)], bytes[lo..hi]);
        off += chunk;
    }
}

fn writeUserPtr(proc: *process.Process, va: u64, val: u64) Error!void {
    if (@sizeOf(usize) == 8) {
        const v: u64 = val;
        try writeUser(proc, va, std.mem.asBytes(&v));
    } else {
        const v: u32 = @intCast(val);
        try writeUser(proc, va, std.mem.asBytes(&v));
    }
}

// LC_FERRITE_AUTH manifest.

fn applyManifest(
    image: *const macho_mod.Image,
    parent: *process.Process,
    child: *process.Process,
) !void {
    var blob = image.manifest_blob;
    var i: u32 = 0;
    while (i < image.manifest_count) : (i += 1) {
        const hdr_size = @sizeOf(macho_mod.ManifestEntry);
        if (blob.len < hdr_size) return error.BadImage;
        const ent = std.mem.bytesAsValue(macho_mod.ManifestEntry, blob[0..hdr_size]).*;
        const path_len: usize = @intCast(ent.path_len);
        const path_end = hdr_size + path_len;
        if (blob.len < path_end) return error.BadImage;
        const path = blob[hdr_size..path_end];
        const padded = std.mem.alignForward(usize, path_end, 8);
        if (padded > blob.len) return error.BadImage;
        blob = blob[padded..];

        const parent_handle = parent.namespace.resolve(path) catch |e| {
            arch.uart.print("[loader] manifest miss ({s}): {s}\n", .{ @errorName(e), path });
            continue;
        };

        const want_kind: cap.Kind = @enumFromInt(@as(u8, @truncate(ent.kind)));
        const parent_ent = parent.cap_table.get(parent_handle, want_kind) catch |e| {
            arch.uart.print("[loader] manifest bad cap ({s}): {s}\n", .{ @errorName(e), path });
            continue;
        };

        const want_rights = std.mem.bytesAsValue(cap.Rights, std.mem.asBytes(&@as(u32, ent.rights))).*;
        const granted_rights = intersectRights(parent_ent.rights, want_rights);
        const new_handle = child.cap_table.mint(parent_ent.kind, granted_rights, parent_ent.object) catch return error.OutOfMemory;
        child.namespace.bind(path, new_handle) catch return error.BadImage;
    }
}

fn intersectRights(a: cap.Rights, b: cap.Rights) cap.Rights {
    const av: u32 = @bitCast(a);
    const bv: u32 = @bitCast(b);
    return @bitCast(av & bv);
}

// Error mapping.

fn mapMachoError(e: macho_mod.Error) Error {
    return switch (e) {
        error.NoMatchingSlice, error.Unsupported => error.ArchUnsupported,
        else => error.BadImage,
    };
}

fn mapMachoErrorErased(e: anyerror) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadImage,
    };
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}
