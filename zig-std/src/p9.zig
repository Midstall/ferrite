//! Plan-9-style request/response protocol over Ferrite channels.

const std = @import("std");

pub const Op = enum(u8) {
    walk = 1,
    walk_reply = 2,
    open = 3,
    open_reply = 4,
    read = 5,
    read_reply = 6,
    write = 7,
    write_reply = 8,
    close = 9,
    close_reply = 10,
    status = 11,
    status_reply = 12,
    err_reply = 13,
    /// Payload: `u16 prefix_len | prefix`. Service send-cap rides as `cap_xfer`. No reply.
    register = 14,
    register_reply = 15,
    /// Payload: `u16 prefix_len | prefix`. `cap_xfer` is reply-channel send-cap; reply carries service cap.
    lookup = 16,
    lookup_reply = 17,
    /// Walk-handoff reply. New service cap rides via `cap_xfer`; payload is remaining path.
    walk_redirect = 18,
    /// Payload: `u8 kind | u16 name_len | name`. Driver service-cap rides as `cap_xfer`.
    register_device = 19,
    register_device_reply = 20,
    /// Payload: `u16 path_len | path`. `cap_xfer` = reply-channel send-cap.
    resolve_mount = 21,
    resolve_mount_reply = 22,
    /// Payload: `u16 prefix_len | prefix | u16 authority_len | authority`.
    add_mount = 23,
    add_mount_reply = 24,
    /// Payload: `u16 compat_len | compat | u32 index`. `cap_xfer` = reply-channel send-cap.
    probe_device = 25,
    /// Reply payload: `u64 phys | u64 size | u32 irq | u32 has_irq`.
    probe_device_reply = 26,
    /// Payload: `u8 kind | u16 path_len | path`.
    create = 27,
    create_reply = 28,
    /// Payload: `u16 path_len | path`.
    remove = 29,
    remove_reply = 30,
    /// Payload: query path. Reply payload: NUL-separated names.
    list_mounts = 31,
    list_mounts_reply = 32,
    /// Reply payload: newline-separated `prefix\tauthority` lines.
    dump_mounts = 33,
    dump_mounts_reply = 34,
    /// Payload: `u16 path_len | path | u16 target_len | target`.
    symlink = 35,
    symlink_reply = 36,
    /// Payload: `u16 path_len | path`. Reply: `u16 target_len | target`.
    readlink = 37,
    readlink_reply = 38,
};

pub const Mode = enum(u8) {
    read = 0,
    write = 1,
    rdwr = 2,
    exec = 3,
};

pub const Errno = enum(u16) {
    ok = 0,
    not_found = 1,
    permission = 2,
    bad_fid = 3,
    bad_offset = 4,
    bad_op = 5,
    server_busy = 6,
    truncated = 7,
};

pub const Kind = enum(u8) {
    file = 0,
    dir = 1,
};

pub const DeviceKind = enum(u8) {
    char = 0,
    block = 1,
};

pub const RegisterDeviceArgs = struct {
    kind: DeviceKind,
    name: []const u8,
};

/// 4-byte little-endian preamble on every wire message.
pub const Header = extern struct {
    op: u8,
    tag: u8,
    len: u16,
};

pub const HEADER_SIZE: usize = @sizeOf(Header);

pub const MAX_MSG: usize = 16 * 1024;

pub const WalkArgs = struct {
    fid: u32,
    /// Slash-separated. Empty path duplicates `fid`.
    path: []const u8,
};

pub const WalkReply = struct {
    newfid: u32,
};

pub const WalkRedirect = struct {
    remaining_path: []const u8,
};

pub const OpenArgs = struct {
    fid: u32,
    mode: Mode,
};

pub const ReadArgs = struct {
    fid: u32,
    offset: u64,
    count: u32,
};

pub const WriteArgs = struct {
    fid: u32,
    offset: u64,
    data: []const u8,
};

pub const CloseArgs = struct {
    fid: u32,
};

pub const StatusArgs = struct {
    fid: u32,
};

pub const ReadReply = struct {
    data: []const u8,
};

pub const WriteReply = struct {
    count: u32,
};

pub const StatusReply = struct {
    kind: Kind,
    size: u64,
};

pub const ErrReply = struct {
    errno: Errno,
};

pub const Error = error{BufferTooSmall};

fn writeHeader(buf: []u8, op: Op, tag: u8, payload_len: u16) Error!void {
    if (buf.len < HEADER_SIZE) return error.BufferTooSmall;
    buf[0] = @intFromEnum(op);
    buf[1] = tag;
    std.mem.writeInt(u16, buf[2..4], payload_len, .little);
}

