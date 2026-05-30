const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const p9 = ferrite.p9;
const fs = ferrite.fs;

const URI_PREFIX = "com.midstall.ferrite.fatfs@v0";

const SECTOR_SIZE: u32 = 512;

const Bpb = struct {
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sectors: u16,
    num_fats: u8,
    root_entries: u16,
    total_sectors_16: u16,
    fat_size_16: u16,
    total_sectors_32: u32,
};

const DirEntry = extern struct {
    name: [11]u8,
    attr: u8,
    nt_res: u8,
    crt_time_tenth: u8,
    crt_time: u16,
    crt_date: u16,
    lst_acc_date: u16,
    fst_clus_hi: u16,
    wrt_time: u16,
    wrt_date: u16,
    fst_clus_lo: u16,
    file_size: u32,
};

comptime {
    if (@sizeOf(DirEntry) != 32) @compileError("DirEntry must be 32 bytes");
}

const ATTR_LONG_NAME: u8 = 0x0F;
const ATTR_DIRECTORY: u8 = 0x10;
const ATTR_VOLUME_ID: u8 = 0x08;

const Volume = struct {
    bpb: Bpb,
    fat_lba: u32,
    root_lba: u32,
    root_sectors: u32,
    data_lba: u32,
    cluster_bytes: u32,
};

var volume: Volume = undefined;
var backing: ferrite.fs.File = undefined;

// MAX = empty.
var sector_cache_lba: u32 = std.math.maxInt(u32);
var sector_cache: [SECTOR_SIZE]u8 = undefined;

fn readSectorCached(lba: u32, out: *[SECTOR_SIZE]u8) bool {
    if (sector_cache_lba == lba) {
        @memcpy(out, &sector_cache);
        return true;
    }
    if (!readSector(lba, out)) return false;
    sector_cache_lba = lba;
    @memcpy(&sector_cache, out);
    return true;
}

const MAX_FIDS = 32;

const FidKind = enum { root, file };

const Fid = struct {
    used: bool = false,
    opened: bool = false,
    kind: FidKind = .root,
    first_cluster: u32 = 0,
    size: u32 = 0,
    cached_cluster: u32 = 0,
    cached_off: u32 = 0,
};

const State = struct {
    fids: [MAX_FIDS]Fid = @splat(.{}),
};

var state: State = .{};

pub fn main() void {
    const argv = ferrite.argv;
    if (argv.len < 3) {
        ferrite.console.print("usage: mount.fat <backing-path> <mount-prefix>\n", .{}) catch {};
        return;
    }
    const backing_path = std.mem.span(argv[1]);
    const mount_prefix = std.mem.span(argv[2]);

    backing = openBackingWithRetry(backing_path) orelse {
        ferrite.console.print("[mount.fat] {s} never appeared. Exiting\n", .{backing_path}) catch {};
        return;
    };

    if (!loadBpb()) return;

    const ch = ferrite.channelCreate(0);
    if (ch < 0) return;
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);

    fs.register(URI_PREFIX, svc_send) catch |e| {
        ferrite.console.print("[mount.fat] register failed: {t}\n", .{e}) catch {};
        return;
    };

    fs.mount(mount_prefix, URI_PREFIX) catch |e| switch (e) {
        error.Permission => {},
        else => ferrite.console.print("[mount.fat] mount({s} -> " ++ URI_PREFIX ++ ") failed: {t}\n", .{ mount_prefix, e }) catch {},
    };

    state.fids[0] = .{ .used = true, .opened = true, .kind = .root };

    const handlers: fs.Handlers(State) = .{
        .on_walk = onWalk,
        .on_open = onOpen,
        .on_read = onRead,
        .on_write = onWrite,
        .on_close = onClose,
        .on_status = onStatus,
    };
    fs.serve(State, svc_recv, &state, &handlers);
}

fn openBackingWithRetry(path: []const u8) ?ferrite.fs.File {
    var uri_buf: [128]u8 = undefined;
    const uri = fs.resolvePath(path, &uri_buf) catch return null;
    var attempts: u32 = 0;
    while (attempts < 4) : (attempts += 1) {
        if (fs.open(uri, .{ .mode = .rdwr })) |f| return f else |_| {}
        var i: u32 = 0;
        while (i < 4) : (i += 1) ferrite.yield();
    }
    return null;
}

