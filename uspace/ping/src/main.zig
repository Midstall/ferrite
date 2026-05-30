const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

pub fn main() void {
    const argv = ferrite.argv;
    if (argv.len < 2) {
        ferrite.console.print("usage: ping <ipv4|ipv6|hostname>\n", .{}) catch {};
        return;
    }
    const arg = std.mem.span(argv[1]);

    var target_buf: [64]u8 = undefined;
    var target: []const u8 = arg;
    if (!isIpLiteral(arg)) {
        target = resolveDns(arg, &target_buf) orelse {
            ferrite.console.print("ping: cannot resolve {s}\n", .{arg}) catch {};
            return;
        };
    }

    var uri_buf: [128]u8 = undefined;
    const path = if (std.mem.indexOfScalar(u8, target, ':') != null) "/sys/net/icmp6" else "/sys/net/icmp4";
    const uri = ferrite.fs.resolvePath(path, &uri_buf) catch |e| {
        ferrite.console.print("ping: resolvePath: {t}\n", .{e}) catch {};
        return;
    };
    const f = ferrite.fs.open(uri, .{ .mode = .rdwr }) catch |e| {
        ferrite.console.print("ping: open: {t}\n", .{e}) catch {};
        return;
    };
    defer f.close();

    _ = f.writeAll(target) catch |e| {
        ferrite.console.print("ping: write: {t}\n", .{e}) catch {};
        return;
    };

    var reply: [256]u8 = undefined;
    var total: usize = 0;
    while (total < reply.len) {
        const n = f.read(total, reply[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    if (total == 0) {
        ferrite.console.print("ping: no reply\n", .{}) catch {};
        return;
    }
    // Kernel reply already starts with the IP; prefix the hostname if we resolved.
    if (target.ptr != arg.ptr) {
        ferrite.console.print("{s} ", .{arg}) catch {};
    }
    ferrite.console.writeAll(reply[0..total]) catch {};
}

/// IPv4: digits+dots with >=1 dot. IPv6: hex+colons with >=1 colon.
fn isIpLiteral(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.mem.indexOfScalar(u8, s, ':') != null) {
        for (s) |c| {
            const hex = (c >= '0' and c <= '9') or
                (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
            if (!hex and c != ':') return false;
        }
        return true;
    }
    if (std.mem.indexOfScalar(u8, s, '.') == null) return false;
    for (s) |c| {
        if (!(c >= '0' and c <= '9') and c != '.') return false;
    }
    return true;
}

/// Try A first, then AAAA (via `.6` suffix).
fn resolveDns(host: []const u8, out: []u8) ?[]const u8 {
    if (lookupOnce(host, "", out)) |ip| return ip;
    return lookupOnce(host, ".6", out);
}

fn lookupOnce(host: []const u8, suffix: []const u8, out: []u8) ?[]const u8 {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/sys/dns/{s}{s}", .{ host, suffix }) catch return null;

    var uri_buf: [256]u8 = undefined;
    const uri = ferrite.fs.resolvePath(path, &uri_buf) catch return null;
    const f = ferrite.fs.open(uri, .{ .mode = .read }) catch return null;
    defer f.close();

    var buf: [256]u8 = undefined;
    const n = f.read(0, &buf) catch return null;
    if (n == 0) return null;

    // svc.dns may return "rcode=3" / "timeout" instead of an IP, so filter.
    const first_line_end = std.mem.indexOfScalar(u8, buf[0..n], '\n') orelse n;
    const line = buf[0..first_line_end];
    if (line.len == 0) return null;
    if (!looksLikeIp(line)) return null;
    if (line.len > out.len) return null;
    @memcpy(out[0..line.len], line);
    return out[0..line.len];
}

fn looksLikeIp(s: []const u8) bool {
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or c == '.' or c == ':' or
            (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return s.len > 0;
}
