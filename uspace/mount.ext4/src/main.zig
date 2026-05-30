//! mount.ext4: an ext2/3/4 filesystem server over a block device.
//!
//! Reads the on-disk format directly from a backing device (e.g. /dev/vblk0
//! exposed by drv.virtio-blk) and serves it as a p9 filesystem. Supports the
//! common ext4 layout produced by `mke2fs -t ext4`: 64-bit group descriptors,
//! 256-byte inodes, extent-mapped files, and classic indirect block maps as a
//! fallback. The read path lands first; write support is layered on next.

const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const p9 = ferrite.p9;
const fs = ferrite.fs;

// On-disk constants (all little-endian).
const SB_OFFSET: u64 = 1024;
const SB_MAGIC: u16 = 0xEF53;
const EXT4_EXTENTS_FL: u32 = 0x80000;
const EXTENT_MAGIC: u16 = 0xF30A;
const ROOT_INO: u32 = 2;

const S_IFMT: u16 = 0xF000;
const S_IFDIR: u16 = 0x4000;
const S_IFREG: u16 = 0x8000;
const S_IFLNK: u16 = 0xA000;
const FAST_SYMLINK_MAX: usize = 59; // targets up to 59 bytes inline in i_block

const INCOMPAT_64BIT: u32 = 0x80;
const INCOMPAT_RECOVER: u32 = 0x4; // journal needs recovery
const INCOMPAT_CSUM_SEED: u32 = 0x2000; // s_checksum_seed is precomputed
const COMPAT_HAS_JOURNAL: u32 = 0x4;
const RO_COMPAT_METADATA_CSUM: u32 = 0x400;
const EXTRA_ISIZE: u16 = 32; // i_extra_isize we stamp on created inodes

const MAX_BLOCK: usize = 4096;

const Super = struct {
    block_size: u32,
    blocks_per_group: u32,
    inodes_per_group: u32,
    inode_size: u32,
    first_data_block: u32,
    desc_size: u32, // 32, or 64 with the 64bit feature
    is_64bit: bool,
    groups: u32,
    inodes_count: u32,
    metadata_csum: bool, // RO_COMPAT_METADATA_CSUM
    csum_seed: u32, // crc32c(~0, uuid) (or s_checksum_seed if INCOMPAT_CSUM_SEED)
    has_journal: bool, // COMPAT_HAS_JOURNAL
    journal_inum: u32, // s_journal_inum (usually 8)
    needs_recover: bool, // INCOMPAT_RECOVER (journal dirty)
};

var sb: Super = undefined;
var backing: fs.File = undefined;

// Single-threaded serve loop, so module-global scratch buffers are safe and
// keep handler stack frames small.
var blk_buf: [MAX_BLOCK]u8 = undefined;
var dir_buf: [MAX_BLOCK]u8 = undefined;
var idx_buf: [MAX_BLOCK]u8 = undefined;
var inode_buf: [256]u8 = undefined;
// Write-path scratch: wbuf holds the data/dir block being modified, bm_buf an
// allocation bitmap. Kept separate from the read-path buffers so a write op
// can hold a block while allocBlock touches descriptors/bitmaps.
var wbuf: [MAX_BLOCK]u8 = undefined;
var bm_buf: [MAX_BLOCK]u8 = undefined;
// Journal recovery scratch (mount-time only, before the serve loop starts).
var jbuf: [MAX_BLOCK]u8 = undefined;
var jinode: Inode = undefined;
var jbd_blocksize: u32 = 0;
var jbd_maxlen: u32 = 0;
var jbd_first: u32 = 0;
var jbd_start: u32 = 0;
var jbd_seq0: u32 = 0;
var jbd_incompat: u32 = 0;
var revoke_blk: [512]u64 = undefined;
var revoke_seq: [512]u32 = undefined;
var revoke_n: usize = 0;
var revoke_overflow: bool = false;

// Little-endian field readers.
inline fn rd16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
inline fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
inline fn lohi(lo: u32, hi: u32) u64 {
    return (@as(u64, hi) << 32) | lo;
}

// CRC32C (Castagnoli, reflected) matches the kernel's chainable __crc32c_le
// used by ext4/jbd2 metadata checksums: seed in, raw running value out (no
// final inversion), so callers thread the running crc through successive calls.
const crc32c_table = blk: {
    @setEvalBranchQuota(20000);
    var t: [256]u32 = undefined;
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        var c: u32 = i;
        var k: u32 = 0;
        while (k < 8) : (k += 1) {
            c = if (c & 1 != 0) (c >> 1) ^ 0x82F63B78 else c >> 1;
        }
        t[i] = c;
    }
    break :blk t;
};

fn crc32c(crc: u32, data: []const u8) u32 {
    var c = crc;
    for (data) |b| c = (c >> 8) ^ crc32c_table[(c ^ b) & 0xFF];
    return c;
}

inline fn crc32cU32(crc: u32, v: u32) u32 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    return crc32c(crc, &b);
}

// Big-endian readers for jbd2 (the journal is stored big-endian, unlike ext4).
inline fn rd32be(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

// Backing device reads.
fn readAt(offset: u64, out: []u8) bool {
    var total: usize = 0;
    while (total < out.len) {
        const n = backing.read(offset + total, out[total..]) catch return false;
        if (n == 0) return false;
        total += n;
    }
    return true;
}

fn readBlock(block: u64, out: []u8) bool {
    return readAt(block * sb.block_size, out[0..sb.block_size]);
}

fn loadSuper() bool {
    var raw: [1024]u8 = undefined;
    if (!readAt(SB_OFFSET, &raw)) {
        ferrite.console.print("[mount.ext4] failed to read superblock\n", .{}) catch {};
        return false;
    }
    if (rd16(&raw, 56) != SB_MAGIC) {
        ferrite.console.print("[mount.ext4] bad magic (not ext2/3/4)\n", .{}) catch {};
        return false;
    }
    const log_bs = rd32(&raw, 24);
    sb.block_size = @as(u32, 1024) << @intCast(log_bs);
    if (sb.block_size > MAX_BLOCK) {
        ferrite.console.print("[mount.ext4] block size {d} unsupported\n", .{sb.block_size}) catch {};
        return false;
    }
    sb.blocks_per_group = rd32(&raw, 32);
    sb.inodes_per_group = rd32(&raw, 40);
    sb.first_data_block = rd32(&raw, 20);

    const rev = rd32(&raw, 76);
    sb.inode_size = if (rev >= 1) rd16(&raw, 88) else 128;
    if (sb.inode_size == 0 or sb.inode_size > inode_buf.len) sb.inode_size = 128;

    const incompat = rd32(&raw, 96); // s_feature_incompat @ 0x60
    sb.is_64bit = (incompat & INCOMPAT_64BIT) != 0;
    sb.desc_size = if (sb.is_64bit) blk: {
        const d = rd16(&raw, 254);
        break :blk if (d >= 64) @as(u32, d) else 32;
    } else 32;

    sb.inodes_count = rd32(&raw, 0);
    sb.groups = (sb.inodes_count + sb.inodes_per_group - 1) / sb.inodes_per_group;

    const ro_compat = rd32(&raw, 100); // s_feature_ro_compat @ 0x64
    sb.metadata_csum = (ro_compat & RO_COMPAT_METADATA_CSUM) != 0;
    // Checksum seed: precomputed in s_checksum_seed (@0x270) when the csum_seed
    // feature is set, otherwise crc32c(~0, s_uuid[16] @0x68).
    sb.csum_seed = if ((incompat & INCOMPAT_CSUM_SEED) != 0)
        rd32(&raw, 0x270)
    else
        crc32c(0xFFFFFFFF, raw[0x68..][0..16]);

    const compat = rd32(&raw, 92); // s_feature_compat @ 0x5C
    sb.has_journal = (compat & COMPAT_HAS_JOURNAL) != 0;
    sb.journal_inum = rd32(&raw, 224); // s_journal_inum @ 0xE0
    sb.needs_recover = (incompat & INCOMPAT_RECOVER) != 0;

    if (sb.metadata_csum) {
        const stored = rd32(&raw, 1020); // s_checksum @ 0x3FC
        const calc = crc32c(0xFFFFFFFF, raw[0..1020]);
        if (stored != calc) {
            ferrite.console.print("[mount.ext4] superblock csum mismatch (stored=0x{x} calc=0x{x}); continuing\n", .{ stored, calc }) catch {};
        }
    }
    return true;
}

// Recompute + store the superblock checksum in a 1024-byte SB image (no-op
// unless metadata_csum). The sb csum uses init ~0, not the uuid seed.
fn sealSuper(raw: []u8) void {
    if (!sb.metadata_csum) return;
    const calc = crc32c(0xFFFFFFFF, raw[0..1020]);
    std.mem.writeInt(u32, raw[1020..][0..4], calc, .little);
}

// jbd2 journal: recover + coexist (Level A). We do NOT journal our own writes;
// instead we replay a dirty journal on mount (e.g. one a crashed Linux left
// behind), reset it, and otherwise keep it untouched so a clean shutdown stays
// consistent. The journal is stored BIG-endian (unlike ext4). Replay is
// fail-safe: on any uncertainty it bails without modifying the fs, leaving the
// journal for a real fsck rather than risking a half-applied recovery.
const JBD2_MAGIC: u32 = 0xC03B3998;
const JBD2_DESCRIPTOR: u32 = 1;
const JBD2_COMMIT: u32 = 2;
const JBD2_REVOKE: u32 = 5;
const JBD2_FLAG_ESCAPE: u32 = 1;
const JBD2_FLAG_SAME_UUID: u32 = 2;
const JBD2_FLAG_LAST_TAG: u32 = 8;
const JBD2_INCOMPAT_64BIT: u32 = 0x2;
const JBD2_INCOMPAT_ASYNC_COMMIT: u32 = 0x4;
const JBD2_INCOMPAT_CSUM_V2: u32 = 0x8;
const JBD2_INCOMPAT_CSUM_V3: u32 = 0x10;

inline fn rd16be(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .big);
}
inline fn rd64be(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .big);
}

