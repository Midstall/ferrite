//! <stdlib.h> beyond malloc/exit (those live in stubs.zig). atoi/strtol
//! family + bsearch + qsort. strtod is missing (needs proper float
//! parsing), deferred until something demands it.

const std = @import("std");

const ERANGE: c_int = 34;
const EINVAL: c_int = 22;

extern fn __errno_location() *c_int;

fn setErrno(v: c_int) void {
    __errno_location().* = v;
}

fn isspaceByte(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', 11, 12 => true,
        else => false,
    };
}

fn digitValue(c: u8, base: u32) ?u32 {
    const v: u32 = switch (c) {
        '0'...'9' => c - '0',
        'A'...'Z' => c - 'A' + 10,
        'a'...'z' => c - 'a' + 10,
        else => return null,
    };
    if (v >= base) return null;
    return v;
}

/// Shared core. Returns the magnitude + parsed flags. Caller applies
/// sign and clamps to the target type's range, setting errno on
/// overflow.
const ParseResult = struct {
    magnitude: u64,
    negative: bool,
    consumed: usize,
    overflow: bool,
};

fn parseInteger(s: [*]const u8, base_in: c_int) ParseResult {
    var i: usize = 0;
    while (isspaceByte(s[i])) i += 1;

    var negative = false;
    if (s[i] == '+' or s[i] == '-') {
        negative = s[i] == '-';
        i += 1;
    }

    var base: u32 = if (base_in == 0) 10 else @intCast(base_in);

    // Auto-detect base: 0x = 16, 0 = 8.
    if ((base_in == 0 or base_in == 16) and s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X')) {
        base = 16;
        i += 2;
    } else if (base_in == 0 and s[i] == '0') {
        base = 8;
        i += 1;
    }

    var value: u64 = 0;
    var overflow = false;
    var any_digits = false;
    while (true) {
        const d = digitValue(s[i], base) orelse break;
        any_digits = true;
        const new = value *% base + d;
        if (new < value) overflow = true;
        value = new;
        i += 1;
    }

    if (!any_digits) {
        // No digits → consumed counts no characters from the integer
        // portion; strtoX returns 0 and endptr unchanged.
        return .{ .magnitude = 0, .negative = false, .consumed = 0, .overflow = false };
    }

    return .{ .magnitude = value, .negative = negative, .consumed = i, .overflow = overflow };
}

fn writeEndptr(endptr: ?*?[*]const u8, s: [*]const u8, consumed: usize) void {
    if (endptr) |e| {
        e.* = if (consumed == 0) s else s + consumed;
    }
}

export fn strtol(nptr: [*]const u8, endptr: ?*?[*]const u8, base: c_int) callconv(.c) c_long {
    const r = parseInteger(nptr, base);
    writeEndptr(endptr, nptr, r.consumed);
    const c_long_max: u64 = @intCast(std.math.maxInt(c_long));
    const c_long_min_mag: u64 = @as(u64, c_long_max) + 1;
    if (r.overflow or (r.negative and r.magnitude > c_long_min_mag) or (!r.negative and r.magnitude > c_long_max)) {
        setErrno(ERANGE);
        return if (r.negative) std.math.minInt(c_long) else std.math.maxInt(c_long);
    }
    return if (r.negative)
        -@as(c_long, @intCast(r.magnitude))
    else
        @as(c_long, @intCast(r.magnitude));
}

export fn strtoll(nptr: [*]const u8, endptr: ?*?[*]const u8, base: c_int) callconv(.c) c_longlong {
    const r = parseInteger(nptr, base);
    writeEndptr(endptr, nptr, r.consumed);
    const ll_max: u64 = @intCast(std.math.maxInt(c_longlong));
    const ll_min_mag: u64 = @as(u64, ll_max) + 1;
    if (r.overflow or (r.negative and r.magnitude > ll_min_mag) or (!r.negative and r.magnitude > ll_max)) {
        setErrno(ERANGE);
        return if (r.negative) std.math.minInt(c_longlong) else std.math.maxInt(c_longlong);
    }
    return if (r.negative)
        -@as(c_longlong, @intCast(r.magnitude))
    else
        @as(c_longlong, @intCast(r.magnitude));
}

