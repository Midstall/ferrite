// ip [link|addr|route|neigh]: iproute2-style reader over /sys/net.

const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

const Section = enum { all, link, addr, route, neigh };

pub fn main() void {
    const argv = ferrite.argv;
    const section: Section = if (argv.len < 2)
        .all
    else blk: {
        const sub = std.mem.span(argv[1]);
        if (std.mem.eql(u8, sub, "link")) break :blk .link;
        if (std.mem.eql(u8, sub, "addr") or std.mem.eql(u8, sub, "address")) break :blk .addr;
        if (std.mem.eql(u8, sub, "route")) break :blk .route;
        if (std.mem.eql(u8, sub, "neigh") or std.mem.eql(u8, sub, "neighbor")) break :blk .neigh;
        ferrite.console.print("usage: ip [link|addr|route|neigh]\n", .{}) catch {};
        return;
    };

    const iface = "eth0";

    if (section == .all or section == .link or section == .addr) {
        const mac = readLine("/sys/net", iface, "mac") orelse return;
        ferrite.console.print("{s}: link/ether {s}\n", .{ iface, mac.slice() }) catch {};
        if (section == .all or section == .addr) {
            if (readLine("/sys/net", iface, "addr")) |a| {
                ferrite.console.print("    inet {s}\n", .{a.slice()}) catch {};
            }
            if (readLine("/sys/net", iface, "addr6")) |a| {
                ferrite.console.print("    inet6 {s}\n", .{a.slice()}) catch {};
            }
        }
    }

    if (section == .all or section == .route) {
        if (readLine("/sys/net", iface, "gw")) |gw| {
            ferrite.console.print("default via {s} dev {s}\n", .{ gw.slice(), iface }) catch {};
        }
        if (readLine("/sys/net", iface, "gw6")) |gw| {
            ferrite.console.print("default via {s} dev {s} (inet6)\n", .{ gw.slice(), iface }) catch {};
        }
    }

    if (section == .all or section == .neigh) {
        if (readWhole("/sys/net", iface, "neigh")) |neigh| {
            ferrite.console.print("{s}", .{neigh.slice()}) catch {};
        }
        if (readWhole("/sys/net", iface, "neigh6")) |neigh| {
            ferrite.console.print("{s}", .{neigh.slice()}) catch {};
        }
    }
}

const Buf = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,
    fn slice(self: *const Buf) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn readLine(base: []const u8, iface: []const u8, leaf: []const u8) ?Buf {
    var out = readWhole(base, iface, leaf) orelse return null;
    if (out.len > 0 and out.bytes[out.len - 1] == '\n') out.len -= 1;
    return out;
}

fn readWhole(base: []const u8, iface: []const u8, leaf: []const u8) ?Buf {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{ base, iface, leaf }) catch return null;
    var uri_buf: [256]u8 = undefined;
    const uri = ferrite.fs.resolvePath(path, &uri_buf) catch return null;
    const f = ferrite.fs.open(uri, .{ .mode = .read }) catch return null;
    defer f.close();
    var out: Buf = .{};
    while (out.len < out.bytes.len) {
        const n = f.read(out.len, out.bytes[out.len..]) catch break;
        if (n == 0) break;
        out.len += n;
    }
    return out;
}
