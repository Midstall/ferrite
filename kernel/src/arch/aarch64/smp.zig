pub const MAX_CPUS: usize = 32;

pub const SecondaryInit = extern struct {
    stack_top: u64 = 0,
    cpu_id: u32 = 0,
    _pad: u32 = 0,
};

pub export var inits: [MAX_CPUS]SecondaryInit = @splat(.{});

// Filled in by start.zig's bringUpSecondaries() (which has the `kernel` import
// for DTB/cpu/heap). The actual PSCI CPU_ON is deferred to startSecondaries(),
// called from kmain only AFTER the boot CPU is fully initialized -- otherwise a
// secondary would run scheduler/timer code against half-initialized global state
// and hang the boot.
pub var pending_mpidr: [MAX_CPUS]u64 = @splat(0);
/// Secondary CPU ids 1..=pending_count are provisioned and ready to start.
pub var pending_count: u32 = 0;

const psci = @import("psci.zig");
const uart = @import("uart_pl011.zig");

extern fn _start_secondary() callconv(.naked) void;

pub fn bringUpPsci(cpu_id: u32, target_mpidr: u64) bool {
    return psci.cpuOn(target_mpidr, @intFromPtr(&_start_secondary), cpu_id) == 0;
}

// PSCI-start every provisioned secondary. Needs no `kernel` import (just the
// stored mpidrs), so kmain can call it directly once the system is up.
pub fn startSecondaries() void {
    var id: u32 = 1;
    while (id <= pending_count) : (id += 1) {
        if (!bringUpPsci(id, pending_mpidr[id])) {
            uart.print("[boot] PSCI rejected id={d} mpidr=0x{x}\n", .{ id, pending_mpidr[id] });
        }
    }
}
