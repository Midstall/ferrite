// RISC-V CPU feature views for the cpufeatures policy layer.
//   detect()      - runtime, from the misa CSR (M-mode; Ferrite's riscv kernel
//                   runs in M-mode, so misa is accessible).
//   comptimeSet() - build-time, from the -Dcpu/-mcpu target feature set.
const std = @import("std");
const builtin = @import("builtin");

pub const Features = struct {
    fp: ?bool = null, // F/D extensions
    simd: ?bool = null, // V extension
    hypervisor: ?bool = null, // H extension
    atomics: ?bool = null, // A extension
    aes: ?bool = null, // scalar crypto isn't reported by misa
    sha2: ?bool = null,
    crc32: ?bool = null,
    simd_wide: ?bool = null, // V (same bit as simd)
};

fn misa() usize {
    return asm volatile ("csrr %[r], misa"
        : [r] "=r" (-> usize),
    );
}

// misa bit N corresponds to extension letter 'A'+N.
fn ext(m: usize, comptime letter: u8) bool {
    return (m >> (letter - 'A')) & 1 != 0;
}

pub fn detect() Features {
    const m = misa();
    return .{
        .fp = ext(m, 'F') or ext(m, 'D'),
        .simd = ext(m, 'V'),
        .hypervisor = ext(m, 'H'),
        .atomics = ext(m, 'A'),
        .simd_wide = ext(m, 'V'),
        // The scalar-crypto extensions aren't reflected in misa; leave to comptime.
        .aes = null,
        .sha2 = null,
        .crc32 = null,
    };
}

inline fn cpuHas(comptime f: std.Target.riscv.Feature) bool {
    return std.Target.riscv.featureSetHas(builtin.cpu.features, f);
}

pub fn comptimeSet() Features {
    return .{
        .fp = cpuHas(.f) or cpuHas(.d),
        .simd = cpuHas(.v),
        .atomics = cpuHas(.a),
        .simd_wide = cpuHas(.v),
        .aes = null,
        .sha2 = null,
        .crc32 = null,
        .hypervisor = null,
    };
}