fn loadBpb() bool {
    var sector: [SECTOR_SIZE]u8 = undefined;
    if (!readSector(0, &sector)) {
        ferrite.console.print("[mount.fat] failed to read BPB\n", .{}) catch {};
        return false;
    }
    if (std.mem.readInt(u16, sector[510..512], .little) != 0xAA55) {
        ferrite.console.print("[mount.fat] no boot-sector signature\n", .{}) catch {};
        return false;
    }
    volume.bpb = .{
        .bytes_per_sector = std.mem.readInt(u16, sector[11..13], .little),
        .sectors_per_cluster = sector[13],
        .reserved_sectors = std.mem.readInt(u16, sector[14..16], .little),
        .num_fats = sector[16],
        .root_entries = std.mem.readInt(u16, sector[17..19], .little),
        .total_sectors_16 = std.mem.readInt(u16, sector[19..21], .little),
        .fat_size_16 = std.mem.readInt(u16, sector[22..24], .little),
        .total_sectors_32 = std.mem.readInt(u32, sector[32..36], .little),
    };
    if (volume.bpb.bytes_per_sector != SECTOR_SIZE) {
        ferrite.console.print("[mount.fat] unsupported sector size {d}\n", .{volume.bpb.bytes_per_sector}) catch {};
        return false;
    }
    if (volume.bpb.fat_size_16 == 0) {
        ferrite.console.print("[mount.fat] FAT32 not supported\n", .{}) catch {};
        return false;
    }

    volume.fat_lba = volume.bpb.reserved_sectors;
    volume.root_lba = volume.fat_lba + @as(u32, volume.bpb.num_fats) * volume.bpb.fat_size_16;
    volume.root_sectors = (@as(u32, volume.bpb.root_entries) * 32 + SECTOR_SIZE - 1) / SECTOR_SIZE;
    volume.data_lba = volume.root_lba + volume.root_sectors;
    volume.cluster_bytes = @as(u32, volume.bpb.sectors_per_cluster) * SECTOR_SIZE;
    return true;
}

fn readSector(lba: u32, out: *[SECTOR_SIZE]u8) bool {
    const offset = @as(u64, lba) * SECTOR_SIZE;
    var total: usize = 0;
    while (total < SECTOR_SIZE) {
        const n = backing.read(offset + total, out[total..]) catch return false;
        if (n == 0) return false;
        total += n;
    }
    return true;
}

// Clusters 0 and 1 reserved; user data starts at 2.
fn clusterLba(cluster: u32) u32 {
    return volume.data_lba + (cluster - 2) * volume.bpb.sectors_per_cluster;
}

fn clusterFor(fid: *Fid, byte_off: u32) ?u32 {
    var cluster: u32 = fid.cached_cluster;
    var skipped: u32 = fid.cached_off;
    if (byte_off < fid.cached_off or fid.cached_cluster == 0) {
        cluster = fid.first_cluster;
        skipped = 0;
    }
    while (skipped + volume.cluster_bytes <= byte_off) {
        const next = nextCluster(cluster) orelse return null;
        if (next >= 0xFFF8) return null;
        cluster = next;
        skipped += volume.cluster_bytes;
    }
    fid.cached_cluster = cluster;
    fid.cached_off = skipped;
    return cluster;
}

fn nextCluster(cluster: u32) ?u16 {
    const entry_off = cluster * 2;
    const sector_lba = volume.fat_lba + entry_off / SECTOR_SIZE;
    const sector_off = entry_off % SECTOR_SIZE;
    var sector: [SECTOR_SIZE]u8 = undefined;
    if (!readSector(sector_lba, &sector)) return null;
    return std.mem.readInt(u16, sector[sector_off..][0..2], .little);
}

fn formatName(entry: *const DirEntry, out: []u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < 8 and entry.name[i] != ' ') : (i += 1) {
        out[w] = entry.name[i];
        w += 1;
    }
    if (entry.name[8] != ' ') {
        out[w] = '.';
        w += 1;
        i = 8;
        while (i < 11 and entry.name[i] != ' ') : (i += 1) {
            out[w] = entry.name[i];
            w += 1;
        }
    }
    return w;
}

fn matchName(entry: *const DirEntry, name: []const u8) bool {
    var formatted: [13]u8 = undefined;
    const n = formatName(entry, &formatted);
    if (n != name.len) return false;
    for (formatted[0..n], name) |a, b| {
        if (std.ascii.toUpper(a) != std.ascii.toUpper(b)) return false;
    }
    return true;
}

