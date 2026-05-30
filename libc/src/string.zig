//! <string.h> and friends. mem*/str* primitives that have to match
//! the POSIX spec well enough to satisfy ported C code. The chunky
//! mem* trio (memcpy/memset/memmove) lives in libc.zig because it
//! needs `@disableIntrinsics` to keep LLVM from rewriting the byte
//! loop into a tail-call to itself.

const std = @import("std");

export fn strlen(s: [*:0]const u8) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {}
    return i;
}

export fn strnlen(s: [*]const u8, maxlen: usize) usize {
    var i: usize = 0;
    while (i < maxlen and s[i] != 0) : (i += 1) {}
    return i;
}

export fn strcmp(a: [*:0]const u8, b: [*:0]const u8) c_int {
    var i: usize = 0;
    while (a[i] != 0 and b[i] != 0) : (i += 1) {
        if (a[i] != b[i]) return if (a[i] < b[i]) -1 else 1;
    }
    if (a[i] == b[i]) return 0;
    return if (a[i] < b[i]) -1 else 1;
}

export fn strncmp(a: [*]const u8, b: [*]const u8, n: usize) c_int {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ca = a[i];
        const cb = b[i];
        if (ca != cb) return if (ca < cb) -1 else 1;
        if (ca == 0) return 0;
    }
    return 0;
}

export fn strcasecmp(a: [*:0]const u8, b: [*:0]const u8) c_int {
    var i: usize = 0;
    while (a[i] != 0 and b[i] != 0) : (i += 1) {
        const ca = toLowerByte(a[i]);
        const cb = toLowerByte(b[i]);
        if (ca != cb) return if (ca < cb) -1 else 1;
    }
    const ca = toLowerByte(a[i]);
    const cb = toLowerByte(b[i]);
    if (ca == cb) return 0;
    return if (ca < cb) -1 else 1;
}

export fn strncasecmp(a: [*]const u8, b: [*]const u8, n: usize) c_int {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ca = toLowerByte(a[i]);
        const cb = toLowerByte(b[i]);
        if (ca != cb) return if (ca < cb) -1 else 1;
        if (a[i] == 0) return 0;
    }
    return 0;
}

fn toLowerByte(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

export fn strcpy(dst: [*]u8, src: [*:0]const u8) [*]u8 {
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) dst[i] = src[i];
    dst[i] = 0;
    return dst;
}

export fn strncpy(dst: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    var i: usize = 0;
    while (i < n and src[i] != 0) : (i += 1) dst[i] = src[i];
    while (i < n) : (i += 1) dst[i] = 0;
    return dst;
}

export fn strcat(dst: [*:0]u8, src: [*:0]const u8) [*:0]u8 {
    var d: usize = 0;
    while (dst[d] != 0) : (d += 1) {}
    var s: usize = 0;
    while (src[s] != 0) : (s += 1) dst[d + s] = src[s];
    dst[d + s] = 0;
    return dst;
}

export fn strncat(dst: [*:0]u8, src: [*]const u8, n: usize) [*:0]u8 {
    var d: usize = 0;
    while (dst[d] != 0) : (d += 1) {}
    var s: usize = 0;
    while (s < n and src[s] != 0) : (s += 1) dst[d + s] = src[s];
    dst[d + s] = 0;
    return dst;
}

export fn strchr(s: [*:0]const u8, c: c_int) ?[*:0]const u8 {
    const target: u8 = @intCast(c & 0xff);
    var i: usize = 0;
    while (true) {
        if (s[i] == target) return s + i;
        if (s[i] == 0) return null;
        i += 1;
    }
}

export fn strrchr(s: [*:0]const u8, c: c_int) ?[*:0]const u8 {
    const target: u8 = @intCast(c & 0xff);
    var last: ?[*:0]const u8 = null;
    var i: usize = 0;
    while (true) {
        if (s[i] == target) last = s + i;
        if (s[i] == 0) return last;
        i += 1;
    }
}

export fn memchr(s: [*]const u8, c: c_int, n: usize) ?[*]const u8 {
    const target: u8 = @intCast(c & 0xff);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (s[i] == target) return s + i;
    }
    return null;
}

export fn strstr(hay: [*:0]const u8, needle: [*:0]const u8) ?[*:0]const u8 {
    if (needle[0] == 0) return hay;
    var i: usize = 0;
    while (hay[i] != 0) : (i += 1) {
        var j: usize = 0;
        while (needle[j] != 0 and hay[i + j] == needle[j]) : (j += 1) {}
        if (needle[j] == 0) return hay + i;
        if (hay[i + j] == 0) return null;
    }
    return null;
}

export fn strspn(s: [*:0]const u8, accept: [*:0]const u8) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        if (strchr(accept, @intCast(s[i])) == null) return i;
    }
    return i;
}

export fn strcspn(s: [*:0]const u8, reject: [*:0]const u8) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        if (strchr(reject, @intCast(s[i])) != null) return i;
    }
    return i;
}

export fn strpbrk(s: [*:0]const u8, accept: [*:0]const u8) ?[*:0]const u8 {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        if (strchr(accept, @intCast(s[i])) != null) return s + i;
    }
    return null;
}

/// strtok is stateful. POSIX uses a hidden static pointer. Single-
/// threaded for now; reentrant strtok_r below should be preferred.
var strtok_save: ?[*:0]u8 = null;

export fn strtok(s: ?[*:0]u8, delim: [*:0]const u8) ?[*:0]u8 {
    return strtok_r(s, delim, &strtok_save);
}

export fn strtok_r(s_in: ?[*:0]u8, delim: [*:0]const u8, saveptr: *?[*:0]u8) ?[*:0]u8 {
    var p = s_in orelse saveptr.* orelse return null;

    while (p[0] != 0 and strchr(delim, @intCast(p[0])) != null) p += 1;
    if (p[0] == 0) {
        saveptr.* = null;
        return null;
    }

    const tok = p;
    while (p[0] != 0 and strchr(delim, @intCast(p[0])) == null) p += 1;
    if (p[0] == 0) {
        saveptr.* = null;
    } else {
        p[0] = 0;
        saveptr.* = p + 1;
    }
    return tok;
}

// strdup allocates from malloc; the caller frees.
extern fn malloc(size: usize) ?*anyopaque;

export fn strdup(s: [*:0]const u8) ?[*:0]u8 {
    const len = strlen(s);
    const p = malloc(len + 1) orelse return null;
    const buf: [*]u8 = @ptrCast(p);
    var i: usize = 0;
    while (i < len) : (i += 1) buf[i] = s[i];
    buf[len] = 0;
    return @ptrCast(buf);
}

export fn strndup(s: [*]const u8, n: usize) ?[*:0]u8 {
    const len = strnlen(s, n);
    const p = malloc(len + 1) orelse return null;
    const buf: [*]u8 = @ptrCast(p);
    var i: usize = 0;
    while (i < len) : (i += 1) buf[i] = s[i];
    buf[len] = 0;
    return @ptrCast(buf);
}

export fn strerror(errnum: c_int) [*:0]const u8 {
    return switch (errnum) {
        0 => "Success",
        1 => "Operation not permitted",
        2 => "No such file or directory",
        9 => "Bad file descriptor",
        12 => "Out of memory",
        13 => "Permission denied",
        14 => "Bad address",
        17 => "File exists",
        20 => "Not a directory",
        21 => "Is a directory",
        22 => "Invalid argument",
        24 => "Too many open files",
        28 => "No space left on device",
        38 => "Function not implemented",
        else => "Unknown error",
    };
}