fn readJournalBlock(logical: u64, out: []u8) bool {
    const phys = mapBlock(&jinode, logical) orelse return false;
    return readBlock(phys, out);
}

inline fn jbNext(pos: u32) u32 {
    const n = pos + 1;
    return if (n >= jbd_maxlen) jbd_first else n;
}

inline fn jbd64() bool {
    return (jbd_incompat & JBD2_INCOMPAT_64BIT) != 0;
}
inline fn jbdCsumV3() bool {
    return (jbd_incompat & JBD2_INCOMPAT_CSUM_V3) != 0;
}
inline fn jbdTagSize() usize {
    return if (jbdCsumV3()) 16 else @as(usize, 8) + (if (jbd64()) @as(usize, 4) else 0);
}
inline fn jbdTagFlags(off: usize) u32 {
    return if (jbdCsumV3()) rd32be(&jbuf, off + 4) else rd16be(&jbuf, off + 6);
}
inline fn jbdTagBlock(off: usize) u64 {
    const lo = rd32be(&jbuf, off);
    const hi: u32 = if (jbd64()) rd32be(&jbuf, off + 8) else 0;
    return lohi(lo, hi);
}

fn addRevoke(block: u64, seq: u32) void {
    if (revoke_n >= revoke_blk.len) {
        revoke_overflow = true;
        return;
    }
    revoke_blk[revoke_n] = block;
    revoke_seq[revoke_n] = seq;
    revoke_n += 1;
}

// A block is revoked for a transaction with sequence `txn` if any revoke record
// names it with a sequence >= txn (jbd2_journal_test_revoke semantics).
fn isRevoked(block: u64, txn: u32) bool {
    var i: usize = 0;
    while (i < revoke_n) : (i += 1) {
        if (revoke_blk[i] == block and revoke_seq[i] >= txn) return true;
    }
    return false;
}

fn collectRevokes(seq: u32) void {
    const count = rd32be(&jbuf, 12); // r_count: byte offset where records end
    const rsz: usize = if (jbd64()) 8 else 4;
    var off: usize = 16;
    while (off + rsz <= count and off + rsz <= jbd_blocksize) : (off += rsz) {
        const blk: u64 = if (jbd64()) rd64be(&jbuf, off) else rd32be(&jbuf, off);
        addRevoke(blk, seq);
    }
}

const JbdPass = enum { scan, revoke, replay };

// Walk the log from jbd_start/jbd_seq0. In .scan mode returns the sequence
// after the last committed transaction. In .revoke mode collects revoke
// records. In .replay mode copies committed data blocks to their targets
// (skipping revoked ones). Stops at the first block whose magic or sequence
// doesn't line up (the end of the valid log).
fn journalPass(pass: JbdPass, end_seq: u32) u32 {
    var pos = jbd_start;
    var seq = jbd_seq0;
    while (true) {
        if (pass != .scan and seq >= end_seq) break;
        if (!readJournalBlock(pos, &jbuf)) break;
        if (rd32be(&jbuf, 0) != JBD2_MAGIC) break;
        const btype = rd32be(&jbuf, 4);
        if (rd32be(&jbuf, 8) != seq) break;
        switch (btype) {
            JBD2_DESCRIPTOR => {
                pos = jbNext(pos); // first data block follows the descriptor
                var off: usize = 12;
                while (off + jbdTagSize() <= jbd_blocksize) {
                    const flags = jbdTagFlags(off);
                    const target = jbdTagBlock(off);
                    if (pass == .replay and !isRevoked(target, seq)) {
                        if (readJournalBlock(pos, &wbuf)) {
                            if ((flags & JBD2_FLAG_ESCAPE) != 0)
                                std.mem.writeInt(u32, wbuf[0..4], JBD2_MAGIC, .big);
                            _ = writeBlock(target, &wbuf);
                        }
                    }
                    pos = jbNext(pos);
                    off += jbdTagSize();
                    if ((flags & JBD2_FLAG_SAME_UUID) == 0) off += 16; // inline uuid
                    if ((flags & JBD2_FLAG_LAST_TAG) != 0) break;
                }
            },
            JBD2_REVOKE => {
                if (pass == .revoke) collectRevokes(seq);
                pos = jbNext(pos);
            },
            JBD2_COMMIT => {
                pos = jbNext(pos);
                seq += 1; // this transaction is now complete
            },
            else => break,
        }
    }
    return seq;
}

// Recompute + store the jbd2 journal-superblock checksum (csum_v2/v3) in jbuf,
// then write jbuf back to journal logical block 0. The journal sb csum covers
// the first 1024 bytes with s_checksum (@0xFC) zeroed, seed ~0, big-endian.
fn writeJournalSb() void {
    if ((jbd_incompat & (JBD2_INCOMPAT_CSUM_V2 | JBD2_INCOMPAT_CSUM_V3)) != 0) {
        std.mem.writeInt(u32, jbuf[0xFC..][0..4], 0, .big);
        const calc = crc32c(0xFFFFFFFF, jbuf[0..1024]);
        std.mem.writeInt(u32, jbuf[0xFC..][0..4], calc, .big);
    }
    const phys = mapBlock(&jinode, 0) orelse return;
    _ = writeBlock(phys, &jbuf);
}

// Clear INCOMPAT_RECOVER in the fs superblock (resealing its csum).
fn clearRecoverFlag() void {
    var raw: [1024]u8 = undefined;
    if (!readAt(SB_OFFSET, &raw)) return;
    const incompat = rd32(&raw, 96);
    std.mem.writeInt(u32, raw[96..][0..4], incompat & ~INCOMPAT_RECOVER, .little);
    sealSuper(&raw);
    _ = writeAt(SB_OFFSET, &raw);
    sb.needs_recover = false;
}

// Mount-time journal handling. Returns false only on a hard error that should
// abort the mount; a clean or successfully-recovered journal returns true.
fn journalRecover() bool {
    if (!sb.has_journal) return true;
    if (!readInode(sb.journal_inum, &jinode)) {
        ferrite.console.print("[mount.ext4] journal inode {d} unreadable\n", .{sb.journal_inum}) catch {};
        return true; // tolerate; treat as no journal
    }
    if (!readJournalBlock(0, &jbuf)) return true;
    if (rd32be(&jbuf, 0) != JBD2_MAGIC) {
        ferrite.console.print("[mount.ext4] journal has no jbd2 magic; ignoring\n", .{}) catch {};
        return true;
    }
    jbd_blocksize = rd32be(&jbuf, 12);
    jbd_maxlen = rd32be(&jbuf, 16);
    jbd_first = rd32be(&jbuf, 20);
    jbd_seq0 = rd32be(&jbuf, 24);
    jbd_start = rd32be(&jbuf, 28);
    jbd_incompat = rd32be(&jbuf, 40);

    if (jbd_start == 0) {
        // Clean journal: nothing to replay. Drop a stale recover flag if present.
        if (sb.needs_recover) clearRecoverFlag();
        return true;
    }

    // Dirty journal: bail safely on shapes we can't faithfully replay.
    if (jbd_blocksize != sb.block_size or (jbd_incompat & JBD2_INCOMPAT_ASYNC_COMMIT) != 0) {
        ferrite.console.print("[mount.ext4] dirty journal needs full jbd2 (async/blocksize); NOT mounting clean. Run fsck.\n", .{}) catch {};
        return true;
    }

    revoke_n = 0;
    revoke_overflow = false;
    const end_seq = journalPass(.scan, 0);
    _ = journalPass(.revoke, end_seq);
    if (revoke_overflow) {
        ferrite.console.print("[mount.ext4] journal revoke table overflow; skipping replay. Run fsck.\n", .{}) catch {};
        return true;
    }
    _ = journalPass(.replay, end_seq);

    // Recovery applied: mark the journal empty and clear the fs recover flag.
    // The passes above reused jbuf for log blocks, so re-read the journal sb
    // before editing it (else we'd write a stale log block as the superblock).
    if (!readJournalBlock(0, &jbuf)) return true;
    std.mem.writeInt(u32, jbuf[24..][0..4], end_seq, .big); // s_sequence
    std.mem.writeInt(u32, jbuf[28..][0..4], 0, .big); // s_start = 0 (empty)
    writeJournalSb();
    clearRecoverFlag();
    ferrite.console.print("[mount.ext4] journal recovered ({d} txns replayed to seq {d})\n", .{ end_seq - jbd_seq0, end_seq }) catch {};
    return true;
}