fn writeU32(buf: []u8, off: usize, val: u32) Error!void {
    if (off + 4 > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[off..][0..4], val, .little);
}

fn writeU64(buf: []u8, off: usize, val: u64) Error!void {
    if (off + 8 > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u64, buf[off..][0..8], val, .little);
}

fn writeBytes(buf: []u8, off: usize, bytes: []const u8) Error!void {
    if (off + bytes.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[off..][0..bytes.len], bytes);
}

pub fn encodeWalk(buf: []u8, tag: u8, m: WalkArgs) Error!usize {
    if (m.path.len > std.math.maxInt(u16)) return error.BufferTooSmall;
    const payload: usize = 4 + 2 + m.path.len;
    try writeHeader(buf, .walk, tag, @intCast(payload));
    try writeU32(buf, HEADER_SIZE + 0, m.fid);
    if (HEADER_SIZE + 4 + 2 > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[HEADER_SIZE + 4 ..][0..2], @intCast(m.path.len), .little);
    try writeBytes(buf, HEADER_SIZE + 6, m.path);
    return HEADER_SIZE + payload;
}

pub fn encodeOpen(buf: []u8, tag: u8, m: OpenArgs) Error!usize {
    const payload: usize = 4 + 1;
    try writeHeader(buf, .open, tag, payload);
    try writeU32(buf, HEADER_SIZE + 0, m.fid);
    if (HEADER_SIZE + 4 >= buf.len) return error.BufferTooSmall;
    buf[HEADER_SIZE + 4] = @intFromEnum(m.mode);
    return HEADER_SIZE + payload;
}

pub fn encodeRead(buf: []u8, tag: u8, m: ReadArgs) Error!usize {
    const payload: usize = 4 + 8 + 4;
    try writeHeader(buf, .read, tag, payload);
    try writeU32(buf, HEADER_SIZE + 0, m.fid);
    try writeU64(buf, HEADER_SIZE + 4, m.offset);
    try writeU32(buf, HEADER_SIZE + 12, m.count);
    return HEADER_SIZE + payload;
}

pub fn encodeWrite(buf: []u8, tag: u8, m: WriteArgs) Error!usize {
    const data_len = m.data.len;
    if (data_len > std.math.maxInt(u16)) return error.BufferTooSmall;
    const payload: usize = 4 + 8 + 2 + data_len;
    try writeHeader(buf, .write, tag, @intCast(payload));
    try writeU32(buf, HEADER_SIZE + 0, m.fid);
    try writeU64(buf, HEADER_SIZE + 4, m.offset);
    std.mem.writeInt(u16, buf[HEADER_SIZE + 12 ..][0..2], @intCast(data_len), .little);
    try writeBytes(buf, HEADER_SIZE + 14, m.data);
    return HEADER_SIZE + payload;
}

pub fn encodeClose(buf: []u8, tag: u8, m: CloseArgs) Error!usize {
    const payload: usize = 4;
    try writeHeader(buf, .close, tag, payload);
    try writeU32(buf, HEADER_SIZE + 0, m.fid);
    return HEADER_SIZE + payload;
}

pub fn encodeStatus(buf: []u8, tag: u8, m: StatusArgs) Error!usize {
    const payload: usize = 4;
    try writeHeader(buf, .status, tag, payload);
    try writeU32(buf, HEADER_SIZE + 0, m.fid);
    return HEADER_SIZE + payload;
}

pub fn encodeReadReply(buf: []u8, tag: u8, data: []const u8) Error!usize {
    if (data.len > std.math.maxInt(u16)) return error.BufferTooSmall;
    const payload: usize = 2 + data.len;
    try writeHeader(buf, .read_reply, tag, @intCast(payload));
    std.mem.writeInt(u16, buf[HEADER_SIZE..][0..2], @intCast(data.len), .little);
    try writeBytes(buf, HEADER_SIZE + 2, data);
    return HEADER_SIZE + payload;
}

pub fn encodeWriteReply(buf: []u8, tag: u8, count: u32) Error!usize {
    const payload: usize = 4;
    try writeHeader(buf, .write_reply, tag, payload);
    try writeU32(buf, HEADER_SIZE + 0, count);
    return HEADER_SIZE + payload;
}

pub fn encodeStatusReply(buf: []u8, tag: u8, m: StatusReply) Error!usize {
    const payload: usize = 1 + 8;
    try writeHeader(buf, .status_reply, tag, payload);
    if (HEADER_SIZE + 9 > buf.len) return error.BufferTooSmall;
    buf[HEADER_SIZE] = @intFromEnum(m.kind);
    std.mem.writeInt(u64, buf[HEADER_SIZE + 1 ..][0..8], m.size, .little);
    return HEADER_SIZE + payload;
}

