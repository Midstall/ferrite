const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

const LINE_MAX = 128;
const AUTH_URI = "com.midstall.ferrite.users@v0:/auth";

pub fn main() void {
    var uri_buf: [128]u8 = undefined;
    const tty_uri = ferrite.fs.resolvePath("/dev/tty0", &uri_buf) catch return;
    const tty = ferrite.fs.open(tty_uri, .{ .mode = .rdwr }) catch return;
    defer tty.close();

    while (true) {
        _ = tty.writeAll("\nlogin: ") catch {};
        var name_buf: [LINE_MAX]u8 = undefined;
        const name = readLine(&tty, &name_buf);
        if (name.len == 0) continue;

        _ = tty.writeAll("password: ") catch {};
        setEcho(false);
        var pass_buf: [LINE_MAX]u8 = undefined;
        const pass = readLine(&tty, &pass_buf);
        setEcho(true);
        _ = tty.writeAll("\n") catch {};

        if (authenticate(name, pass)) |uid| {
            if (ferrite.setUid(uid) != 0) {
                _ = tty.writeAll("login: setuid denied (missing authority)\n") catch {};
                return;
            }
            _ = tty.writeAll("\nwelcome\n") catch {};
            const child = ferrite.spawn("bin/sh");
            if (child < 0) {
                _ = tty.writeAll("login: failed to spawn sh\n") catch {};
                continue;
            }
            // The shell manages the tty foreground group per-pipeline (and isn't
            // itself foreground at its prompt, so Ctrl-C cancels the line instead
            // of killing the shell). login just waits for it.
            _ = ferrite.wait(@intCast(child));
            return;
        } else {
            _ = tty.writeAll("login incorrect\n") catch {};
        }
    }
}

fn readLine(tty: *const ferrite.fs.File, buf: []u8) []const u8 {
    var n: usize = 0;
    while (n < buf.len) {
        var one: [1]u8 = undefined;
        const got = tty.read(0, &one) catch return buf[0..n];
        if (got == 0) continue;
        if (one[0] == '\n' or one[0] == '\r') return buf[0..n];
        buf[n] = one[0];
        n += 1;
    }
    return buf[0..n];
}

fn setEcho(on: bool) void {
    const ctl = ferrite.fs.open("com.midstall.ferrite.devfs@v0:/tty0/ctl", .{ .mode = .write }) catch return;
    defer ctl.close();
    _ = ctl.writeAll(if (on) "echo on" else "echo off") catch {};
}

fn authenticate(name: []const u8, pass: []const u8) ?u32 {
    const file = ferrite.fs.open(AUTH_URI, .{ .mode = .rdwr }) catch return null;
    defer file.close();

    var msg: [LINE_MAX * 2 + 1]u8 = undefined;
    if (name.len + 1 + pass.len > msg.len) return null;
    @memcpy(msg[0..name.len], name);
    msg[name.len] = 0;
    @memcpy(msg[name.len + 1 ..][0..pass.len], pass);
    const total = name.len + 1 + pass.len;
    _ = file.writeAll(msg[0..total]) catch return null;

    var resp: [64]u8 = undefined;
    const n = file.read(0, &resp) catch return null;
    if (n == 0) return null;
    const view = std.mem.trim(u8, resp[0..n], " \r\n");
    if (view.len < 3 or !std.mem.startsWith(u8, view, "ok ")) return null;
    return std.fmt.parseUnsigned(u32, view[3..], 10) catch null;
}