// Block group descriptor table starts at the block after the superblock.
fn groupDescTableBlock() u64 {
    return sb.first_data_block + 1;
}

// Returns the inode-table starting block for a group.
fn inodeTableBlock(group: u32) ?u64 {
    const per_block = sb.block_size / sb.desc_size;
    const desc_block = groupDescTableBlock() + group / per_block;
    const within = (group % per_block) * sb.desc_size;
    if (!readBlock(desc_block, &blk_buf)) return null;
    const lo = rd32(&blk_buf, within + 8);
    const hi: u32 = if (sb.desc_size >= 64) rd32(&blk_buf, within + 0x28) else 0;
    return lohi(lo, hi);
}

const Inode = struct {
    mode: u16,
    size: u64,
    flags: u32,
    // raw i_block area (60 bytes): extent tree root or classic block map.
    iblock: [60]u8,

    fn isDir(self: *const Inode) bool {
        return (self.mode & S_IFMT) == S_IFDIR;
    }
};

fn readInode(ino: u32, out: *Inode) bool {
    if (ino == 0) return false;
    const group = (ino - 1) / sb.inodes_per_group;
    const index = (ino - 1) % sb.inodes_per_group;
    const table = inodeTableBlock(group) orelse return false;
    const byte = @as(u64, index) * sb.inode_size;
    const block = table + byte / sb.block_size;
    const within: usize = @intCast(byte % sb.block_size);
    if (!readBlock(block, &blk_buf)) return false;
    if (within + sb.inode_size > sb.block_size) return false;
    const raw = blk_buf[within..][0..sb.inode_size];

    out.mode = rd16(raw, 0);
    out.flags = rd32(raw, 32);
    const size_lo = rd32(raw, 4);
    // For regular files i_size_high lives at 108; dirs keep size in lo.
    const size_hi: u32 = if ((out.mode & S_IFMT) == S_IFREG) rd32(raw, 108) else 0;
    out.size = lohi(size_lo, size_hi);
    @memcpy(&out.iblock, raw[40..100]);
    return true;
}

// Map a logical file block to a physical block, via extents or classic maps.
fn mapBlock(inode: *const Inode, logical: u64) ?u64 {
    if ((inode.flags & EXT4_EXTENTS_FL) != 0) {
        return extentLookup(&inode.iblock, logical);
    }
    return classicLookup(inode, logical);
}

// Walk an extent tree node (the 60-byte inode root or a full-block node).
fn extentLookup(node: []const u8, logical: u64) ?u64 {
    if (rd16(node, 0) != EXTENT_MAGIC) return null;
    const entries = rd16(node, 2);
    const depth = rd16(node, 6);
    var i: usize = 0;
    if (depth == 0) {
        while (i < entries) : (i += 1) {
            const e = node[12 + i * 12 ..];
            const ee_block = rd32(e, 0);
            var ee_len = rd16(e, 4);
            if (ee_len > 32768) ee_len -= 32768; // uninitialized extent
            if (logical >= ee_block and logical < @as(u64, ee_block) + ee_len) {
                const start = lohi(rd32(e, 8), rd16(e, 6));
                return start + (logical - ee_block);
            }
        }
        return null;
    }
    // Index node: pick the last child whose ei_block <= logical.
    var chosen: ?u64 = null;
    i = 0;
    while (i < entries) : (i += 1) {
        const e = node[12 + i * 12 ..];
        const ei_block = rd32(e, 0);
        if (ei_block <= logical) {
            chosen = lohi(rd32(e, 4), rd16(e, 8));
        } else break;
    }
    const child = chosen orelse return null;
    if (!readBlock(child, &idx_buf)) return null;
    return extentLookup(idx_buf[0..sb.block_size], logical);
}

fn classicLookup(inode: *const Inode, logical: u64) ?u64 {
    const ppb: u64 = sb.block_size / 4; // pointers per indirect block
    if (logical < 12) {
        const b = rd32(&inode.iblock, @intCast(logical * 4));
        return if (b == 0) null else b;
    }
    var l = logical - 12;
    if (l < ppb) {
        const single = rd32(&inode.iblock, 12 * 4);
        return indirectEntry(single, l);
    }
    l -= ppb;
    if (l < ppb * ppb) {
        const double = rd32(&inode.iblock, 13 * 4);
        const mid = indirectEntry(double, l / ppb) orelse return null;
        return indirectEntry(@intCast(mid), l % ppb);
    }
    return null; // triple-indirect unsupported (files this large are unexpected)
}

fn indirectEntry(block: u32, index: u64) ?u64 {
    if (block == 0) return null;
    if (!readBlock(block, &idx_buf)) return null;
    const b = rd32(idx_buf[0..sb.block_size], @intCast(index * 4));
    return if (b == 0) null else b;
}

// Read up to out.len bytes of an inode's data starting at byte `offset`.
fn readInodeData(inode: *const Inode, offset: u64, out: []u8) ?usize {
    if (offset >= inode.size) return 0;
    const remaining = inode.size - offset;
    const want = @min(@as(u64, out.len), remaining);
    var done: usize = 0;
    while (done < want) {
        const pos = offset + done;
        const logical = pos / sb.block_size;
        const within: usize = @intCast(pos % sb.block_size);
        const chunk = @min(@as(u64, sb.block_size - within), want - done);
        const phys = mapBlock(inode, logical);
        if (phys) |pb| {
            if (!readBlock(pb, &blk_buf)) return null;
            @memcpy(out[done..][0..@intCast(chunk)], blk_buf[within..][0..@intCast(chunk)]);
        } else {
            // Hole: reads as zeros.
            @memset(out[done..][0..@intCast(chunk)], 0);
        }
        done += @intCast(chunk);
    }
    return done;
}

const Entry = struct { ino: u32, is_dir: bool };

// Find `name` in directory `dir`. Scans linear ext4_dir_entry_2 records; works
// even when an htree index is present (the leaf blocks are linearly walkable).
fn dirLookup(dir: *const Inode, name: []const u8) ?Entry {
    const nblocks = (dir.size + sb.block_size - 1) / sb.block_size;
    var b: u64 = 0;
    while (b < nblocks) : (b += 1) {
        const phys = mapBlock(dir, b) orelse continue;
        if (!readBlock(phys, &dir_buf)) return null;
        var off: usize = 0;
        while (off + 8 <= sb.block_size) {
            const ino = rd32(&dir_buf, off);
            const rec_len = rd16(&dir_buf, off + 4);
            if (rec_len < 8) break;
            const name_len = dir_buf[off + 6];
            if (ino != 0 and name_len == name.len) {
                const ent_name = dir_buf[off + 8 ..][0..name_len];
                if (std.mem.eql(u8, ent_name, name)) {
                    const ftype = dir_buf[off + 7];
                    return .{ .ino = ino, .is_dir = ftype == 2 };
                }
            }
            off += rec_len;
        }
    }
    return null;
}

// Write a newline-separated listing of a directory's names into `out`,
// honoring `offset` for paged reads. Skips "." and "..".
fn dirListing(dir: *const Inode, offset: u64, out: []u8) ?usize {
    var line: [256]u8 = undefined;
    var produced: u64 = 0; // logical bytes emitted across the whole listing
    var written: usize = 0;
    const nblocks = (dir.size + sb.block_size - 1) / sb.block_size;
    var b: u64 = 0;
    while (b < nblocks) : (b += 1) {
        const phys = mapBlock(dir, b) orelse continue;
        if (!readBlock(phys, &dir_buf)) return null;
        var off: usize = 0;
        while (off + 8 <= sb.block_size) {
            const ino = rd32(&dir_buf, off);
            const rec_len = rd16(&dir_buf, off + 4);
            if (rec_len < 8) break;
            const name_len = dir_buf[off + 6];
            off += rec_len;
            if (ino == 0 or name_len == 0) continue;
            const ent = dir_buf[off - rec_len + 8 ..][0..name_len];
            if (std.mem.eql(u8, ent, ".") or std.mem.eql(u8, ent, "..")) continue;
            if (name_len + 1 > line.len) continue;
            @memcpy(line[0..name_len], ent);
            line[name_len] = '\n';
            const chunk = line[0 .. name_len + 1];
            // Emit only the portion past `offset`.
            for (chunk) |c| {
                if (produced >= offset and written < out.len) {
                    out[written] = c;
                    written += 1;
                }
                produced += 1;
            }
        }
    }
    return written;
}