pub fn encodeErrReply(buf: []u8, tag: u8, errno: Errno) Error!usize {
    const payload: usize = 2;
    try writeHeader(buf, .err_reply, tag, payload);
    if (HEADER_SIZE + 2 > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[HEADER_SIZE..][0..2], @intFromEnum(errno), .little);
    return HEADER_SIZE + payload;
}

pub fn encodeWalkReply(buf: []u8, tag: u8, m: WalkReply) Error!usize {
    const payload: usize = 4;
    try writeHeader(buf, .walk_reply, tag, payload);
    try writeU32(buf, HEADER_SIZE + 0, m.newfid);
    return HEADER_SIZE + payload;
}

pub fn encodeWalkRedirect(buf: []u8, tag: u8, m: WalkRedirect) Error!usize {
    if (m.remaining_path.len > std.math.maxInt(u16)) return error.BufferTooSmall;
    const payload: usize = 2 + m.remaining_path.len;
    try writeHeader(buf, .walk_redirect, tag, @intCast(payload));
    if (HEADER_SIZE + 2 > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[HEADER_SIZE..][0..2], @intCast(m.remaining_path.len), .little);
    try writeBytes(buf, HEADER_SIZE + 2, m.remaining_path);
    return HEADER_SIZE + payload;
}

pub fn encodeRegisterDevice(buf: []u8, tag: u8, m: RegisterDeviceArgs) Error!usize {
    if (m.name.len > std.math.maxInt(u16)) return error.BufferTooSmall;
    const payload: usize = 1 + 2 + m.name.len;
    try writeHeader(buf, .register_device, tag, @intCast(payload));
    if (HEADER_SIZE + 3 > buf.len) return error.BufferTooSmall;
    buf[HEADER_SIZE] = @intFromEnum(m.kind);
    std.mem.writeInt(u16, buf[HEADER_SIZE + 1 ..][0..2], @intCast(m.name.len), .little);
    try writeBytes(buf, HEADER_SIZE + 3, m.name);
    return HEADER_SIZE + payload;
}

pub fn encodeRegisterDeviceReply(buf: []u8, tag: u8) Error!usize {
    try writeHeader(buf, .register_device_reply, tag, 0);
    return HEADER_SIZE;
}

pub fn encodeOpenReply(buf: []u8, tag: u8) Error!usize {
    try writeHeader(buf, .open_reply, tag, 0);
    return HEADER_SIZE;
}

pub fn encodeCloseReply(buf: []u8, tag: u8) Error!usize {
    try writeHeader(buf, .close_reply, tag, 0);
    return HEADER_SIZE;
}

pub fn encodeRegister(buf: []u8, tag: u8, prefix: []const u8) Error!usize {
    if (prefix.len > std.math.maxInt(u16)) return error.BufferTooSmall;
    const payload: usize = 2 + prefix.len;
    try writeHeader(buf, .register, tag, @intCast(payload));
    if (HEADER_SIZE + 2 > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[HEADER_SIZE..][0..2], @intCast(prefix.len), .little);
    try writeBytes(buf, HEADER_SIZE + 2, prefix);
    return HEADER_SIZE + payload;
}

pub fn encodeRegisterReply(buf: []u8, tag: u8) Error!usize {
    try writeHeader(buf, .register_reply, tag, 0);
    return HEADER_SIZE;
}

pub fn encodeLookup(buf: []u8, tag: u8, prefix: []const u8) Error!usize {
    if (prefix.len > std.math.maxInt(u16)) return error.BufferTooSmall;
    const payload: usize = 2 + prefix.len;
    try writeHeader(buf, .lookup, tag, @intCast(payload));
    if (HEADER_SIZE + 2 > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[HEADER_SIZE..][0..2], @intCast(prefix.len), .little);
    try writeBytes(buf, HEADER_SIZE + 2, prefix);
    return HEADER_SIZE + payload;
}

pub fn encodeLookupReply(buf: []u8, tag: u8) Error!usize {
    try writeHeader(buf, .lookup_reply, tag, 0);
    return HEADER_SIZE;
}

pub fn encodeResolveMount(buf: []u8, tag: u8, path: []const u8) Error!usize {
    if (path.len > std.math.maxInt(u16)) return error.BufferTooSmall;
    const payload: usize = 2 + path.len;
    try writeHeader(buf, .resolve_mount, tag, @intCast(payload));
    if (HEADER_SIZE + 2 > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[HEADER_SIZE..][0..2], @intCast(path.len), .little);
    try writeBytes(buf, HEADER_SIZE + 2, path);
    return HEADER_SIZE + payload;
}

