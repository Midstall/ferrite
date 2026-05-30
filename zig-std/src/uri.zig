//! Parser for `<authority>@<version>:<path>` service URIs.

const std = @import("std");

pub const Parts = struct {
    authority: []const u8,
    version: []const u8,
    path: []const u8,
};

pub const ParseError = error{
    MissingVersion,
    MissingPath,
    BadAuthority,
    BadVersion,
    BadPath,
};

pub fn parse(uri: []const u8) ParseError!Parts {
    var at: ?usize = null;
    var colon: ?usize = null;
    for (uri, 0..) |c, i| {
        switch (c) {
            '@' => {
                if (at == null) at = i;
            },
            ':' => {
                if (colon == null) {
                    colon = i;
                    break;
                }
            },
            else => {},
        }
    }
    const at_pos = at orelse return error.MissingVersion;
    const colon_pos = colon orelse return error.MissingPath;
    if (colon_pos <= at_pos) return error.MissingVersion;

    const authority = uri[0..at_pos];
    const version = uri[at_pos + 1 .. colon_pos];
    const path = uri[colon_pos + 1 ..];

    if (authority.len == 0) return error.BadAuthority;
    if (version.len == 0) return error.BadVersion;
    if (path.len == 0 or path[0] != '/') return error.BadPath;

    for (authority) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => {},
            else => return error.BadAuthority,
        }
    }
    for (version) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-' => {},
            else => return error.BadVersion,
        }
    }
    for (path) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '/', '.', '-', '_', ':' => {},
            else => return error.BadPath,
        }
    }

    return .{ .authority = authority, .version = version, .path = path };
}

pub fn formatPrefix(buf: []u8, p: Parts) error{BufferTooSmall}![]u8 {
    const need = p.authority.len + 1 + p.version.len;
    if (buf.len < need) return error.BufferTooSmall;
    @memcpy(buf[0..p.authority.len], p.authority);
    buf[p.authority.len] = '@';
    @memcpy(buf[p.authority.len + 1 ..][0..p.version.len], p.version);
    return buf[0..need];
}