// Resolve a '/'-separated path relative to a starting inode, following any
// symlinks encountered (Unix open semantics). Depth-limited against loops.
fn walk(start_ino: u32, path: []const u8) ?Entry {
    return walkDepth(start_ino, path, 0);
}

fn walkDepth(start_ino: u32, path: []const u8, depth: u32) ?Entry {
    if (depth > 8) return null; // symlink loop / too deep
    var cur: Entry = .{ .ino = start_ino, .is_dir = true };
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (!cur.is_dir) return null;
        var dir: Inode = undefined;
        if (!readInode(cur.ino, &dir)) return null;
        const e = dirLookup(&dir, comp) orelse return null;
        const parent_ino = cur.ino;
        cur = e;
        if (isSymlink(cur.ino)) {
            cur = followLink(cur.ino, parent_ino, depth) orelse return null;
        }
    }
    return cur;
}

fn isSymlink(ino: u32) bool {
    var inode: Inode = undefined;
    if (!readInode(ino, &inode)) return false;
    return (inode.mode & S_IFMT) == S_IFLNK;
}

// Read a symlink's target into `out`. Fast symlinks (size < 60) store it inline
// in the inode's i_block; slow ones in the first data block.
fn readLinkTarget(ino: u32, out: []u8) ?[]const u8 {
    var inode: Inode = undefined;
    if (!readInode(ino, &inode)) return null;
    if ((inode.mode & S_IFMT) != S_IFLNK) return null;
    const len: usize = @intCast(@min(inode.size, @as(u64, out.len)));
    if (inode.size <= FAST_SYMLINK_MAX) {
        @memcpy(out[0..len], inode.iblock[0..len]);
        return out[0..len];
    }
    const phys = mapBlock(&inode, 0) orelse return null;
    if (!readBlock(phys, &blk_buf)) return null;
    @memcpy(out[0..len], blk_buf[0..len]);
    return out[0..len];
}

// Resolve a symlink: absolute targets restart at the fs root, relative ones at
// the directory holding the link.
fn followLink(link_ino: u32, parent_dir_ino: u32, depth: u32) ?Entry {
    var tbuf: [256]u8 = undefined;
    const target = readLinkTarget(link_ino, &tbuf) orelse return null;
    if (target.len == 0) return null;
    const base = if (target[0] == '/') ROOT_INO else parent_dir_ino;
    return walkDepth(base, target, depth + 1);
}

const MAX_FIDS = 64;

const Fid = struct {
    used: bool = false,
    opened: bool = false,
    ino: u32 = 0,
    is_dir: bool = false,
    size: u64 = 0,
};

const State = struct {
    fids: [MAX_FIDS]Fid = @splat(.{}),
};

var state: State = .{};

pub fn main() void {
    const argv = ferrite.argv;
    if (argv.len < 4) {
        ferrite.console.print("usage: mount.ext4 <backing-path> <authority> <mount-prefix>\n", .{}) catch {};
        return;
    }
    const backing_path = std.mem.span(argv[1]);
    const authority = std.mem.span(argv[2]);
    const mount_prefix = std.mem.span(argv[3]);

    backing = openBackingWithRetry(backing_path) orelse {
        ferrite.console.print("[mount.ext4] {s} never appeared. Exiting\n", .{backing_path}) catch {};
        return;
    };

    if (!loadSuper()) return;
    _ = journalRecover();

    const ch = ferrite.channelCreate(0);
    if (ch < 0) return;
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);

    fs.register(authority, svc_send) catch |e| {
        ferrite.console.print("[mount.ext4] register failed: {t}\n", .{e}) catch {};
        return;
    };
    fs.mount(mount_prefix, authority) catch |e| switch (e) {
        error.Permission => {},
        else => ferrite.console.print("[mount.ext4] mount failed: {t}\n", .{e}) catch {},
    };

    // fid 0 = the filesystem root.
    var root: Inode = undefined;
    if (!readInode(ROOT_INO, &root)) {
        ferrite.console.print("[mount.ext4] cannot read root inode\n", .{}) catch {};
        return;
    }
    state.fids[0] = .{ .used = true, .opened = true, .ino = ROOT_INO, .is_dir = true, .size = root.size };
    ferrite.console.print("[mount.ext4] mounted {s} (bs={d} {s}{s}{s})\n", .{
        mount_prefix,
        sb.block_size,
        if (sb.is_64bit) "64bit" else "32bit",
        if (sb.metadata_csum) " csum" else "",
        if (sb.has_journal) " journal" else "",
    }) catch {};

    const handlers: fs.Handlers(State) = .{
        .on_walk = onWalk,
        .on_open = onOpen,
        .on_read = onRead,
        .on_write = onWrite,
        .on_close = onClose,
        .on_status = onStatus,
        .on_create = onCreate,
        .on_remove = onRemove,
        .on_symlink = onSymlink,
        .on_readlink = onReadlink,
    };
    fs.serve(State, svc_recv, &state, &handlers);
}

fn openBackingWithRetry(path: []const u8) ?fs.File {
    // The block driver may still be probing PCI when we start, so wait
    // generously for the root device to appear (this is the rootfs mount).
    var attempts: u32 = 0;
    while (attempts < 250) : (attempts += 1) {
        var uri_buf: [128]u8 = undefined;
        if (fs.resolvePath(path, &uri_buf)) |uri| {
            if (fs.open(uri, .{ .mode = .rdwr })) |f| return f else |_| {}
        } else |_| {}
        var i: u32 = 0;
        while (i < 8) : (i += 1) ferrite.yield();
    }
    return null;
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

fn onWalk(s: *State, fid: u32, path: []const u8) fs.HandlerError!fs.WalkResult {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    if (!s.fids[fid].is_dir) return error.NotFound;

    const r = walk(s.fids[fid].ino, path) orelse return error.NotFound;
    var size: u64 = 0;
    if (!r.is_dir) {
        var inode: Inode = undefined;
        if (!readInode(r.ino, &inode)) return error.BadOp;
        size = inode.size;
    }
    return .{ .bound = try allocFid(s, .{
        .used = true,
        .opened = false,
        .ino = r.ino,
        .is_dir = r.is_dir,
        .size = size,
    }) };
}

fn onOpen(s: *State, fid: u32, _: p9.Mode) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    s.fids[fid].opened = true;
}

fn onRead(s: *State, fid: u32, offset: u64, out: []u8) fs.HandlerError!usize {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    const f = &s.fids[fid];
    var inode: Inode = undefined;
    if (!readInode(f.ino, &inode)) return error.BadOp;
    if (f.is_dir) {
        return dirListing(&inode, offset, out) orelse error.BadOp;
    }
    return readInodeData(&inode, offset, out) orelse error.BadOp;
}

fn onWrite(s: *State, fid: u32, offset: u64, data: []const u8) fs.HandlerError!u32 {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    const f = &s.fids[fid];
    if (f.is_dir) return error.BadOp;
    const n = writeInodeData(f.ino, offset, data) orelse return error.BadOp;
    if (offset + n > f.size) f.size = offset + n;
    return @intCast(n);
}

fn onCreate(_: *State, kind: p9.Kind, path: []const u8) fs.HandlerError!void {
    const sp = splitPath(path);
    if (sp.name.len == 0 or sp.name.len > 255) return error.BadOp;

    const pe = walk(ROOT_INO, sp.parent) orelse return error.NotFound;
    if (!pe.is_dir) return error.NotFound;
    var pdir: Inode = undefined;
    if (!readInode(pe.ino, &pdir)) return error.BadOp;
    if (dirLookup(&pdir, sp.name) != null) {
        if (kind == .dir) return error.BadOp; // mkdir of an existing name = EEXIST
        return; // touch of an existing file is a no-op
    }
    switch (kind) {
        .file => try createFile(pe.ino, sp.name),
        .dir => try createDir(pe.ino, sp.name),
    }
}

fn createFile(parent_ino: u32, name: []const u8) fs.HandlerError!void {
    const nino = allocInode(false) orelse return error.BadOp;
    @memset(inode_buf[0..sb.inode_size], 0);
    std.mem.writeInt(u16, inode_buf[0..2], 0x81A4, .little); // S_IFREG | 0644
    std.mem.writeInt(u16, inode_buf[26..][0..2], 1, .little); // i_links_count
    std.mem.writeInt(u32, inode_buf[32..][0..4], EXT4_EXTENTS_FL, .little);
    std.mem.writeInt(u16, inode_buf[40..][0..2], EXTENT_MAGIC, .little);
    std.mem.writeInt(u16, inode_buf[44..][0..2], 4, .little); // eh_max
    stampExtraIsize();
    if (!writeInodeRaw(nino)) return error.BadOp;
    if (!addDirEntry(parent_ino, name, nino, 1)) return error.BadOp;
}