pub fn encodeResolveMountReply(buf: []u8, tag: u8, authority: []const u8, sub_path: []const u8) Error!usize {
    if (authority.len > std.math.maxInt(u16) or sub_path.len > std.math.maxInt(u16)) return error.BufferTooSmall;
    const payload: usize = 2 + authority.len + 2 + sub_path.len;
    try writeHeader(buf, .resolve_mount_reply, tag, @intCast(payload));
    if (HEADER_SIZE + payload > buf.len) return error.BufferTooSmall;
    var off: usize = HEADER_SIZE;
    std.mem.writeInt(u16, buf[off..][0..2], @intCast(authority.len), .little);
    off += 2;
    @memcpy(buf[off..][0..authority.len], authority);
    off += authority.len;
    std.mem.writeInt(u16, buf[off..][0..2], @intCast(sub_path.len), .little);
    off += 2;
    @memcpy(buf[off..][0..sub_path.len], sub_path);
    return HEADER_SIZE + payload;
}

pub fn encodeAddMount(buf: []u8, tag: u8, prefix: []const u8, authority: []const u8) Error!usize {
    if (prefix.len > std.math.maxInt(u16) or authority.len > std.math.maxInt(u16)) return error.BufferTooSmall;
    const payload: usize = 2 + prefix.len + 2 + authority.len;
    try writeHeader(buf, .add_mount, tag, @intCast(payload));
    if (HEADER_SIZE + payload > buf.len) return error.BufferTooSmall;
    var off: usize = HEADER_SIZE;
    std.mem.writeInt(u16, buf[off..][0..2], @intCast(prefix.len), .little);
    off += 2;
    @memcpy(buf[off..][0..prefix.len], prefix);
    off += prefix.len;
    std.mem.writeInt(u16, buf[off..][0..2], @intCast(authority.len), .little);
    off += 2;
    @memcpy(buf[off..][0..authority.len], authority);
    return HEADER_SIZE + payload;
}

pub fn encodeAddMountReply(buf: []u8, tag: u8) Error!usize {
    try writeHeader(buf, .add_mount_reply, tag, 0);
    return HEADER_SIZE;
}

pub fn encodeProbeDevice(buf: []u8, tag: u8, args: ProbeDeviceArgs) Error!usize {
    if (args.compat.len > std.math.maxInt(u16)) return error.BufferTooSmall;
    const payload: usize = 2 + args.compat.len + 4;
    try writeHeader(buf, .probe_device, tag, @intCast(payload));
    if (HEADER_SIZE + payload > buf.len) return error.BufferTooSmall;
    var off: usize = HEADER_SIZE;
    std.mem.writeInt(u16, buf[off..][0..2], @intCast(args.compat.len), .little);
    off += 2;
    @memcpy(buf[off..][0..args.compat.len], args.compat);
    off += args.compat.len;
    std.mem.writeInt(u32, buf[off..][0..4], args.index, .little);
    return HEADER_SIZE + payload;
}

pub fn encodeCreate(buf: []u8, tag: u8, args: CreateArgs) Error!usize {
    if (args.path.len > std.math.maxInt(u16)) return error.BufferTooSmall;
    const payload: usize = 1 + 2 + args.path.len;
    try writeHeader(buf, .create, tag, @intCast(payload));
    if (HEADER_SIZE + payload > buf.len) return error.BufferTooSmall;
    var off: usize = HEADER_SIZE;
    buf[off] = @intFromEnum(args.kind);
    off += 1;
    std.mem.writeInt(u16, buf[off..][0..2], @intCast(args.path.len), .little);
    off += 2;
    @memcpy(buf[off..][0..args.path.len], args.path);
    return HEADER_SIZE + payload;
}

pub fn encodeCreateReply(buf: []u8, tag: u8) Error!usize {
    try writeHeader(buf, .create_reply, tag, 0);
    return HEADER_SIZE;
}

pub fn encodeRemove(buf: []u8, tag: u8, args: RemoveArgs) Error!usize {
    if (args.path.len > std.math.maxInt(u16)) return error.BufferTooSmall;
    const payload: usize = 2 + args.path.len;
    try writeHeader(buf, .remove, tag, @intCast(payload));
    if (HEADER_SIZE + payload > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[HEADER_SIZE..][0..2], @intCast(args.path.len), .little);
    @memcpy(buf[HEADER_SIZE + 2 ..][0..args.path.len], args.path);
    return HEADER_SIZE + payload;
}

pub fn encodeRemoveReply(buf: []u8, tag: u8) Error!usize {
    try writeHeader(buf, .remove_reply, tag, 0);
    return HEADER_SIZE;
}

