// S-mode CPU feature views for the cpufeatures policy layer.
//
// Ferrite's Limine riscv64 build runs in S-mode, where `misa` (an M-mode CSR)
// is not readable: `csrr misa` from S-mode is an illegal instruction. So
// `detect()` reports "unknown" (all null) for every feature and the policy
// layer falls back to the build-time `-Dcpu` set. `comptimeSet()` reuses the
// shared riscv build-time view (the M-mode arch.zig uses the same one).
//
// This is the counterpart to riscv/features.zig, whose `detect()` reads misa and
// is therefore M-mode only.

const riscv = @import("riscv");

pub const Features = riscv.features.Features;

pub fn detect() Features {
    return .{};
}

pub fn comptimeSet() Features {
    return riscv.features.comptimeSet();
}
