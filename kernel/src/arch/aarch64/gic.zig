const arch_options = @import("arch-options");
const v2 = @import("gic/v2.zig");
const v3 = @import("gic/v3.zig");

var detected: Detected = .v2;

const Detected = enum { v2, v3 };

// ID_AA64PFR0_EL1.GIC[27:24] is the safe probe; reading past GICD's 4 KB
// register file faults on v2.
fn probe() Detected {
    var pfr0: u64 = undefined;
    asm volatile ("mrs %[r], id_aa64pfr0_el1"
        : [r] "=r" (pfr0),
    );
    const gic_field = (pfr0 >> 24) & 0xF;
    return if (gic_field >= 1) .v3 else .v2;
}

/// Point both GIC drivers at discovered MMIO bases (DT reg order: bases[0] =
/// distributor, bases[1] = CPU interface (v2) / redistributor (v3)). Must run
/// before init(); the version is not probed yet, so both drivers are seeded and
/// only the active one is used. A short list (no second window) is ignored, so
/// the compiled-in defaults stand.
pub fn setBases(bases: []const u64) void {
    if (bases.len < 2) return;
    const dist: usize = @intCast(bases[0]);
    const second: usize = @intCast(bases[1]);
    v2.setBases(dist, second);
    v3.setBases(dist, second);
}

pub fn init() void {
    switch (arch_options.gic_version) {
        .v2 => v2.init(),
        .v3 => v3.init(),
        .auto => {
            detected = probe();
            switch (detected) {
                .v2 => v2.init(),
                .v3 => v3.init(),
            }
        },
    }
}

// Per-CPU init: each CPU enables its own CPU interface (v2) / redistributor +
// ICC sysregs (v3). The boot CPU runs this via init(); secondaries call it.
pub fn initCpu(cpu_index: u32) void {
    switch (arch_options.gic_version) {
        .v2 => v2.initCpu(cpu_index),
        .v3 => v3.initCpu(cpu_index),
        .auto => switch (detected) {
            .v2 => v2.initCpu(cpu_index),
            .v3 => v3.initCpu(cpu_index),
        },
    }
}

pub fn enableIrq(irq: u32) void {
    switch (arch_options.gic_version) {
        .v2 => v2.enableIrq(irq),
        .v3 => v3.enableIrq(irq),
        .auto => switch (detected) {
            .v2 => v2.enableIrq(irq),
            .v3 => v3.enableIrq(irq),
        },
    }
}

// Enable/prioritize a per-CPU interrupt (PPI/SGI) on a specific CPU.
pub fn enableIrqCpu(cpu_index: u32, irq: u32) void {
    switch (arch_options.gic_version) {
        .v2 => v2.enableIrqCpu(cpu_index, irq),
        .v3 => v3.enableIrqCpu(cpu_index, irq),
        .auto => switch (detected) {
            .v2 => v2.enableIrqCpu(cpu_index, irq),
            .v3 => v3.enableIrqCpu(cpu_index, irq),
        },
    }
}

pub fn setPriorityCpu(cpu_index: u32, irq: u32, prio: u8) void {
    switch (arch_options.gic_version) {
        .v2 => v2.setPriorityCpu(cpu_index, irq, prio),
        .v3 => v3.setPriorityCpu(cpu_index, irq, prio),
        .auto => switch (detected) {
            .v2 => v2.setPriorityCpu(cpu_index, irq, prio),
            .v3 => v3.setPriorityCpu(cpu_index, irq, prio),
        },
    }
}

pub fn disableIrq(irq: u32) void {
    switch (arch_options.gic_version) {
        .v2 => v2.disableIrq(irq),
        .v3 => v3.disableIrq(irq),
        .auto => switch (detected) {
            .v2 => v2.disableIrq(irq),
            .v3 => v3.disableIrq(irq),
        },
    }
}

pub fn setPriority(irq: u32, prio: u8) void {
    switch (arch_options.gic_version) {
        .v2 => v2.setPriority(irq, prio),
        .v3 => v3.setPriority(irq, prio),
        .auto => switch (detected) {
            .v2 => v2.setPriority(irq, prio),
            .v3 => v3.setPriority(irq, prio),
        },
    }
}

pub fn acknowledge() u32 {
    return switch (arch_options.gic_version) {
        .v2 => v2.acknowledge(),
        .v3 => v3.acknowledge(),
        .auto => switch (detected) {
            .v2 => v2.acknowledge(),
            .v3 => v3.acknowledge(),
        },
    };
}

pub fn endOfInterrupt(iar: u32) void {
    switch (arch_options.gic_version) {
        .v2 => v2.endOfInterrupt(iar),
        .v3 => v3.endOfInterrupt(iar),
        .auto => switch (detected) {
            .v2 => v2.endOfInterrupt(iar),
            .v3 => v3.endOfInterrupt(iar),
        },
    }
}