pub fn encodeSymlink(buf: []u8, tag: u8, args: SymlinkArgs) Error!usize {
    if (args.path.len > std.math.maxInt(u16) or args.target.len > std.math.maxInt(u16)) return error.BufferTooSmall;
    const payload: usize = 2 + args.path.len + 2 + args.target.len;
    try writeHeader(buf, .symlink, tag, @intCast(payload));
    if (HEADER_SIZE + payload > buf.len) return error.BufferTooSmall;
    var off: usize = HEADER_SIZE;
    std.mem.writeInt(u16, buf[off..][0..2], @intCast(args.path.len), .little);
    off += 2;
    @memcpy(buf[off..][0..args.path.len], args.path);
    off += args.path.len;
    std.mem.writeInt(u16, buf[off..][0..2], @intCast(args.target.len), .little);
    off += 2;
    @memcpy(buf[off..][0..args.target.len], args.target);
    return HEADER_SIZE + payload;
}

pub fn encodeSymlinkReply(buf: []u8, tag: u8) Error!usize {
    try writeHeader(buf, .symlink_reply, tag, 0);
    return HEADER_SIZE;
}

pub fn encodeReadlink(buf: []u8, tag: u8, path: []const u8) Error!usize {
    if (path.len > std.math.maxInt(u16)) return error.BufferTooSmall;
    const payload: usize = 2 + path.len;
    try writeHeader(buf, .readlink, tag, @intCast(payload));
    if (HEADER_SIZE + payload > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[HEADER_SIZE..][0..2], @intCast(path.len), .little);
    @memcpy(buf[HEADER_SIZE + 2 ..][0..path.len], path);
    return HEADER_SIZE + payload;
}

pub fn encodeReadlinkReply(buf: []u8, tag: u8, target: []const u8) Error!usize {
    if (target.len > std.math.maxInt(u16)) return error.BufferTooSmall;
    const payload: usize = 2 + target.len;
    try writeHeader(buf, .readlink_reply, tag, @intCast(payload));
    if (HEADER_SIZE + payload > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[HEADER_SIZE..][0..2], @intCast(target.len), .little);
    @memcpy(buf[HEADER_SIZE + 2 ..][0..target.len], target);
    return HEADER_SIZE + payload;
}

pub fn encodeListMounts(buf: []u8, tag: u8, path: []const u8) Error!usize {
    if (path.len > std.math.maxInt(u16)) return error.BufferTooSmall;
    const payload: usize = 2 + path.len;
    try writeHeader(buf, .list_mounts, tag, @intCast(payload));
    if (HEADER_SIZE + 2 > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[HEADER_SIZE..][0..2], @intCast(path.len), .little);
    try writeBytes(buf, HEADER_SIZE + 2, path);
    return HEADER_SIZE + payload;
}

pub fn encodeListMountsReply(buf: []u8, tag: u8, names: []const u8) Error!usize {
    if (names.len > std.math.maxInt(u16)) return error.BufferTooSmall;
    const payload: usize = 2 + names.len;
    try writeHeader(buf, .list_mounts_reply, tag, @intCast(payload));
    if (HEADER_SIZE + 2 > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[HEADER_SIZE..][0..2], @intCast(names.len), .little);
    try writeBytes(buf, HEADER_SIZE + 2, names);
    return HEADER_SIZE + payload;
}

pub fn encodeDumpMounts(buf: []u8, tag: u8) Error!usize {
    try writeHeader(buf, .dump_mounts, tag, 0);
    return HEADER_SIZE;
}

pub fn encodeDumpMountsReply(buf: []u8, tag: u8, table: []const u8) Error!usize {
    if (table.len > std.math.maxInt(u16)) return error.BufferTooSmall;
    const payload: usize = 2 + table.len;
    try writeHeader(buf, .dump_mounts_reply, tag, @intCast(payload));
    if (HEADER_SIZE + 2 > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[HEADER_SIZE..][0..2], @intCast(table.len), .little);
    try writeBytes(buf, HEADER_SIZE + 2, table);
    return HEADER_SIZE + payload;
}

pub fn encodeProbeDeviceReply(buf: []u8, tag: u8, reply: ProbeDeviceReply) Error!usize {
    const payload: usize = 24;
    try writeHeader(buf, .probe_device_reply, tag, @intCast(payload));
    if (HEADER_SIZE + payload > buf.len) return error.BufferTooSmall;
    var off: usize = HEADER_SIZE;
    std.mem.writeInt(u64, buf[off..][0..8], reply.phys, .little);
    off += 8;
    std.mem.writeInt(u64, buf[off..][0..8], reply.size, .little);
    off += 8;
    std.mem.writeInt(u32, buf[off..][0..4], reply.irq, .little);
    off += 4;
    std.mem.writeInt(u32, buf[off..][0..4], reply.has_irq, .little);
    return HEADER_SIZE + payload;
}

