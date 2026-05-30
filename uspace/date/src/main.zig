// date [-u|--uptime|+ISO]
//   default:   read /sys/time/local
//   -u:        read /sys/time/utc and format as "YYYY-MM-DD HH:MM:SS UTC"
//   --uptime:  monotonic uptime (legacy behavior)

const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

pub fn main() void {
    const argv = ferrite.argv;
    var mode: enum { local, utc, uptime, iso } = .local;
    if (argv.len >= 2) {
        const a = std.mem.span(argv[1]);
        if (std.mem.eql(u8, a, "-u")) mode = .utc;
        if (std.mem.eql(u8, a, "--uptime")) mode = .uptime;
        if (std.mem.eql(u8, a, "--iso")) mode = .iso;
    }

    switch (mode) {
        .uptime => printUptime(),
        .local => streamPath("/sys/time/local"),
        .iso => streamPath("/sys/time/iso"),
        .utc => printUtc(),
    }
}

fn printUptime() void {
    const ns = ferrite.clockMono();
    const total_ms = ns / 1_000_000;
    const ms = total_ms % 1000;
    const total_s = total_ms / 1000;
    const s = total_s % 60;
    const total_m = total_s / 60;
    const m = total_m % 60;
    const h = total_m / 60;
    ferrite.console.print("up {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}\n", .{ h, m, s, ms }) catch {};
}

fn streamPath(path: []const u8) void {
    var uri_buf: [128]u8 = undefined;
    const uri = ferrite.fs.resolvePath(path, &uri_buf) catch return;
    var f = ferrite.fs.open(uri, .{ .mode = .read }) catch return;
    defer f.close();
    var buf: [128]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = f.read(off, &buf) catch break;
        if (n == 0) break;
        ferrite.console.writeAll(buf[0..n]) catch break;
        off += n;
    }
}

fn printUtc() void {
    var uri_buf: [128]u8 = undefined;
    const uri = ferrite.fs.resolvePath("/sys/time/utc", &uri_buf) catch return;
    var f = ferrite.fs.open(uri, .{ .mode = .read }) catch return;
    defer f.close();
    var buf: [32]u8 = undefined;
    const n = f.read(0, &buf) catch return;
    const view = std.mem.trim(u8, buf[0..n], " \t\r\n");
    const unix = std.fmt.parseInt(u64, view, 10) catch {
        ferrite.console.print("date: bad utc value: {s}\n", .{view}) catch {};
        return;
    };
    if (unix == 0) {
        ferrite.console.print("date: clock not set (run `ntpdate`)\n", .{}) catch {};
        return;
    }
    const date = civilFromDays(unix / 86_400);
    const sod = unix % 86_400;
    ferrite.console.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC\n", .{
        date.year, date.month, date.day, sod / 3600, (sod % 3600) / 60, sod % 60,
    }) catch {};
}

const Civil = struct { year: u32, month: u32, day: u32 };

fn civilFromDays(unix_days: u64) Civil {
    const z: i64 = @intCast(unix_days);
    const era_anchor: i64 = z + 719_468;
    const era: i64 = if (era_anchor >= 0) @divFloor(era_anchor, 146_097) else @divFloor(era_anchor - 146_096, 146_097);
    const doe: u64 = @intCast(era_anchor - era * 146_097);
    const yoe: u64 = (doe -% (doe / 1460) +% (doe / 36_524) -% (doe / 146_096)) / 365;
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const d: u64 = doy - (153 * mp + 2) / 5 + 1;
    const m: u64 = if (mp < 10) mp + 3 else mp - 9;
    const year: i64 = if (m <= 2) y + 1 else y;
    return .{ .year = @intCast(year), .month = @intCast(m), .day = @intCast(d) };
}