// mkdir: allocate the inode + one data block holding "." and "..", link it into
// the parent, and bump the parent's link count (the new dir's ".." adds a ref).
fn createDir(parent_ino: u32, name: []const u8) fs.HandlerError!void {
    const nino = allocInode(true) orelse return error.BadOp;
    const dblock = allocBlock() orelse return error.BadOp;

    @memset(wbuf[0..sb.block_size], 0);
    std.mem.writeInt(u32, wbuf[0..4], nino, .little); // "." -> self
    std.mem.writeInt(u16, wbuf[4..6], 12, .little);
    wbuf[6] = 1;
    wbuf[7] = 2; // dir
    wbuf[8] = '.';
    std.mem.writeInt(u32, wbuf[12..16], parent_ino, .little); // ".." -> parent
    std.mem.writeInt(u16, wbuf[16..18], @intCast(dirDataLen() - 12), .little); // ".." spans up to the tail
    wbuf[18] = 2;
    wbuf[19] = 2; // dir
    wbuf[20] = '.';
    wbuf[21] = '.';
    if (!writeDirBlock(nino, 0, dblock)) return error.BadOp; // new dir: i_generation = 0

    @memset(inode_buf[0..sb.inode_size], 0);
    std.mem.writeInt(u16, inode_buf[0..2], 0x41ED, .little); // S_IFDIR | 0755
    std.mem.writeInt(u16, inode_buf[26..][0..2], 2, .little); // "." + parent's entry
    std.mem.writeInt(u32, inode_buf[32..][0..4], EXT4_EXTENTS_FL, .little);
    if (!appendExtent(0, dblock)) return error.BadOp;
    std.mem.writeInt(u32, inode_buf[4..][0..4], @intCast(sb.block_size), .little); // i_size
    incIBlocks(1);
    stampExtraIsize();
    if (!writeInodeRaw(nino)) return error.BadOp;

    if (!addDirEntry(parent_ino, name, nino, 2)) return error.BadOp;
    bumpLinks(parent_ino, 1);
}

// Create a symbolic link. Fast symlinks only (target inline in i_block, <=59
// bytes), which covers the common case.
fn onSymlink(_: *State, path: []const u8, target: []const u8) fs.HandlerError!void {
    if (target.len == 0 or target.len > FAST_SYMLINK_MAX) return error.BadOp;
    const sp = splitPath(path);
    if (sp.name.len == 0 or sp.name.len > 255) return error.BadOp;
    const pe = walk(ROOT_INO, sp.parent) orelse return error.NotFound;
    if (!pe.is_dir) return error.NotFound;
    var pdir: Inode = undefined;
    if (!readInode(pe.ino, &pdir)) return error.BadOp;
    if (dirLookup(&pdir, sp.name) != null) return error.BadOp; // EEXIST

    const nino = allocInode(false) orelse return error.BadOp;
    @memset(inode_buf[0..sb.inode_size], 0);
    std.mem.writeInt(u16, inode_buf[0..2], 0xA1FF, .little); // S_IFLNK | 0777
    std.mem.writeInt(u32, inode_buf[4..][0..4], @intCast(target.len), .little); // i_size
    std.mem.writeInt(u16, inode_buf[26..][0..2], 1, .little); // i_links_count
    @memcpy(inode_buf[40..][0..target.len], target); // inline target (fast symlink)
    stampExtraIsize();
    if (!writeInodeRaw(nino)) return error.BadOp;
    if (!addDirEntry(pe.ino, sp.name, nino, 7)) return error.BadOp; // ftype 7 = symlink
}

// Read a symlink's target WITHOUT following it (the link's last component is
// looked up directly). EINVAL-ish (BadOp) if the path isn't a symlink.
fn onReadlink(_: *State, path: []const u8, out: []u8) fs.HandlerError!usize {
    const sp = splitPath(path);
    if (sp.name.len == 0) return error.BadOp;
    const pe = walk(ROOT_INO, sp.parent) orelse return error.NotFound;
    if (!pe.is_dir) return error.NotFound;
    var pdir: Inode = undefined;
    if (!readInode(pe.ino, &pdir)) return error.BadOp;
    const target = dirLookup(&pdir, sp.name) orelse return error.NotFound;
    const t = readLinkTarget(target.ino, out) orelse return error.BadOp; // not a symlink
    return t.len;
}

fn bumpLinks(ino: u32, delta: i16) void {
    _ = readInodeRaw(ino) orelse return;
    const cur = rd16(&inode_buf, 26);
    const nv: u16 = @intCast(@as(i32, cur) + delta);
    std.mem.writeInt(u16, inode_buf[26..][0..2], nv, .little);
    _ = writeInodeRaw(ino);
}

// Unlink an entry, reclaiming the inode + its blocks when the last link goes.
// Empty directories are removed (rmdir); non-empty ones are refused.
fn onRemove(_: *State, path: []const u8) fs.HandlerError!void {
    const sp = splitPath(path);
    if (sp.name.len == 0) return error.BadOp;
    const pe = walk(ROOT_INO, sp.parent) orelse return error.NotFound;
    if (!pe.is_dir) return error.NotFound;
    var pdir: Inode = undefined;
    if (!readInode(pe.ino, &pdir)) return error.BadOp;
    const target = dirLookup(&pdir, sp.name) orelse return error.NotFound;
    var tinode: Inode = undefined;
    if (!readInode(target.ino, &tinode)) return error.BadOp;
    const is_dir = (tinode.mode & S_IFMT) == S_IFDIR;
    if (is_dir and !dirIsEmpty(&tinode)) return error.BadOp; // ENOTEMPTY

    if (!removeDirEntry(pe.ino, &pdir, sp.name)) return error.NotFound;

    if (is_dir) {
        freeInodeBlocks(&tinode);
        clearInode(target.ino);
        freeInode(target.ino, true);
        bumpLinks(pe.ino, -1); // the gone dir's ".." no longer references the parent
        return;
    }
    // File or symlink: drop a link; reclaim when it hits zero.
    _ = readInodeRaw(target.ino) orelse return;
    const links = rd16(&inode_buf, 26);
    if (links > 1) {
        std.mem.writeInt(u16, inode_buf[26..][0..2], links - 1, .little);
        _ = writeInodeRaw(target.ino);
    } else {
        freeInodeBlocks(&tinode); // no-op for fast symlinks (no extent flag / no blocks)
        clearInode(target.ino);
        freeInode(target.ino, false);
    }
}

// A plausible deletion timestamp for freed inodes. i_dtime must be nonzero (so
// fsck sees the inode as deleted) AND larger than s_inodes_count: ext4's orphan
// list reuses i_dtime as a "next orphan inode" pointer, so a small value with
// links_count==0 is read as a corrupted orphan-list link. 2023-11-14 UTC.
const DELETE_TIME: u32 = 1_700_000_000;

// Mark an inode deleted in the inode table. fsck reconstructs "in use" from the
// table (links_count>0 && dtime==0), not the bitmap, so a freed inode must have
// links_count=0 and a nonzero dtime or fsck resurrects it as an unattached inode.
fn clearInode(ino: u32) void {
    _ = readInodeRaw(ino) orelse return;
    std.mem.writeInt(u32, inode_buf[4..][0..4], 0, .little); // i_size_lo
    std.mem.writeInt(u32, inode_buf[20..][0..4], DELETE_TIME, .little); // i_dtime
    std.mem.writeInt(u16, inode_buf[26..][0..2], 0, .little); // i_links_count
    std.mem.writeInt(u32, inode_buf[28..][0..4], 0, .little); // i_blocks_lo
    std.mem.writeInt(u32, inode_buf[108..][0..4], 0, .little); // i_size_high / i_dir_acl
    _ = writeInodeRaw(ino);
}

fn dirIsEmpty(dir: *const Inode) bool {
    const nblocks = (dir.size + sb.block_size - 1) / sb.block_size;
    var b: u64 = 0;
    while (b < nblocks) : (b += 1) {
        const phys = mapBlock(dir, b) orelse continue;
        if (!readBlock(phys, &dir_buf)) return false;
        var off: usize = 0;
        while (off + 8 <= sb.block_size) {
            const ino = rd32(&dir_buf, off);
            const rec_len = rd16(&dir_buf, off + 4);
            if (rec_len < 8) break;
            const nl = dir_buf[off + 6];
            if (ino != 0 and nl != 0) {
                const name = dir_buf[off + 8 ..][0..nl];
                if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) return false;
            }
            off += rec_len;
        }
    }
    return true;
}

// Free all data blocks of an extent-mapped inode (depth-0 tree). Classic block
// maps and depth>0 trees aren't reclaimed (none of our created files use them).
fn freeInodeBlocks(inode: *const Inode) void {
    if ((inode.flags & EXT4_EXTENTS_FL) == 0) return;
    if (rd16(&inode.iblock, 0) != EXTENT_MAGIC) return;
    if (rd16(&inode.iblock, 6) != 0) return; // depth > 0 unsupported
    const entries = rd16(&inode.iblock, 2);
    var i: usize = 0;
    while (i < entries) : (i += 1) {
        const e = inode.iblock[12 + i * 12 ..];
        var len = rd16(e, 4);
        if (len > 32768) len -= 32768;
        const start = lohi(rd32(e, 8), rd16(e, 6));
        var b: u64 = 0;
        while (b < len) : (b += 1) freeBlock(start + b);
    }
}