pub const DecodeError = error{ Truncated, BadOp };

pub fn decodeHeader(buf: []const u8) DecodeError!Header {
    if (buf.len < HEADER_SIZE) return error.Truncated;
    return .{
        .op = buf[0],
        .tag = buf[1],
        .len = std.mem.readInt(u16, buf[2..4], .little),
    };
}

pub const NamePrefix = struct {
    prefix: []const u8,
};

pub const ResolveMountArgs = struct {
    path: []const u8,
};

pub const ResolveMountReply = struct {
    authority: []const u8,
    sub_path: []const u8,
};

pub const AddMountArgs = struct {
    prefix: []const u8,
    authority: []const u8,
};

pub const ProbeDeviceArgs = struct {
    compat: []const u8,
    index: u32,
};

pub const ProbeDeviceReply = extern struct {
    phys: u64,
    size: u64,
    irq: u32,
    has_irq: u32,
};

pub const CreateArgs = struct {
    kind: Kind,
    path: []const u8,
};

pub const RemoveArgs = struct {
    path: []const u8,
};

pub const SymlinkArgs = struct {
    /// The link path (created); target is the string the link points to.
    path: []const u8,
    target: []const u8,
};

pub const ReadlinkArgs = struct {
    path: []const u8,
};

pub const ReadlinkReply = struct {
    target: []const u8,
};

pub const ListMountsArgs = struct {
    path: []const u8,
};

pub const ListMountsReply = struct {
    names: []const u8,
};

pub const DumpMountsReply = struct {
    table: []const u8,
};

pub const Request = union(enum) {
    walk: WalkArgs,
    open: OpenArgs,
    read: ReadArgs,
    write: WriteArgs,
    close: CloseArgs,
    status: StatusArgs,
    register: NamePrefix,
    lookup: NamePrefix,
    register_device: RegisterDeviceArgs,
    resolve_mount: ResolveMountArgs,
    add_mount: AddMountArgs,
    probe_device: ProbeDeviceArgs,
    create: CreateArgs,
    remove: RemoveArgs,
    symlink: SymlinkArgs,
    readlink: ReadlinkArgs,
    list_mounts: ListMountsArgs,
    dump_mounts,
};

