//! <time.h>. Wall-clock from /sys/time/utc (the same anchor svc.ntp
//! writes), monotonic from syscall.clockMono. The calendar conversions
//! (gmtime/localtime/mktime/strftime) implement enough of the proleptic
//! Gregorian calendar to display dates after 1970-01-01; no leap-second
//! handling, no timezone DB integration (localtime is currently == UTC).

const std = @import("std");
const syscall = @import("ferrite_syscall");

const time_t = i64;
const suseconds_t = i64;
const clock_t = i64;

// CLOCK_REALTIME / CLOCK_MONOTONIC / CLOCK_BOOTTIME from Linux.
const CLOCK_REALTIME: c_int = 0;
const CLOCK_MONOTONIC: c_int = 1;
const CLOCK_PROCESS_CPUTIME_ID: c_int = 2;
const CLOCK_THREAD_CPUTIME_ID: c_int = 3;
const CLOCK_MONOTONIC_RAW: c_int = 4;
const CLOCK_BOOTTIME: c_int = 7;

const CLOCKS_PER_SEC: clock_t = 1_000_000;

const struct_timespec = extern struct {
    tv_sec: time_t,
    tv_nsec: i64,
};

const struct_timeval = extern struct {
    tv_sec: time_t,
    tv_usec: suseconds_t,
};

const struct_tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long = 0,
    tm_zone: ?[*:0]const u8 = null,
};

extern fn _ferrite_read(fd: c_int, buf: [*]u8, n: usize) callconv(.c) isize;
extern fn _ferrite_open(path: [*:0]const u8, flags: c_int, mode: c_int) callconv(.c) c_int;
extern fn _ferrite_close(fd: c_int) callconv(.c) c_int;

