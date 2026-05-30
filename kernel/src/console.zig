const arch = @import("arch");
const cpu = @import("cpu.zig");
const process = @import("process.zig");
const sched = @import("sched.zig");
const sync = @import("sync.zig");
const thread = @import("thread.zig");

var waiter: ?*thread.Thread = null;
/// Guards waiter against the RX IRQ; without it, a wake before `state=.blocked`
/// commits gets overwritten and is silently lost.
var waiter_lock: sync.Spinlock = .{};
/// Foreground process *group* id for the console tty (0 = none). Ctrl-C delivers
/// SIGINT to every process in this group, so a whole pipeline dies, not just one
/// stage. The shell sets this to each pipeline's group while it runs.
var foreground_pgid: u32 = 0;

inline fn irqSave() bool {
    const prev = arch.cpu.irqsEnabled();
    arch.cpu.disableIrq();
    return prev;
}

inline fn irqRestore(prev: bool) void {
    if (prev) arch.cpu.enableIrq();
}

pub fn init() void {
    arch.uart.rx_wake = &onRxBytes;
    arch.uart.enableRx();
}

fn onRxBytes() void {
    // Called from IRQ context, IRQs already disabled.
    waiter_lock.acquire();
    const w = waiter;
    waiter = null;
    waiter_lock.release();
    if (w) |t| sched.wake(t);
}

pub fn setForegroundGroup(pgid: u32) void {
    foreground_pgid = pgid;
}

/// Ctrl-C: deliver SIGINT to the whole foreground process group.
pub fn killForeground() void {
    if (foreground_pgid == 0) return;
    _ = process.signalGroup(foreground_pgid, process.SIGINT);
}

pub fn read(buf: []u8) usize {
    while (true) {
        const prev_irq = irqSave();
        waiter_lock.acquire();
        const n = arch.uart.tryRead(buf);
        if (n > 0) {
            waiter_lock.release();
            irqRestore(prev_irq);
            return n;
        }
        const cur = cpu.current() orelse {
            waiter_lock.release();
            irqRestore(prev_irq);
            return 0;
        };
        waiter = cur;
        // Atomic state=.blocked + release vs the RX-IRQ wake path.
        sched.blockReleasing(&waiter_lock);
        irqRestore(prev_irq);
    }
}