pub fn decodeRequest(buf: []const u8) DecodeError!struct { hdr: Header, req: Request } {
    const hdr = try decodeHeader(buf);
    if (buf.len < HEADER_SIZE + hdr.len) return error.Truncated;
    const p = buf[HEADER_SIZE..][0..hdr.len];
    const op: Op = std.enums.fromInt(Op, hdr.op) orelse return error.BadOp;
    const req: Request = switch (op) {
        .walk => blk: {
            if (p.len < 6) return error.Truncated;
            const fid = std.mem.readInt(u32, p[0..4], .little);
            const path_len = std.mem.readInt(u16, p[4..6], .little);
            if (p.len < 6 + path_len) return error.Truncated;
            break :blk .{ .walk = .{ .fid = fid, .path = p[6..][0..path_len] } };
        },
        .open => blk: {
            if (p.len < 5) return error.Truncated;
            break :blk .{ .open = .{
                .fid = std.mem.readInt(u32, p[0..4], .little),
                .mode = std.enums.fromInt(Mode, p[4]) orelse return error.BadOp,
            } };
        },
        .read => blk: {
            if (p.len < 16) return error.Truncated;
            break :blk .{ .read = .{
                .fid = std.mem.readInt(u32, p[0..4], .little),
                .offset = std.mem.readInt(u64, p[4..12], .little),
                .count = std.mem.readInt(u32, p[12..16], .little),
            } };
        },
        .write => blk: {
            if (p.len < 14) return error.Truncated;
            const fid = std.mem.readInt(u32, p[0..4], .little);
            const offset = std.mem.readInt(u64, p[4..12], .little);
            const data_len = std.mem.readInt(u16, p[12..14], .little);
            if (p.len < 14 + data_len) return error.Truncated;
            break :blk .{ .write = .{ .fid = fid, .offset = offset, .data = p[14..][0..data_len] } };
        },
        .close => blk: {
            if (p.len < 4) return error.Truncated;
            break :blk .{ .close = .{ .fid = std.mem.readInt(u32, p[0..4], .little) } };
        },
        .status => blk: {
            if (p.len < 4) return error.Truncated;
            break :blk .{ .status = .{ .fid = std.mem.readInt(u32, p[0..4], .little) } };
        },
        .register, .lookup => blk: {
            if (p.len < 2) return error.Truncated;
            const name_len = std.mem.readInt(u16, p[0..2], .little);
            if (p.len < 2 + name_len) return error.Truncated;
            const prefix = p[2..][0..name_len];
            break :blk if (op == .register)
                .{ .register = .{ .prefix = prefix } }
            else
                .{ .lookup = .{ .prefix = prefix } };
        },
        .register_device => blk: {
            if (p.len < 3) return error.Truncated;
            const kind = std.enums.fromInt(DeviceKind, p[0]) orelse return error.BadOp;
            const name_len = std.mem.readInt(u16, p[1..3], .little);
            if (p.len < 3 + name_len) return error.Truncated;
            break :blk .{ .register_device = .{ .kind = kind, .name = p[3..][0..name_len] } };
        },
        .resolve_mount => blk: {
            if (p.len < 2) return error.Truncated;
            const path_len = std.mem.readInt(u16, p[0..2], .little);
            if (p.len < 2 + path_len) return error.Truncated;
            break :blk .{ .resolve_mount = .{ .path = p[2..][0..path_len] } };
        },
        .add_mount => blk: {
            if (p.len < 2) return error.Truncated;
            const prefix_len = std.mem.readInt(u16, p[0..2], .little);
            if (p.len < 2 + prefix_len + 2) return error.Truncated;
            const prefix = p[2..][0..prefix_len];
            const auth_off = 2 + prefix_len;
            const auth_len = std.mem.readInt(u16, p[auth_off..][0..2], .little);
            if (p.len < auth_off + 2 + auth_len) return error.Truncated;
            const authority = p[auth_off + 2 ..][0..auth_len];
            break :blk .{ .add_mount = .{ .prefix = prefix, .authority = authority } };
        },
        .probe_device => blk: {
            if (p.len < 2) return error.Truncated;
            const compat_len = std.mem.readInt(u16, p[0..2], .little);
            if (p.len < 2 + compat_len + 4) return error.Truncated;
            const compat = p[2..][0..compat_len];
            const index = std.mem.readInt(u32, p[2 + compat_len ..][0..4], .little);
            break :blk .{ .probe_device = .{ .compat = compat, .index = index } };
        },
        .create => blk: {
            if (p.len < 3) return error.Truncated;
            const k = std.enums.fromInt(Kind, p[0]) orelse return error.BadOp;
            const path_len = std.mem.readInt(u16, p[1..3], .little);
            if (p.len < 3 + path_len) return error.Truncated;
            break :blk .{ .create = .{ .kind = k, .path = p[3..][0..path_len] } };
        },
        .remove => blk: {
            if (p.len < 2) return error.Truncated;
            const path_len = std.mem.readInt(u16, p[0..2], .little);
            if (p.len < 2 + path_len) return error.Truncated;
            break :blk .{ .remove = .{ .path = p[2..][0..path_len] } };
        },
        .symlink => blk: {
            if (p.len < 2) return error.Truncated;
            const path_len = std.mem.readInt(u16, p[0..2], .little);
            if (p.len < 2 + path_len + 2) return error.Truncated;
            const t_off = 2 + path_len;
            const target_len = std.mem.readInt(u16, p[t_off..][0..2], .little);
            if (p.len < t_off + 2 + target_len) return error.Truncated;
            break :blk .{ .symlink = .{ .path = p[2..][0..path_len], .target = p[t_off + 2 ..][0..target_len] } };
        },
        .readlink => blk: {
            if (p.len < 2) return error.Truncated;
            const path_len = std.mem.readInt(u16, p[0..2], .little);
            if (p.len < 2 + path_len) return error.Truncated;
            break :blk .{ .readlink = .{ .path = p[2..][0..path_len] } };
        },
        .list_mounts => blk: {
            if (p.len < 2) return error.Truncated;
            const path_len = std.mem.readInt(u16, p[0..2], .little);
            if (p.len < 2 + path_len) return error.Truncated;
            break :blk .{ .list_mounts = .{ .path = p[2..][0..path_len] } };
        },
        .dump_mounts => .dump_mounts,
        else => return error.BadOp,
    };
    return .{ .hdr = hdr, .req = req };
}

pub const Response = union(enum) {
    walk: WalkReply,
    open: void,
    read: ReadReply,
    write: WriteReply,
    close: void,
    status: StatusReply,
    register: void,
    lookup: void,
    walk_redirect: WalkRedirect,
    register_device: void,
    resolve_mount: ResolveMountReply,
    add_mount: void,
    probe_device: ProbeDeviceReply,
    create: void,
    remove: void,
    symlink: void,
    readlink: ReadlinkReply,
    list_mounts: ListMountsReply,
    dump_mounts: DumpMountsReply,
    err: ErrReply,
};

