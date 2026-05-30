const std = @import("std");

var raw: []const u8 = &.{};

/// The slice must outlive every reader; it points into the DTB or Limine
/// response region.
pub fn init(bytes: []const u8) void {
    raw = bytes;
}

pub fn get() []const u8 {
    return raw;
}

/// Splits on ASCII space + tab; no shell quoting.
pub const TokenIter = struct {
    rest: []const u8,

    pub fn next(self: *TokenIter) ?[]const u8 {
        var i: usize = 0;
        while (i < self.rest.len and isSpace(self.rest[i])) : (i += 1) {}
        self.rest = self.rest[i..];
        if (self.rest.len == 0) return null;
        var j: usize = 0;
        while (j < self.rest.len and !isSpace(self.rest[j])) : (j += 1) {}
        const tok = self.rest[0..j];
        self.rest = self.rest[j..];
        return tok;
    }

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\t';
    }
};

pub fn tokens() TokenIter {
    return .{ .rest = raw };
}

/// Returns the value half of a `key=value` token. Bare `key` tokens are ignored.
pub fn getValue(key: []const u8) ?[]const u8 {
    var it = tokens();
    while (it.next()) |tok| {
        if (tok.len <= key.len) continue;
        if (tok[key.len] != '=') continue;
        if (!std.mem.eql(u8, tok[0..key.len], key)) continue;
        return tok[key.len + 1 ..];
    }
    return null;
}
