const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

const con = &ferrite.console;
const MAX_PROCS = 32;

fn formatKB(bytes: u64) struct { v: u64, unit: []const u8 } {
    if (bytes >= 1024 * 1024) return .{ .v = bytes / (1024 * 1024), .unit = "M" };
    if (bytes >= 1024) return .{ .v = bytes / 1024, .unit = "K" };
    return .{ .v = bytes, .unit = "B" };
}

fn formatMs(ns: u64) u64 {
    return ns / 1_000_000;
}

pub fn main() void {
    var entries: [MAX_PROCS]ferrite.ProcEntry = undefined;
    const n = ferrite.procList(entries[0..]);

    con.print(
        "{s:>4} {s:>3} {s:>1} {s:>9} {s:>9} {s:>6} {s:>6} {s:>6} {s}\n",
        .{ "PID", "THR", "S", "USER(ms)", "SYS(ms)", "RSS", "KSTK", "KMEM", "NAME" },
    ) catch {};

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e = &entries[i];
        var st: ferrite.ProcStat = undefined;
        if (ferrite.procStat(e.pid, &st) != 0) continue;
        const rss = formatKB(st.rss_bytes);
        const kstk = formatKB(st.kstack_bytes);
        const kmem = formatKB(st.kmem_bytes);
        const state_ch: []const u8 = if (st.state == 0) "Z" else "R";
        con.print(
            "{d:>4} {d:>3} {s:>1} {d:>9} {d:>9} {d:>5}{s} {d:>5}{s} {d:>5}{s} {s}\n",
            .{
                st.pid,
                st.num_threads,
                state_ch,
                formatMs(st.user_cpu_ns),
                formatMs(st.sys_cpu_ns),
                rss.v,
                rss.unit,
                kstk.v,
                kstk.unit,
                kmem.v,
                kmem.unit,
                st.nameSlice(),
            },
        ) catch {};
    }
}