pub fn decodeResponse(buf: []const u8) DecodeError!struct { hdr: Header, resp: Response } {
    const hdr = try decodeHeader(buf);
    if (buf.len < HEADER_SIZE + hdr.len) return error.Truncated;
    const p = buf[HEADER_SIZE..][0..hdr.len];
    const op: Op = std.enums.fromInt(Op, hdr.op) orelse return error.BadOp;
    const resp: Response = switch (op) {
        .walk_reply => blk: {
            if (p.len < 4) return error.Truncated;
            break :blk .{ .walk = .{ .newfid = std.mem.readInt(u32, p[0..4], .little) } };
        },
        .open_reply => .open,
        .read_reply => blk: {
            if (p.len < 2) return error.Truncated;
            const data_len = std.mem.readInt(u16, p[0..2], .little);
            if (p.len < 2 + data_len) return error.Truncated;
            break :blk .{ .read = .{ .data = p[2..][0..data_len] } };
        },
        .write_reply => blk: {
            if (p.len < 4) return error.Truncated;
            break :blk .{ .write = .{ .count = std.mem.readInt(u32, p[0..4], .little) } };
        },
        .close_reply => .close,
        .status_reply => blk: {
            if (p.len < 9) return error.Truncated;
            const k = std.enums.fromInt(Kind, p[0]) orelse return error.BadOp;
            const size = std.mem.readInt(u64, p[1..9], .little);
            break :blk .{ .status = .{ .kind = k, .size = size } };
        },
        .register_reply => .register,
        .lookup_reply => .lookup,
        .walk_redirect => blk: {
            if (p.len < 2) return error.Truncated;
            const path_len = std.mem.readInt(u16, p[0..2], .little);
            if (p.len < 2 + path_len) return error.Truncated;
            break :blk .{ .walk_redirect = .{ .remaining_path = p[2..][0..path_len] } };
        },
        .register_device_reply => .register_device,
        .resolve_mount_reply => blk: {
            if (p.len < 2) return error.Truncated;
            const auth_len = std.mem.readInt(u16, p[0..2], .little);
            if (p.len < 2 + auth_len + 2) return error.Truncated;
            const authority = p[2..][0..auth_len];
            const sub_off = 2 + auth_len;
            const sub_len = std.mem.readInt(u16, p[sub_off..][0..2], .little);
            if (p.len < sub_off + 2 + sub_len) return error.Truncated;
            break :blk .{ .resolve_mount = .{
                .authority = authority,
                .sub_path = p[sub_off + 2 ..][0..sub_len],
            } };
        },
        .add_mount_reply => .add_mount,
        .probe_device_reply => blk: {
            if (p.len < 24) return error.Truncated;
            break :blk .{ .probe_device = .{
                .phys = std.mem.readInt(u64, p[0..8], .little),
                .size = std.mem.readInt(u64, p[8..16], .little),
                .irq = std.mem.readInt(u32, p[16..20], .little),
                .has_irq = std.mem.readInt(u32, p[20..24], .little),
            } };
        },
        .create_reply => .create,
        .remove_reply => .remove,
        .symlink_reply => .symlink,
        .readlink_reply => blk: {
            if (p.len < 2) return error.Truncated;
            const tlen = std.mem.readInt(u16, p[0..2], .little);
            if (p.len < 2 + tlen) return error.Truncated;
            break :blk .{ .readlink = .{ .target = p[2..][0..tlen] } };
        },
        .list_mounts_reply => blk: {
            if (p.len < 2) return error.Truncated;
            const names_len = std.mem.readInt(u16, p[0..2], .little);
            if (p.len < 2 + names_len) return error.Truncated;
            break :blk .{ .list_mounts = .{ .names = p[2..][0..names_len] } };
        },
        .dump_mounts_reply => blk: {
            if (p.len < 2) return error.Truncated;
            const table_len = std.mem.readInt(u16, p[0..2], .little);
            if (p.len < 2 + table_len) return error.Truncated;
            break :blk .{ .dump_mounts = .{ .table = p[2..][0..table_len] } };
        },
        .err_reply => blk: {
            if (p.len < 2) return error.Truncated;
            const code = std.mem.readInt(u16, p[0..2], .little);
            const errno = std.enums.fromInt(Errno, code) orelse return error.BadOp;
            break :blk .{ .err = .{ .errno = errno } };
        },
        else => return error.BadOp,
    };
    return .{ .hdr = hdr, .resp = resp };
}
