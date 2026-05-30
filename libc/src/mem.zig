// Byte-loop mem* exports for boot paths linked without compiler_rt. @memcpy
// and friends would trip Debug-mode alignment/aliasing checks on valid C-ABI
// callers. This module has no dependencies so the kernel can pull in just
// these symbols without dragging in the userspace libc (glue/heap/time).
//
// Volatile pointers and `@disableIntrinsics()` keep LLVM from "optimizing"
// these byte loops back into calls to memset/memcpy/memmove, which would
// recurse infinitely (the symbol calling itself).

export fn memcpy(dst: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    @disableIntrinsics();
    const d: [*]volatile u8 = @ptrCast(dst);
    const s: [*]const volatile u8 = @ptrCast(src);
    var i: usize = 0;
    while (i < n) : (i += 1) d[i] = s[i];
    return dst;
}

export fn memset(dst: [*]u8, c: c_int, n: usize) [*]u8 {
    @disableIntrinsics();
    const b: u8 = @intCast(c & 0xff);
    const d: [*]volatile u8 = @ptrCast(dst);
    var i: usize = 0;
    while (i < n) : (i += 1) d[i] = b;
    return dst;
}

export fn memmove(dst: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    @disableIntrinsics();
    const d: [*]volatile u8 = @ptrCast(dst);
    const s: [*]const volatile u8 = @ptrCast(src);
    if (@intFromPtr(dst) < @intFromPtr(src)) {
        var i: usize = 0;
        while (i < n) : (i += 1) d[i] = s[i];
    } else {
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            d[i] = s[i];
        }
    }
    return dst;
}

export fn memcmp(a: [*]const u8, b: [*]const u8, n: usize) c_int {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return if (a[i] < b[i]) -1 else 1;
    }
    return 0;
}

export fn bcmp(a: [*]const u8, b: [*]const u8, n: usize) c_int {
    return memcmp(a, b, n);
}
