// Portable memory-ordering primitives for virtio drivers. Maps to the
// arch-native barrier instruction with the same semantics across kernels
// and userspace.

const builtin = @import("builtin");

/// Store-store ordering: prior plain stores must be visible to other agents
/// (including DMA) before any later store. Use after writing a virtio
/// descriptor ring entry but before bumping the index that publishes it.
pub inline fn storeStore() void {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("dmb st" ::: .{ .memory = true }),
        // RISC-V `fence w,w` orders writes-before-writes.
        .riscv32, .riscv64 => asm volatile ("fence w,w" ::: .{ .memory = true }),
        // x86 has TSO - plain stores are already release-ordered with
        // respect to other CPU stores. A compiler barrier is enough.
        .x86, .x86_64 => asm volatile ("" ::: .{ .memory = true }),
        else => @compileError("ferrite barrier: unsupported arch"),
    }
}

/// Full barrier (load+store, both directions). Use before an MMIO write
/// that must observe all prior data writes, or after a device read whose
/// data drives subsequent CPU work.
pub inline fn full() void {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("dmb sy" ::: .{ .memory = true }),
        .riscv32, .riscv64 => asm volatile ("fence rw,rw" ::: .{ .memory = true }),
        .x86, .x86_64 => asm volatile ("mfence" ::: .{ .memory = true }),
        else => @compileError("ferrite barrier: unsupported arch"),
    }
}