fn readWallClockSecs() time_t {
    var uri_buf: [128]u8 = undefined;
    const fs = @import("ferrite_fs");
    const uri = fs.resolvePath("/sys/time/utc", &uri_buf) catch return 0;
    var f = fs.open(uri, .{ .mode = .read }) catch return 0;
    defer f.close();
    var buf: [32]u8 = undefined;
    var got: usize = 0;
    while (got < buf.len) {
        const n = f.read(got, buf[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    const trimmed = std.mem.trim(u8, buf[0..got], " \t\r\n");
    const secs = std.fmt.parseInt(u64, trimmed, 10) catch return 0;
    return @intCast(secs);
}

export fn time(out_t: ?*time_t) callconv(.c) time_t {
    const secs = readWallClockSecs();
    if (out_t) |p| p.* = secs;
    return secs;
}

export fn gettimeofday(tv: ?*struct_timeval, tz: ?*anyopaque) callconv(.c) c_int {
    _ = tz;
    if (tv) |p| {
        p.tv_sec = readWallClockSecs();
        p.tv_usec = 0;
    }
    return 0;
}

export fn clock_gettime(clk: c_int, ts: ?*struct_timespec) callconv(.c) c_int {
    const t = ts orelse return -1;
    switch (clk) {
        CLOCK_REALTIME => {
            t.tv_sec = readWallClockSecs();
            t.tv_nsec = 0;
        },
        CLOCK_MONOTONIC, CLOCK_MONOTONIC_RAW, CLOCK_BOOTTIME, CLOCK_PROCESS_CPUTIME_ID, CLOCK_THREAD_CPUTIME_ID => {
            const ns: u64 = syscall.uptimeNs();
            t.tv_sec = @intCast(ns / std.time.ns_per_s);
            t.tv_nsec = @intCast(ns % std.time.ns_per_s);
        },
        else => return -1,
    }
    return 0;
}

export fn clock() callconv(.c) clock_t {
    // POSIX: CPU time used so far in CLOCKS_PER_SEC units. We don't
    // separate process CPU from wall time, so use uptime as an upper
    // bound. Good enough for benchmark-style elapsed-time prints.
    const ns: u64 = syscall.uptimeNs();
    return @intCast(ns / 1000);
}

// ---- Calendar conversions ----

const SECS_PER_MIN: time_t = 60;
const SECS_PER_HOUR: time_t = 3600;
const SECS_PER_DAY: time_t = 86400;
const DAYS_PER_4YR: time_t = 4 * 365 + 1;
const DAYS_PER_100YR: time_t = 100 * 365 + 24;
const DAYS_PER_400YR: time_t = 400 * 365 + 97;
const EPOCH_TO_2000: time_t = 946684800; // 2000-01-01 00:00:00 UTC

const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

fn isLeap(year: i64) bool {
    return @rem(year, 4) == 0 and (@rem(year, 100) != 0 or @rem(year, 400) == 0);
}

var tm_storage: struct_tm = .{
    .tm_sec = 0,
    .tm_min = 0,
    .tm_hour = 0,
    .tm_mday = 1,
    .tm_mon = 0,
    .tm_year = 70,
    .tm_wday = 4,
    .tm_yday = 0,
    .tm_isdst = 0,
};

export fn gmtime(t: ?*const time_t) callconv(.c) ?*struct_tm {
    const ts = t orelse return null;
    return gmtime_r(ts, &tm_storage);
}

export fn gmtime_r(t: *const time_t, out: *struct_tm) callconv(.c) ?*struct_tm {
    var secs = t.*;
    if (secs < 0) secs = 0;
    var days = @divFloor(secs, SECS_PER_DAY);
    const tod = @rem(secs, SECS_PER_DAY);
    out.tm_sec = @intCast(@rem(tod, SECS_PER_MIN));
    out.tm_min = @intCast(@rem(@divFloor(tod, SECS_PER_MIN), 60));
    out.tm_hour = @intCast(@divFloor(tod, SECS_PER_HOUR));
    // 1970-01-01 was a Thursday (wday=4).
    out.tm_wday = @intCast(@rem(days + 4, 7));

    // Walk year/month from the epoch.
    var year: i64 = 1970;
    while (true) {
        const ydays: i64 = if (isLeap(year)) 366 else 365;
        if (days < ydays) break;
        days -= ydays;
        year += 1;
    }
    out.tm_year = @intCast(year - 1900);
    out.tm_yday = @intCast(days);

    var month: i64 = 0;
    while (month < 12) : (month += 1) {
        var mdays: i64 = days_in_month[@as(usize, @intCast(month))];
        if (month == 1 and isLeap(year)) mdays += 1;
        if (days < mdays) break;
        days -= mdays;
    }
    out.tm_mon = @intCast(month);
    out.tm_mday = @intCast(days + 1);
    out.tm_isdst = 0;
    out.tm_gmtoff = 0;
    out.tm_zone = "UTC";
    return out;
}

export fn localtime(t: ?*const time_t) callconv(.c) ?*struct_tm {
    // No tzdata integration yet, so same as UTC.
    return gmtime(t);
}

export fn localtime_r(t: *const time_t, out: *struct_tm) callconv(.c) ?*struct_tm {
    return gmtime_r(t, out);
}

export fn mktime(tm: ?*struct_tm) callconv(.c) time_t {
    const t = tm orelse return -1;
    var year: i64 = @as(i64, t.tm_year) + 1900;
    var month: i64 = t.tm_mon;
    // Normalize month/year if month is out of [0,11].
    while (month < 0) {
        month += 12;
        year -= 1;
    }
    while (month >= 12) {
        month -= 12;
        year += 1;
    }

    var days: time_t = 0;
    var y: i64 = 1970;
    while (y < year) : (y += 1) {
        days += if (isLeap(y)) 366 else 365;
    }
    var m: i64 = 0;
    while (m < month) : (m += 1) {
        var md: i64 = days_in_month[@as(usize, @intCast(m))];
        if (m == 1 and isLeap(year)) md += 1;
        days += md;
    }
    days += @as(time_t, t.tm_mday) - 1;
    return days * SECS_PER_DAY +
        @as(time_t, t.tm_hour) * SECS_PER_HOUR +
        @as(time_t, t.tm_min) * SECS_PER_MIN +
        @as(time_t, t.tm_sec);
}

export fn difftime(end: time_t, start: time_t) callconv(.c) f64 {
    return @floatFromInt(end - start);
}

/// Minimal strftime supporting Y/m/d/H/M/S and %F (YYYY-MM-DD) / %T
/// (HH:MM:SS) shortcuts. Enough for log timestamps; extend later.
export fn strftime(
    buf: [*]u8,
    cap: usize,
    fmt: [*:0]const u8,
    tm: ?*const struct_tm,
) callconv(.c) usize {
    const t = tm orelse return 0;
    if (cap == 0) return 0;
    var i: usize = 0;
    var out: usize = 0;
    while (fmt[i] != 0) : (i += 1) {
        const c = fmt[i];
        if (c != '%') {
            if (out + 1 >= cap) return 0;
            buf[out] = c;
            out += 1;
            continue;
        }
        i += 1;
        const spec = fmt[i];
        if (spec == 0) break;
        var tmp_buf: [16]u8 = undefined;
        // Zig 0.16 std.fmt prints a leading `+` for signed integers
        // whenever a fill character is given (e.g. `{d:0>4}` → `+1970`),
        // so cast each field to an unsigned type before formatting.
        const year_u: u32 = @intCast(t.tm_year + 1900);
        const mon_u: u32 = @intCast(t.tm_mon + 1);
        const mday_u: u32 = @intCast(t.tm_mday);
        const hour_u: u32 = @intCast(t.tm_hour);
        const min_u: u32 = @intCast(t.tm_min);
        const sec_u: u32 = @intCast(t.tm_sec);
        const piece: []const u8 = switch (spec) {
            'Y' => std.fmt.bufPrint(&tmp_buf, "{d:0>4}", .{year_u}) catch break,
            'm' => std.fmt.bufPrint(&tmp_buf, "{d:0>2}", .{mon_u}) catch break,
            'd' => std.fmt.bufPrint(&tmp_buf, "{d:0>2}", .{mday_u}) catch break,
            'H' => std.fmt.bufPrint(&tmp_buf, "{d:0>2}", .{hour_u}) catch break,
            'M' => std.fmt.bufPrint(&tmp_buf, "{d:0>2}", .{min_u}) catch break,
            'S' => std.fmt.bufPrint(&tmp_buf, "{d:0>2}", .{sec_u}) catch break,
            'F' => std.fmt.bufPrint(&tmp_buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year_u, mon_u, mday_u }) catch break,
            'T' => std.fmt.bufPrint(&tmp_buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour_u, min_u, sec_u }) catch break,
            '%' => "%",
            else => {
                tmp_buf[0] = '%';
                tmp_buf[1] = spec;
                break;
            },
        };
        if (out + piece.len >= cap) return 0;
        for (piece) |b| {
            buf[out] = b;
            out += 1;
        }
    }
    buf[out] = 0;
    return out;
}
