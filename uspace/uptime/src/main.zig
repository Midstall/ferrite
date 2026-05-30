// uptime: "HH:MM:SS up Xh Ym, U users, load average: 1m 5m 15m"

const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

const con = &ferrite.console;

fn readFile(path: []const u8, buf: []u8) ?[]const u8 {
    var uri_buf: [256]u8 = undefined;
    const uri = ferrite.fs.resolvePath(path, &uri_buf) catch return null;
    const f = ferrite.fs.open(uri, .{ .mode = .read }) catch return null;
    defer f.close();
    const n = f.read(0, buf) catch return null;
    return buf[0..n];
}

fn writeTimeOfDay() void {
    var buf: [128]u8 = undefined;
    const local = readFile("/sys/time/local", &buf) orelse {
        con.print("--:--:--", .{}) catch {};
        return;
    };
    // /sys/time/local: "YYYY-MM-DD HH:MM:SS ABBR"
    if (local.len >= 19) {
        con.print("{s}", .{local[11..19]}) catch {};
    } else {
        con.print("{s}", .{local}) catch {};
    }
}

fn parseFirstFloat(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and s[i] != ' ' and s[i] != '\n') : (i += 1) {}
    return s[0..i];
}

pub fn main() void {
    writeTimeOfDay();
    con.print(" up ", .{}) catch {};

    const up_ns = ferrite.uptimeNs();
    const total_s = up_ns / 1_000_000_000;
    const days = total_s / 86_400;
    const hours = (total_s % 86_400) / 3600;
    const mins = (total_s % 3600) / 60;

    if (days > 0) {
        con.print("{d} day{s}, {d:0>2}:{d:0>2}", .{
            days,
            if (days == 1) "" else "s",
            hours,
            mins,
        }) catch {};
    } else if (hours > 0) {
        con.print("{d}:{d:0>2}", .{ hours, mins }) catch {};
    } else {
        con.print("{d} min", .{mins}) catch {};
    }

    // Sessions not tracked yet; svc.users only knows accounts.
    con.print(",  0 users,  load average: ", .{}) catch {};

    var lbuf: [128]u8 = undefined;
    const load_line = readFile("/proc/loadavg", &lbuf);
    if (load_line) |line| {
        // /proc/loadavg: "1m 5m 15m running/total last_pid"
        var it = std.mem.tokenizeAny(u8, line, " \t\n");
        var count: u32 = 0;
        while (it.next()) |tok| {
            if (count >= 3) break;
            if (count > 0) con.print(", ", .{}) catch {};
            con.print("{s}", .{tok}) catch {};
            count += 1;
        }
        if (count == 0) con.print("0.00, 0.00, 0.00", .{}) catch {};
    } else {
        con.print("0.00, 0.00, 0.00", .{}) catch {};
    }
    con.print("\n", .{}) catch {};
}