fn onWalk(s: *State, fid: u32, path: []const u8) fs.HandlerError!fs.WalkResult {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    if (s.fids[fid].kind != .root) return error.NotFound;

    var iter = std.mem.tokenizeScalar(u8, path, '/');
    const first = iter.next();
    if (first == null) {
        return .{ .bound = try allocFid(s, .{ .used = true, .opened = false, .kind = .root }) };
    }
    if (iter.next() != null) return error.NotFound;

    var sector_idx: u32 = 0;
    while (sector_idx < volume.root_sectors) : (sector_idx += 1) {
        var sector: [SECTOR_SIZE]u8 = undefined;
        if (!readSector(volume.root_lba + sector_idx, &sector)) return error.BadOp;
        var off: usize = 0;
        while (off < SECTOR_SIZE) : (off += 32) {
            const entry: *const DirEntry = @ptrCast(@alignCast(&sector[off]));
            if (entry.name[0] == 0) return error.NotFound;
            if (entry.name[0] == 0xE5) continue;
            if (entry.attr & (ATTR_LONG_NAME | ATTR_VOLUME_ID) != 0) continue;
            if (matchName(entry, first.?)) {
                return .{ .bound = try allocFid(s, .{
                    .used = true,
                    .opened = false,
                    .kind = .file,
                    .first_cluster = entry.fst_clus_lo,
                    .size = entry.file_size,
                }) };
            }
        }
    }
    return error.NotFound;
}

fn allocFid(s: *State, fid: Fid) fs.HandlerError!u32 {
    var i: u32 = 1;
    while (i < MAX_FIDS) : (i += 1) {
        if (!s.fids[i].used) {
            s.fids[i] = fid;
            return i;
        }
    }
    return error.ServerBusy;
}

fn onOpen(s: *State, fid: u32, _: p9.Mode) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    s.fids[fid].opened = true;
}

fn onRead(s: *State, fid: u32, offset: u64, out: []u8) fs.HandlerError!usize {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    const f = &s.fids[fid];
    switch (f.kind) {
        .root => return readRootListing(offset, out),
        .file => return readFile(f, offset, out),
    }
}

fn readRootListing(offset: u64, out: []u8) fs.HandlerError!usize {
    var buf: [1024]u8 = undefined;
    var w: usize = 0;

    var sector_idx: u32 = 0;
    scan: while (sector_idx < volume.root_sectors) : (sector_idx += 1) {
        var sector: [SECTOR_SIZE]u8 = undefined;
        if (!readSector(volume.root_lba + sector_idx, &sector)) return error.BadOp;
        var off: usize = 0;
        while (off < SECTOR_SIZE) : (off += 32) {
            const entry: *const DirEntry = @ptrCast(@alignCast(&sector[off]));
            if (entry.name[0] == 0) break :scan;
            if (entry.name[0] == 0xE5) continue;
            if (entry.attr & (ATTR_LONG_NAME | ATTR_VOLUME_ID) != 0) continue;
            const n = formatName(entry, buf[w..]);
            w += n;
            if (w < buf.len) {
                buf[w] = '\n';
                w += 1;
            }
        }
    }

    if (offset >= w) return 0;
    const start: usize = @intCast(offset);
    const n = @min(w - start, out.len);
    @memcpy(out[0..n], buf[start..][0..n]);
    return n;
}

fn readFile(f: *Fid, offset: u64, out: []u8) fs.HandlerError!usize {
    if (offset >= f.size) return 0;
    const remaining = f.size - @as(u32, @intCast(offset));

    const cluster = clusterFor(f, @intCast(offset)) orelse return 0;
    const within = @as(u32, @intCast(offset)) - (@as(u32, @intCast(offset)) / volume.cluster_bytes) * volume.cluster_bytes;
    const cluster_remaining = volume.cluster_bytes - within;
    const want = @min(@min(@as(usize, remaining), out.len), cluster_remaining);
    const cluster_lba = clusterLba(cluster);

    var done: usize = 0;
    var byte_in_cluster: u32 = within;
    while (done < want) {
        const sec_off = byte_in_cluster / SECTOR_SIZE;
        const sec_within = byte_in_cluster % SECTOR_SIZE;
        var sector: [SECTOR_SIZE]u8 = undefined;
        if (!readSectorCached(cluster_lba + sec_off, &sector)) return error.BadOp;
        const sec_want = @min(SECTOR_SIZE - sec_within, want - done);
        @memcpy(out[done..][0..sec_want], sector[sec_within..][0..sec_want]);
        done += sec_want;
        byte_in_cluster += sec_want;
    }
    return done;
}

fn onWrite(_: *State, _: u32, _: u64, _: []const u8) fs.HandlerError!u32 {
    return error.BadOp;
}

fn onClose(s: *State, fid: u32) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    if (fid != 0) s.fids[fid] = .{};
}

fn onStatus(s: *State, fid: u32) fs.HandlerError!p9.StatusReply {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    const f = &s.fids[fid];
    return switch (f.kind) {
        .root => .{ .kind = .dir, .size = 0 },
        .file => .{ .kind = .file, .size = f.size },
    };
}
