// x86 (32- and 64-bit) CPU feature views for the cpufeatures policy layer.
//   detect()      - runtime, via CPUID.
//   comptimeSet() - build-time, from the -Dcpu/-mcpu target feature set.
const std = @import("std");
const builtin = @import("builtin");

pub const Features = struct {
    fp: ?bool = null, // x87 FPU
    simd: ?bool = null, // SSE2 on x86
    hypervisor: ?bool = null, // VMX (Intel VT-x)
    atomics: ?bool = null, // lock/cmpxchg (always on x86)
    aes: ?bool = null, // AES-NI
    sha2: ?bool = null,
    crc32: ?bool = null, // via SSE4.2
    simd_wide: ?bool = null, // AVX
};

const Cpuid = struct { eax: u32 = 0, ebx: u32 = 0, ecx: u32 = 0, edx: u32 = 0 };

fn cpuid(leaf: u32, sub: u32) Cpuid {
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [la] "{eax}" (leaf),
          [lc] "{ecx}" (sub),
    );
    return .{ .eax = a, .ebx = b, .ecx = c, .edx = d };
}

pub fn detect() Features {
    const max = cpuid(0, 0).eax;
    const r1 = cpuid(1, 0);
    const r7 = if (max >= 7) cpuid(7, 0) else Cpuid{};
    return .{
        .fp = (r1.edx & (1 << 0)) != 0, // x87 FPU on chip
        .simd = (r1.edx & (1 << 26)) != 0, // SSE2
        .hypervisor = (r1.ecx & (1 << 5)) != 0, // VMX
        .atomics = true, // x86 always has lock-prefixed atomics
        .aes = (r1.ecx & (1 << 25)) != 0, // AES-NI
        .crc32 = (r1.ecx & (1 << 20)) != 0, // SSE4.2
        .simd_wide = (r1.ecx & (1 << 28)) != 0, // AVX
        .sha2 = (r7.ebx & (1 << 29)) != 0, // SHA
    };
}

inline fn cpuHas(comptime f: std.Target.x86.Feature) bool {
    return std.Target.x86.featureSetHas(builtin.cpu.features, f);
}

pub fn comptimeSet() Features {
    return .{
        .fp = cpuHas(.x87),
        .simd = cpuHas(.sse2),
        .aes = cpuHas(.aes),
        .sha2 = cpuHas(.sha),
        .crc32 = cpuHas(.sse4_2),
        .simd_wide = cpuHas(.avx),
        .atomics = true,
        .hypervisor = null, // VMX isn't a -Dcpu codegen feature
    };
}