fn freeBlock(block: u64) void {
    if (block < sb.first_data_block) return;
    const rel = block - sb.first_data_block;
    const group: u32 = @intCast(rel / sb.blocks_per_group);
    const bit: u32 = @intCast(rel % sb.blocks_per_group);
    if (group >= sb.groups) return;
    const loc = gdLoc(group);
    if (!readBlock(loc.block, &idx_buf)) return;
    const bbm = lohi(rd32(idx_buf[loc.within..], 0), if (sb.desc_size >= 64) rd32(idx_buf[loc.within..], 0x20) else 0);
    if (!readBlock(bbm, &bm_buf)) return;
    const byte = bit / 8;
    const mask = @as(u8, 1) << @intCast(bit % 8);
    if ((bm_buf[byte] & mask) == 0) return; // already free
    bm_buf[byte] &= ~mask;
    if (!writeBlock(bbm, &bm_buf)) return;
    var free: u32 = rd16(idx_buf[loc.within..], 12);
    if (sb.desc_size >= 64) free |= @as(u32, rd16(idx_buf[loc.within..], 0x2C)) << 16;
    free += 1;
    std.mem.writeInt(u16, idx_buf[loc.within + 12 ..][0..2], @truncate(free), .little);
    if (sb.desc_size >= 64) std.mem.writeInt(u16, idx_buf[loc.within + 0x2C ..][0..2], @intCast(free >> 16), .little);
    sealBitmapCsum(loc.within, 0x18, 0x38, blockBitmapBytes());
    sealGroupDesc(group, loc.within);
    _ = writeBlock(loc.block, &idx_buf);
    adjustSbFree(12, 1);
}

// Highest set bit in the current inode bitmap (bm_buf), or -1 if none.
fn highestSetInodeBit() i64 {
    var byte: usize = inodeBitmapBytes();
    while (byte > 0) {
        byte -= 1;
        if (bm_buf[byte] != 0) {
            var bit: i64 = 7;
            while (bit >= 0) : (bit -= 1) {
                if ((bm_buf[byte] & (@as(u8, 1) << @intCast(bit))) != 0)
                    return @as(i64, @intCast(byte)) * 8 + bit;
            }
        }
    }
    return -1;
}

// Maintain the group descriptor's inode-accounting fields that the checksum
// covers: bg_itable_unused (from the highest used inode) and bg_used_dirs_count
// (delta when the inode is a directory). Only meaningful with metadata_csum.
// Operates on idx_buf+within (caller writes it back + reseals the desc csum).
fn sealInodeAccounting(within: usize, dir_delta: i32) void {
    if (!sb.metadata_csum) return;
    const hi = highestSetInodeBit();
    const used_top: u32 = if (hi < 0) 0 else @intCast(hi + 1);
    const unused: u32 = if (used_top >= sb.inodes_per_group) 0 else sb.inodes_per_group - used_top;
    std.mem.writeInt(u16, idx_buf[within + 0x1C ..][0..2], @truncate(unused), .little);
    if (sb.desc_size >= 64) std.mem.writeInt(u16, idx_buf[within + 0x32 ..][0..2], @intCast(unused >> 16), .little);
    if (dir_delta != 0) {
        var ud: u32 = rd16(idx_buf[within..], 0x10);
        if (sb.desc_size >= 64) ud |= @as(u32, rd16(idx_buf[within..], 0x30)) << 16;
        ud = @intCast(@as(i64, ud) + dir_delta);
        std.mem.writeInt(u16, idx_buf[within + 0x10 ..][0..2], @truncate(ud), .little);
        if (sb.desc_size >= 64) std.mem.writeInt(u16, idx_buf[within + 0x30 ..][0..2], @intCast(ud >> 16), .little);
    }
}

fn freeInode(ino: u32, is_dir: bool) void {
    if (ino == 0) return;
    const group = (ino - 1) / sb.inodes_per_group;
    const bit = (ino - 1) % sb.inodes_per_group;
    if (group >= sb.groups) return;
    const loc = gdLoc(group);
    if (!readBlock(loc.block, &idx_buf)) return;
    const ibm = lohi(rd32(idx_buf[loc.within..], 4), if (sb.desc_size >= 64) rd32(idx_buf[loc.within..], 0x24) else 0);
    if (!readBlock(ibm, &bm_buf)) return;
    const byte = bit / 8;
    const mask = @as(u8, 1) << @intCast(bit % 8);
    if ((bm_buf[byte] & mask) == 0) return;
    bm_buf[byte] &= ~mask;
    if (!writeBlock(ibm, &bm_buf)) return;
    var free: u32 = rd16(idx_buf[loc.within..], 14);
    if (sb.desc_size >= 64) free |= @as(u32, rd16(idx_buf[loc.within..], 0x2E)) << 16;
    free += 1;
    std.mem.writeInt(u16, idx_buf[loc.within + 14 ..][0..2], @truncate(free), .little);
    if (sb.desc_size >= 64) std.mem.writeInt(u16, idx_buf[loc.within + 0x2E ..][0..2], @intCast(free >> 16), .little);
    sealInodeAccounting(loc.within, if (is_dir) -1 else 0);
    sealBitmapCsum(loc.within, 0x1A, 0x3A, inodeBitmapBytes());
    sealGroupDesc(group, loc.within);
    _ = writeBlock(loc.block, &idx_buf);
    adjustSbFree(16, 1);
}

fn onClose(s: *State, fid: u32) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    if (fid != 0) s.fids[fid] = .{};
}

fn onStatus(s: *State, fid: u32) fs.HandlerError!p9.StatusReply {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    const f = &s.fids[fid];
    if (f.is_dir) return .{ .kind = .dir, .size = 0 };
    return .{ .kind = .file, .size = f.size };
}

