// NSS certdata.txt is a PKCS#11 attribute dump: CKO_CERTIFICATE rows carry the
// DER cert (MULTILINE_OCTAL), CKO_NSS_TRUST rows hold the trust posture for the
// same (label, serial). We emit only certs trusted as CKT_NSS_TRUSTED_DELEGATOR
// for server-auth.

const std = @import("std");
const Io = std.Io;
const common = @import("common");

const TRUSTED = "CKT_NSS_TRUSTED_DELEGATOR";

const Object = struct {
    class: []const u8 = "",
    label: []const u8 = "",
    serial: []u8 = &.{},
    value: []u8 = &.{},
    trust_server_auth: []const u8 = "",
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;
    if (args.len < 3) {
        common.stdoutPrint(io, "usage: {s} <certdata.txt> <out.pem>\n", .{args[0]});
        return error.BadUsage;
    }
    const in_path = args[1];
    const out_path = args[2];
    const cwd: Io.Dir = .cwd();

    const text = try common.readAll(arena, cwd, io, in_path);

    var certs: std.StringHashMap([]const u8) = .init(arena);
    var trusted: std.StringHashMap(void) = .init(arena);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var current = Object{};
    var have_obj = false;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "#")) {
            continue;
        }
        if (std.mem.eql(u8, line, "BEGINDATA")) {
            continue;
        }
        // MULTILINE_OCTAL block: header line, then `\nnn\nnn...` lines, then `END`.
        if (std.mem.indexOf(u8, line, "MULTILINE_OCTAL")) |_| {
            const key = firstToken(line);
            const bytes = try readMultilineOctal(arena, &lines);
            if (std.mem.eql(u8, key, "CKA_VALUE")) {
                current.value = bytes;
            } else if (std.mem.eql(u8, key, "CKA_SERIAL_NUMBER")) {
                current.serial = bytes;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "CKA_CLASS ")) {
            if (have_obj) try commit(arena, &certs, &trusted, current);
            current = .{};
            have_obj = true;
            current.class = thirdToken(line);
            continue;
        }

        if (std.mem.startsWith(u8, line, "CKA_LABEL UTF8 ")) {
            current.label = try arena.dupe(u8, unquote(line["CKA_LABEL UTF8 ".len..]));
            continue;
        }
        if (std.mem.startsWith(u8, line, "CKA_TRUST_SERVER_AUTH CK_TRUST ")) {
            current.trust_server_auth = thirdToken(line);
            continue;
        }
    }
    if (have_obj) try commit(arena, &certs, &trusted, current);

    var out: std.ArrayList(u8) = .empty;
    var it = certs.iterator();
    var emitted: usize = 0;
    while (it.next()) |entry| {
        if (!trusted.contains(entry.key_ptr.*)) continue;
        try writePem(arena, &out, entry.key_ptr.*, entry.value_ptr.*);
        emitted += 1;
    }
    try common.writeAll(cwd, io, out_path, out.items);
    common.stdoutPrint(io, "certdata2pem: emitted {d} trusted server-auth roots\n", .{emitted});
}

fn commit(
    arena: std.mem.Allocator,
    certs: *std.StringHashMap([]const u8),
    trusted: *std.StringHashMap(void),
    o: Object,
) !void {
    if (o.label.len == 0) return;
    const key = try std.fmt.allocPrint(arena, "{s}\x00{x}", .{ o.label, o.serial });
    if (std.mem.eql(u8, o.class, "CKO_CERTIFICATE") and o.value.len > 0) {
        try certs.put(key, o.value);
    } else if (std.mem.eql(u8, o.class, "CKO_NSS_TRUST") and std.mem.eql(u8, o.trust_server_auth, TRUSTED)) {
        try trusted.put(key, {});
    }
}

fn firstToken(line: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, line, ' ') orelse return line;
    return line[0..i];
}

fn thirdToken(line: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next();
    _ = it.next();
    return it.next() orelse "";
}

fn unquote(s: []const u8) []const u8 {
    var t = s;
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') t = t[1 .. t.len - 1];
    return t;
}

fn readMultilineOctal(arena: std.mem.Allocator, lines: *std.mem.SplitIterator(u8, .scalar)) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, " \t\r");
        if (std.mem.eql(u8, line, "END")) break;
        var i: usize = 0;
        while (i < line.len) {
            if (line[i] == '\\' and i + 3 < line.len) {
                const v = (octDigit(line[i + 1]) << 6) | (octDigit(line[i + 2]) << 3) | octDigit(line[i + 3]);
                try out.append(arena, @intCast(v));
                i += 4;
            } else {
                i += 1;
            }
        }
    }
    return out.toOwnedSlice(arena);
}

fn octDigit(c: u8) u8 {
    return if (c >= '0' and c <= '7') c - '0' else 0;
}

fn writePem(arena: std.mem.Allocator, out: *std.ArrayList(u8), label: []const u8, der: []const u8) !void {
    var hdr_buf: [512]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf, "# {s}\n-----BEGIN CERTIFICATE-----\n", .{label});
    try out.appendSlice(arena, hdr);
    const base64 = std.base64.standard.Encoder;
    const max_b64 = base64.calcSize(der.len);
    const buf = try arena.alloc(u8, max_b64);
    defer arena.free(buf);
    const encoded = base64.encode(buf, der);
    var i: usize = 0;
    while (i < encoded.len) : (i += 64) {
        const end = @min(i + 64, encoded.len);
        try out.appendSlice(arena, encoded[i..end]);
        try out.append(arena, '\n');
    }
    try out.appendSlice(arena, "-----END CERTIFICATE-----\n");
}
