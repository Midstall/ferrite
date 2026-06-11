// aarch64 CPU feature views for the cpufeatures policy layer.
//   detect()      - runtime, from the ID_AA64* feature registers.
//   comptimeSet() - build-time, from the -Dcpu/-mcpu target feature set.
const std = @import("std");
const builtin = @import("builtin");

// Common feature view shared with kernel/cpufeatures.zig. ?bool: null = "this
// view can't tell", true/false = known.
pub const Features = struct {
    fp: ?bool = null,
    simd: ?bool = null, // AdvSIMD/NEON on aarch64
    hypervisor: ?bool = null, // EL2 implemented
    atomics: ?bool = null, // large-system atomics (LSE)
    aes: ?bool = null,
    sha2: ?bool = null,
    crc32: ?bool = null,
    simd_wide: ?bool = null, // SVE
};

inline fn sysreg(comptime name: []const u8) u64 {
    return asm volatile ("mrs %[r], " ++ name
        : [r] "=r" (-> u64),
    );
}

// A 4-bit ID field of 0b1111 (0xF) means "not implemented" for FP/AdvSIMD;
// for the ISA fields a nonzero value means the feature is present.
pub fn detect() Features {
    const pfr0 = sysreg("ID_AA64PFR0_EL1");
    const isar0 = sysreg("ID_AA64ISAR0_EL1");
    return .{
        .fp = ((pfr0 >> 16) & 0xf) != 0xf,
        .simd = ((pfr0 >> 20) & 0xf) != 0xf,
        .hypervisor = ((pfr0 >> 8) & 0xf) != 0, // EL2 field
        .simd_wide = ((pfr0 >> 32) & 0xf) != 0, // SVE field
        .atomics = ((isar0 >> 20) & 0xf) != 0, // Atomic (LSE)
        .aes = ((isar0 >> 4) & 0xf) != 0,
        .sha2 = ((isar0 >> 12) & 0xf) != 0,
        .crc32 = ((isar0 >> 16) & 0xf) != 0,
    };
}

inline fn cpuHas(comptime f: std.Target.aarch64.Feature) bool {
    return std.Target.aarch64.featureSetHas(builtin.cpu.features, f);
}

pub fn comptimeSet() Features {
    return .{
        .fp = cpuHas(.fp_armv8),
        .simd = cpuHas(.neon),
        .atomics = cpuHas(.lse),
        .aes = cpuHas(.aes),
        .sha2 = cpuHas(.sha2),
        .crc32 = cpuHas(.crc),
        .simd_wide = cpuHas(.sve),
        // EL2 isn't a -Dcpu codegen feature; leave it to runtime detection.
        .hypervisor = null,
    };
}