export fn strtoul(nptr: [*]const u8, endptr: ?*?[*]const u8, base: c_int) callconv(.c) c_ulong {
    const r = parseInteger(nptr, base);
    writeEndptr(endptr, nptr, r.consumed);
    const ulong_max: u64 = @intCast(std.math.maxInt(c_ulong));
    if (r.overflow or r.magnitude > ulong_max) {
        setErrno(ERANGE);
        return std.math.maxInt(c_ulong);
    }
    return if (r.negative)
        @as(c_ulong, @bitCast(-@as(c_long, @intCast(r.magnitude))))
    else
        @as(c_ulong, @intCast(r.magnitude));
}

export fn strtoull(nptr: [*]const u8, endptr: ?*?[*]const u8, base: c_int) callconv(.c) c_ulonglong {
    const r = parseInteger(nptr, base);
    writeEndptr(endptr, nptr, r.consumed);
    if (r.overflow) {
        setErrno(ERANGE);
        return std.math.maxInt(c_ulonglong);
    }
    return if (r.negative)
        @as(c_ulonglong, @bitCast(-@as(c_longlong, @intCast(r.magnitude))))
    else
        @as(c_ulonglong, @intCast(r.magnitude));
}

export fn atoi(s: [*]const u8) callconv(.c) c_int {
    const v = strtol(s, null, 10);
    if (v > std.math.maxInt(c_int)) return std.math.maxInt(c_int);
    if (v < std.math.minInt(c_int)) return std.math.minInt(c_int);
    return @intCast(v);
}

export fn atol(s: [*]const u8) callconv(.c) c_long {
    return strtol(s, null, 10);
}

export fn atoll(s: [*]const u8) callconv(.c) c_longlong {
    return strtoll(s, null, 10);
}

// ---- qsort / bsearch ----

const CompareFn = *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int;

export fn bsearch(
    key: ?*const anyopaque,
    base: [*]const u8,
    nmemb: usize,
    size: usize,
    compare: CompareFn,
) callconv(.c) ?*const anyopaque {
    if (nmemb == 0 or size == 0) return null;
    var lo: usize = 0;
    var hi: usize = nmemb;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const elem = base + mid * size;
        const cmp = compare(key, @ptrCast(elem));
        if (cmp == 0) return @ptrCast(elem);
        if (cmp < 0) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    return null;
}

/// qsort via simple insertion sort. O(n^2) but small code; fine for the
/// usage volume we expect from a Ferrite C program. Drop in a real
/// heap/quick sort if anyone profiles a hot qsort.
export fn qsort(
    base_in: [*]u8,
    nmemb: usize,
    size: usize,
    compare: CompareFn,
) callconv(.c) void {
    if (nmemb < 2 or size == 0) return;
    var tmp_buf: [256]u8 = undefined;
    const tmp: [*]u8 = if (size <= tmp_buf.len) &tmp_buf else return;

    var i: usize = 1;
    while (i < nmemb) : (i += 1) {
        var k: usize = 0;
        while (k < size) : (k += 1) tmp[k] = base_in[i * size + k];

        var j: usize = i;
        while (j > 0 and compare(@ptrCast(base_in + (j - 1) * size), @ptrCast(tmp)) > 0) {
            var k2: usize = 0;
            while (k2 < size) : (k2 += 1) {
                base_in[j * size + k2] = base_in[(j - 1) * size + k2];
            }
            j -= 1;
        }
        var k3: usize = 0;
        while (k3 < size) : (k3 += 1) base_in[j * size + k3] = tmp[k3];
    }
}

export fn abs(n: c_int) callconv(.c) c_int {
    return if (n < 0) -n else n;
}

export fn labs(n: c_long) callconv(.c) c_long {
    return if (n < 0) -n else n;
}

export fn llabs(n: c_longlong) callconv(.c) c_longlong {
    return if (n < 0) -n else n;
}

// getenv: we don't have envp plumbing through the kernel spawn ABI yet,
// so always return null. Programs that fall back to compile-time defaults
// keep working.
export fn getenv(name: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    _ = name;
    return null;
}
