const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const fs = ferrite.fs;

// evdev event types (Linux ABI, shared by virtio-input).
const EV_SYN: u16 = 0;
const EV_KEY: u16 = 1;
const EV_REL: u16 = 2;
const EV_ABS: u16 = 3;

const EV_SIZE: usize = 8;

pub fn main() void {
    printDevices();

    // Pick the event node: argv[1] if given (e.g. "event0"), else the first
    // device whose name mentions a keyboard, else event0.
    var node_buf: [16]u8 = undefined;
    const node = chooseNode(&node_buf);

    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/dev/input/{s}", .{node}) catch return;

    var uri_buf: [128]u8 = undefined;
    const uri = fs.resolvePath(path, &uri_buf) catch {
        ferrite.console.print("evtest: bad path: {s}\n", .{path}) catch {};
        return;
    };
    const file = fs.open(uri, .{ .mode = .read }) catch |e| {
        ferrite.console.print("evtest: open {s}: {t}\n", .{ path, e }) catch {};
        return;
    };
    defer file.close();

    ferrite.console.print("evtest: reading {s} (Ctrl-C to stop)\n", .{path}) catch {};

    var buf: [512]u8 = undefined;
    while (true) {
        const n = file.read(0, &buf) catch |e| {
            ferrite.console.print("evtest: read: {t}\n", .{e}) catch {};
            return;
        };
        if (n == 0) continue; // empty wake; keep waiting for input
        var off: usize = 0;
        while (off + EV_SIZE <= n) : (off += EV_SIZE) {
            const t = std.mem.readInt(u16, buf[off..][0..2], .little);
            const code = std.mem.readInt(u16, buf[off + 2 ..][0..2], .little);
            const value = std.mem.readInt(u32, buf[off + 4 ..][0..4], .little);
            printEvent(t, code, value);
        }
    }
}

fn printEvent(t: u16, code: u16, value: u32) void {
    const name = switch (t) {
        EV_SYN => "SYN",
        EV_KEY => "KEY",
        EV_REL => "REL",
        EV_ABS => "ABS",
        else => "?",
    };
    ferrite.console.print("{s} code={d} value={d}\n", .{ name, code, value }) catch {};
}

fn printDevices() void {
    var uri_buf: [128]u8 = undefined;
    const uri = fs.resolvePath("/dev/input/devices", &uri_buf) catch return;
    const file = fs.open(uri, .{ .mode = .read }) catch {
        ferrite.console.print("evtest: no /dev/input (is drv.virtio-input running?)\n", .{}) catch {};
        return;
    };
    defer file.close();
    var buf: [1024]u8 = undefined;
    const n = file.read(0, &buf) catch return;
    ferrite.console.print("evtest: devices:\n{s}", .{buf[0..n]}) catch {};
}

fn chooseNode(out: *[16]u8) []const u8 {
    const argv = ferrite.argv;
    if (argv.len >= 2) {
        const a = std.mem.span(argv[1]);
        const n = @min(a.len, out.len);
        @memcpy(out[0..n], a[0..n]);
        return out[0..n];
    }

    // Scan the devices file for a keyboard line: "eventN: <name>".
    var uri_buf: [128]u8 = undefined;
    const uri = fs.resolvePath("/dev/input/devices", &uri_buf) catch return defaultNode(out);
    const file = fs.open(uri, .{ .mode = .read }) catch return defaultNode(out);
    defer file.close();
    var buf: [1024]u8 = undefined;
    const n = file.read(0, &buf) catch return defaultNode(out);

    var it = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.mem.indexOf(u8, line[colon..], "eyboard") == null) continue;
        const name = line[0..colon];
        const k = @min(name.len, out.len);
        @memcpy(out[0..k], name[0..k]);
        return out[0..k];
    }
    return defaultNode(out);
}

fn defaultNode(out: *[16]u8) []const u8 {
    const d = "event0";
    @memcpy(out[0..d.len], d);
    return out[0..d.len];
}