// Write path. metadata_csum is honored (crc32c recomputed on every metadata
// write); a journal is tolerated (replayed on mount, then left untouched) but
// our own writes go DIRECT, not through jbd2 - so writes are not crash-atomic
// (fine for a clean shutdown, which keeps the journal empty). Supports
// extent-mapped files with the tree rooted in the inode (depth 0, up to 4
// extents). Deeper/wider extent trees and classic block maps are not writable.
const SplitPath = struct { parent: []const u8, name: []const u8 };
fn splitPath(path: []const u8) SplitPath {
    var p = path;
    while (p.len > 0 and p[0] == '/') p = p[1..];
    while (p.len > 0 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| return .{ .parent = p[0..i], .name = p[i + 1 ..] };
    return .{ .parent = "", .name = p };
}

inline fn roundup4(x: usize) usize {
    return (x + 3) & ~@as(usize, 3);
}

fn currentInode() Inode {
    var n: Inode = undefined;
    n.mode = rd16(&inode_buf, 0);
    n.flags = rd32(&inode_buf, 32);
    const slo = rd32(&inode_buf, 4);
    const shi: u32 = if ((n.mode & S_IFMT) == S_IFREG) rd32(&inode_buf, 108) else 0;
    n.size = lohi(slo, shi);
    @memcpy(&n.iblock, inode_buf[40..100]);
    return n;
}

fn writeAt(offset: u64, data: []const u8) bool {
    var total: usize = 0;
    while (total < data.len) {
        const n = backing.write(offset + total, data[total..]) catch return false;
        if (n == 0) return false;
        total += n;
    }
    return true;
}
fn writeBlock(block: u64, data: []const u8) bool {
    return writeAt(block * sb.block_size, data[0..sb.block_size]);
}

const GdLoc = struct { block: u64, within: usize };
fn gdLoc(group: u32) GdLoc {
    const per_block = sb.block_size / sb.desc_size;
    return .{ .block = groupDescTableBlock() + group / per_block, .within = (group % per_block) * sb.desc_size };
}

// Adjust a 32-bit superblock free counter (s_free_blocks_count_lo @12,
// s_free_inodes_count @16) by `delta`.
fn adjustSbFree(field_off: usize, delta: i64) void {
    var raw: [1024]u8 = undefined;
    if (!readAt(SB_OFFSET, &raw)) return;
    const cur = rd32(&raw, field_off);
    const nv: u32 = @intCast(@as(i64, cur) + delta);
    std.mem.writeInt(u32, raw[field_off..][0..4], nv, .little);
    sealSuper(&raw);
    _ = writeAt(SB_OFFSET, &raw);
}

// metadata_csum helpers. All no-ops unless sb.metadata_csum. Group-descriptor,
// bitmap, and inode checksums are crc32c seeded with sb.csum_seed; the dir-block
// tail checksum lives in setDirTail. Each helper mutates the relevant scratch
// buffer in place so the caller's existing writeBlock persists it.
inline fn blockBitmapBytes() usize {
    return (sb.blocks_per_group + 7) / 8;
}
inline fn inodeBitmapBytes() usize {
    return (sb.inodes_per_group + 7) / 8;
}

// Store the bitmap csum (over bm_buf) into the group descriptor at idx_buf+within.
// off_lo/off_hi are the bg_*_bitmap_csum_lo/hi field offsets within the descriptor.
fn sealBitmapCsum(within: usize, off_lo: usize, off_hi: usize, nbytes: usize) void {
    if (!sb.metadata_csum) return;
    const csum = crc32c(sb.csum_seed, bm_buf[0..nbytes]);
    std.mem.writeInt(u16, idx_buf[within + off_lo ..][0..2], @truncate(csum), .little);
    if (sb.desc_size >= 64) std.mem.writeInt(u16, idx_buf[within + off_hi ..][0..2], @truncate(csum >> 16), .little);
}

// Recompute the group descriptor checksum (bg_checksum @ +0x1E) over idx_buf.
// Must run AFTER any bitmap-csum fields in the descriptor are updated.
fn sealGroupDesc(group: u32, within: usize) void {
    if (!sb.metadata_csum) return;
    var crc = crc32cU32(sb.csum_seed, group);
    crc = crc32c(crc, idx_buf[within..][0..0x1E]);
    crc = crc32c(crc, &[_]u8{ 0, 0 }); // bg_checksum field itself zeroed
    if (sb.desc_size > 0x20) crc = crc32c(crc, idx_buf[within + 0x20 ..][0 .. sb.desc_size - 0x20]);
    std.mem.writeInt(u16, idx_buf[within + 0x1E ..][0..2], @truncate(crc), .little);
}

// Recompute the inode checksum (i_checksum_lo @ +0x7C, i_checksum_hi @ +0x82)
// over inode_buf, prefixed by (inode#, i_generation). Operates in place.
fn sealInodeCsum(ino: u32) void {
    if (!sb.metadata_csum) return;
    const has_hi = sb.inode_size > 128 and rd16(&inode_buf, 0x80) >= 4;
    std.mem.writeInt(u16, inode_buf[0x7C..][0..2], 0, .little);
    if (has_hi) std.mem.writeInt(u16, inode_buf[0x82..][0..2], 0, .little);
    const gen = rd32(&inode_buf, 100);
    var crc = crc32cU32(sb.csum_seed, ino);
    crc = crc32cU32(crc, gen);
    crc = crc32c(crc, inode_buf[0..sb.inode_size]);
    std.mem.writeInt(u16, inode_buf[0x7C..][0..2], @truncate(crc), .little);
    if (has_hi) std.mem.writeInt(u16, inode_buf[0x82..][0..2], @truncate(crc >> 16), .little);
}

// Stamp i_extra_isize on a freshly-created inode so its i_checksum_hi field is
// honored (matches mke2fs); no-op for 128-byte inodes.
inline fn stampExtraIsize() void {
    if (sb.inode_size > 128) std.mem.writeInt(u16, inode_buf[0x80..][0..2], EXTRA_ISIZE, .little);
}

// Usable bytes for directory entries in a block. With metadata_csum the last 12
// bytes hold the ext4_dir_entry_tail (the per-block dir checksum).
inline fn dirDataLen() usize {
    return if (sb.metadata_csum) sb.block_size - 12 else sb.block_size;
}

// Read just i_generation for an inode (via blk_buf, leaving wbuf/inode_buf free).
fn inodeGeneration(ino: u32) u32 {
    const loc = inodeLoc(ino) orelse return 0;
    if (!readBlock(loc.block, &blk_buf)) return 0;
    return rd32(blk_buf[loc.within..], 100);
}

// Write a directory block held in wbuf, stamping + checksumming the trailing dir
// tail when metadata_csum is on (fake dirent: rec_len 12, file_type 0xDE). The
// tail csum is keyed by the owning dir's inode# + i_generation; callers pass the
// generation explicitly since a freshly-created dir's inode isn't on disk yet.
fn writeDirBlock(dir_ino: u32, gen: u32, phys: u64) bool {
    if (sb.metadata_csum) {
        const tail = sb.block_size - 12;
        std.mem.writeInt(u32, wbuf[tail..][0..4], 0, .little); // det_reserved_zero1 (inode=0)
        std.mem.writeInt(u16, wbuf[tail + 4 ..][0..2], 12, .little); // det_rec_len
        wbuf[tail + 6] = 0; // det_reserved_zero2 (name_len)
        wbuf[tail + 7] = 0xDE; // det_reserved_ft = EXT4_FT_DIR_CSUM
        var crc = crc32cU32(sb.csum_seed, dir_ino);
        crc = crc32cU32(crc, gen);
        crc = crc32c(crc, wbuf[0..tail]);
        std.mem.writeInt(u32, wbuf[tail + 8 ..][0..4], crc, .little);
    }
    return writeBlock(phys, &wbuf);
}

fn allocBlock() ?u64 {
    var group: u32 = 0;
    while (group < sb.groups) : (group += 1) {
        const loc = gdLoc(group);
        if (!readBlock(loc.block, &idx_buf)) return null;
        var free: u32 = rd16(idx_buf[loc.within..], 12);
        if (sb.desc_size >= 64) free |= @as(u32, rd16(idx_buf[loc.within..], 0x2C)) << 16;
        if (free == 0) continue;
        const bbm = lohi(rd32(idx_buf[loc.within..], 0), if (sb.desc_size >= 64) rd32(idx_buf[loc.within..], 0x20) else 0);
        if (!readBlock(bbm, &bm_buf)) return null;
        var bit: u32 = 0;
        while (bit < sb.blocks_per_group) : (bit += 1) {
            const byte = bit / 8;
            const mask = @as(u8, 1) << @intCast(bit % 8);
            if ((bm_buf[byte] & mask) == 0) {
                bm_buf[byte] |= mask;
                if (!writeBlock(bbm, &bm_buf)) return null;
                const nf = free - 1;
                std.mem.writeInt(u16, idx_buf[loc.within + 12 ..][0..2], @truncate(nf), .little);
                if (sb.desc_size >= 64) std.mem.writeInt(u16, idx_buf[loc.within + 0x2C ..][0..2], @intCast(nf >> 16), .little);
                sealBitmapCsum(loc.within, 0x18, 0x38, blockBitmapBytes());
                sealGroupDesc(group, loc.within);
                if (!writeBlock(loc.block, &idx_buf)) return null;
                adjustSbFree(12, -1);
                return @as(u64, group) * sb.blocks_per_group + sb.first_data_block + bit;
            }
        }
    }
    return null;
}

fn allocInode(is_dir: bool) ?u32 {
    var group: u32 = 0;
    while (group < sb.groups) : (group += 1) {
        const loc = gdLoc(group);
        if (!readBlock(loc.block, &idx_buf)) return null;
        var free: u32 = rd16(idx_buf[loc.within..], 14);
        if (sb.desc_size >= 64) free |= @as(u32, rd16(idx_buf[loc.within..], 0x2E)) << 16;
        if (free == 0) continue;
        const ibm = lohi(rd32(idx_buf[loc.within..], 4), if (sb.desc_size >= 64) rd32(idx_buf[loc.within..], 0x24) else 0);
        if (!readBlock(ibm, &bm_buf)) return null;
        var bit: u32 = 0;
        while (bit < sb.inodes_per_group) : (bit += 1) {
            const byte = bit / 8;
            const mask = @as(u8, 1) << @intCast(bit % 8);
            if ((bm_buf[byte] & mask) == 0) {
                bm_buf[byte] |= mask;
                if (!writeBlock(ibm, &bm_buf)) return null;
                const nf = free - 1;
                std.mem.writeInt(u16, idx_buf[loc.within + 14 ..][0..2], @truncate(nf), .little);
                if (sb.desc_size >= 64) std.mem.writeInt(u16, idx_buf[loc.within + 0x2E ..][0..2], @intCast(nf >> 16), .little);
                sealInodeAccounting(loc.within, if (is_dir) 1 else 0);
                sealBitmapCsum(loc.within, 0x1A, 0x3A, inodeBitmapBytes());
                sealGroupDesc(group, loc.within);
                if (!writeBlock(loc.block, &idx_buf)) return null;
                adjustSbFree(16, -1);
                return group * sb.inodes_per_group + bit + 1; // inodes are 1-based
            }
        }
    }
    return null;
}

const InodeLoc = struct { block: u64, within: usize };
fn inodeLoc(ino: u32) ?InodeLoc {
    if (ino == 0) return null;
    const group = (ino - 1) / sb.inodes_per_group;
    const index = (ino - 1) % sb.inodes_per_group;
    const table = inodeTableBlock(group) orelse return null;
    const byte = @as(u64, index) * sb.inode_size;
    return .{ .block = table + byte / sb.block_size, .within = @intCast(byte % sb.block_size) };
}

// Loads the raw inode into inode_buf (via wbuf, leaving blk_buf free).
fn readInodeRaw(ino: u32) ?InodeLoc {
    const loc = inodeLoc(ino) orelse return null;
    if (!readBlock(loc.block, &wbuf)) return null;
    @memcpy(inode_buf[0..sb.inode_size], wbuf[loc.within..][0..sb.inode_size]);
    return loc;
}
// Seal the inode checksum (if enabled) then write inode_buf back to its slot.
fn writeInodeRaw(ino: u32) bool {
    const loc = inodeLoc(ino) orelse return false;
    sealInodeCsum(ino);
    if (!readBlock(loc.block, &wbuf)) return false;
    @memcpy(wbuf[loc.within..][0..sb.inode_size], inode_buf[0..sb.inode_size]);
    return writeBlock(loc.block, &wbuf);
}

// Append a (logical -> phys) mapping to the inode's root extent list. Merges
// into the last extent when contiguous; else adds a new one (max 4). Operates
// on inode_buf; caller writes it back. Returns false if the tree can't grow.
fn appendExtent(logical: u64, phys: u64) bool {
    if (rd16(&inode_buf, 40) != EXTENT_MAGIC) {
        std.mem.writeInt(u16, inode_buf[40..][0..2], EXTENT_MAGIC, .little);
        std.mem.writeInt(u16, inode_buf[42..][0..2], 0, .little); // entries
        std.mem.writeInt(u16, inode_buf[44..][0..2], 4, .little); // max
        std.mem.writeInt(u16, inode_buf[46..][0..2], 0, .little); // depth
        std.mem.writeInt(u32, inode_buf[48..][0..4], 0, .little); // generation
    }
    if (rd16(&inode_buf, 46) != 0) return false; // depth>0 unsupported
    const entries = rd16(&inode_buf, 42);
    if (entries > 0) {
        const e = 52 + (@as(usize, entries) - 1) * 12;
        const eb = rd32(&inode_buf, e);
        const el = rd16(&inode_buf, e + 4);
        const es = lohi(rd32(&inode_buf, e + 8), rd16(&inode_buf, e + 6));
        if (el < 32768 and logical == eb + el and phys == es + el) {
            std.mem.writeInt(u16, inode_buf[e + 4 ..][0..2], el + 1, .little);
            return true;
        }
    }
    if (entries >= 4) return false;
    const e = 52 + @as(usize, entries) * 12;
    std.mem.writeInt(u32, inode_buf[e..][0..4], @intCast(logical), .little);
    std.mem.writeInt(u16, inode_buf[e + 4 ..][0..2], 1, .little);
    std.mem.writeInt(u16, inode_buf[e + 6 ..][0..2], @intCast(phys >> 32), .little);
    std.mem.writeInt(u32, inode_buf[e + 8 ..][0..4], @truncate(phys), .little);
    std.mem.writeInt(u16, inode_buf[42..][0..2], entries + 1, .little);
    return true;
}

fn incIBlocks(nblocks: u64) void {
    const cur = rd32(&inode_buf, 28);
    const add: u32 = @intCast(nblocks * (sb.block_size / 512));
    std.mem.writeInt(u32, inode_buf[28..][0..4], cur + add, .little);
}

fn writeInodeData(ino: u32, offset: u64, data: []const u8) ?usize {
    _ = readInodeRaw(ino) orelse return null;
    var cur = currentInode();
    if ((cur.flags & EXT4_EXTENTS_FL) == 0) return null; // only extent files
    var written: usize = 0;
    var dirty = false;
    while (written < data.len) {
        const pos = offset + written;
        const logical = pos / sb.block_size;
        const within: usize = @intCast(pos % sb.block_size);
        const chunk: usize = @intCast(@min(@as(u64, sb.block_size - within), data.len - written));
        var phys = mapBlock(&cur, logical);
        if (phys == null) {
            const nb = allocBlock() orelse break;
            if (!appendExtent(logical, nb)) break;
            incIBlocks(1);
            cur = currentInode(); // refresh iblock after the append
            @memset(wbuf[0..sb.block_size], 0);
            phys = nb;
        } else if (within != 0 or chunk < sb.block_size) {
            if (!readBlock(phys.?, &wbuf)) return null;
        }
        @memcpy(wbuf[within..][0..chunk], data[written..][0..chunk]);
        if (!writeBlock(phys.?, &wbuf)) return null;
        written += chunk;
        dirty = true;
    }
    const new_size = @max(cur.size, offset + written);
    if (new_size != cur.size) {
        std.mem.writeInt(u32, inode_buf[4..][0..4], @truncate(new_size), .little);
        if ((cur.mode & S_IFMT) == S_IFREG) std.mem.writeInt(u32, inode_buf[108..][0..4], @intCast(new_size >> 32), .little);
        dirty = true;
    }
    if (dirty) _ = writeInodeRaw(ino);
    return written;
}

// Insert a directory entry into `dir_ino`, splitting an existing record's slack
// or allocating a fresh directory block when none has room.
fn addDirEntry(dir_ino: u32, name: []const u8, ino: u32, ftype: u8) bool {
    var dir: Inode = undefined;
    if (!readInode(dir_ino, &dir)) return false;
    const needed = 8 + roundup4(name.len);
    const nblocks = (dir.size + sb.block_size - 1) / sb.block_size;
    var b: u64 = 0;
    while (b < nblocks) : (b += 1) {
        const phys = mapBlock(&dir, b) orelse continue;
        if (!readBlock(phys, &wbuf)) return false;
        var off: usize = 0;
        while (off + 8 <= dirDataLen()) {
            const e_ino = rd32(&wbuf, off);
            const rec_len = rd16(&wbuf, off + 4);
            if (rec_len < 8) break;
            const nl = wbuf[off + 6];
            const used: usize = if (e_ino == 0) 0 else 8 + roundup4(nl);
            if (rec_len >= used + needed) {
                var new_off = off;
                var new_rec = rec_len;
                if (e_ino != 0) {
                    std.mem.writeInt(u16, wbuf[off + 4 ..][0..2], @intCast(used), .little);
                    new_off = off + used;
                    new_rec = rec_len - @as(u16, @intCast(used));
                }
                std.mem.writeInt(u32, wbuf[new_off..][0..4], ino, .little);
                std.mem.writeInt(u16, wbuf[new_off + 4 ..][0..2], new_rec, .little);
                wbuf[new_off + 6] = @intCast(name.len);
                wbuf[new_off + 7] = ftype;
                @memcpy(wbuf[new_off + 8 ..][0..name.len], name);
                return writeDirBlock(dir_ino, inodeGeneration(dir_ino), phys);
            }
            off += rec_len;
        }
    }
    // No room in existing blocks: add a fresh directory block.
    const nb = allocBlock() orelse return false;
    @memset(wbuf[0..sb.block_size], 0);
    std.mem.writeInt(u32, wbuf[0..4], ino, .little);
    std.mem.writeInt(u16, wbuf[4..][0..2], @intCast(dirDataLen()), .little);
    wbuf[6] = @intCast(name.len);
    wbuf[7] = ftype;
    @memcpy(wbuf[8..][0..name.len], name);
    if (!writeDirBlock(dir_ino, inodeGeneration(dir_ino), nb)) return false;

    _ = readInodeRaw(dir_ino) orelse return false;
    if (!appendExtent(nblocks, nb)) return false;
    incIBlocks(1);
    const newsize = (nblocks + 1) * sb.block_size;
    std.mem.writeInt(u32, inode_buf[4..][0..4], @truncate(newsize), .little);
    return writeInodeRaw(dir_ino);
}

// Unlink `name` from `dir` by merging its record into the previous one (or
// clearing the inode field if it is the first record in a block).
fn removeDirEntry(dir_ino: u32, dir: *const Inode, name: []const u8) bool {
    const nblocks = (dir.size + sb.block_size - 1) / sb.block_size;
    var b: u64 = 0;
    while (b < nblocks) : (b += 1) {
        const phys = mapBlock(dir, b) orelse continue;
        if (!readBlock(phys, &wbuf)) return false;
        var off: usize = 0;
        var prev: ?usize = null;
        while (off + 8 <= dirDataLen()) {
            const e_ino = rd32(&wbuf, off);
            const rec_len = rd16(&wbuf, off + 4);
            if (rec_len < 8) break;
            const nl = wbuf[off + 6];
            if (e_ino != 0 and nl == name.len and std.mem.eql(u8, wbuf[off + 8 ..][0..nl], name)) {
                if (prev) |pf| {
                    const pr = rd16(&wbuf, pf + 4);
                    std.mem.writeInt(u16, wbuf[pf + 4 ..][0..2], pr + rec_len, .little);
                } else {
                    std.mem.writeInt(u32, wbuf[off..][0..4], 0, .little);
                }
                return writeDirBlock(dir_ino, inodeGeneration(dir_ino), phys);
            }
            prev = off;
            off += rec_len;
        }
    }
    return false;
}
