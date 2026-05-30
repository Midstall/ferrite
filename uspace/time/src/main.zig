const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

const con = &ferrite.console;

fn printDuration(label: []const u8, ns: u64) void {
    const total_ms = ns / 1_000_000;
    const seconds = total_ms / 1000;
    const ms = total_ms % 1000;
    con.print("{s:<5} {d:>4}.{d:0>3}s\n", .{ label, seconds, ms }) catch {};
}

pub fn main() void {
    if (ferrite.argv.len < 2) {
        _ = con.writeAll("usage: time CMD [ARGS...]\n") catch {};
        return;
    }

    const prog = std.mem.span(ferrite.argv[1]);

    var path_buf: [256]u8 = undefined;
    const path = if (prog.len > 0 and prog[0] == '/')
        prog
    else
        std.fmt.bufPrint(&path_buf, "bin/{s}", .{prog}) catch {
            _ = con.writeAll("time: path too long\n") catch {};
            return;
        };

    var args_buf: [512]u8 = undefined;
    var args_len: usize = 0;
    var i: usize = 2;
    while (i < ferrite.argv.len) : (i += 1) {
        const arg = std.mem.span(ferrite.argv[i]);
        if (args_len + arg.len + 1 > args_buf.len) {
            _ = con.writeAll("time: argv too long\n") catch {};
            return;
        }
        @memcpy(args_buf[args_len..][0..arg.len], arg);
        args_len += arg.len;
        args_buf[args_len] = 0;
        args_len += 1;
    }

    const t0 = ferrite.clockMono();
    const child = ferrite.spawnArgs(path, args_buf[0..args_len]);
    if (child < 0) {
        con.print("time: spawn {s}: errno={d}\n", .{ prog, child }) catch {};
        return;
    }
    const handle: u32 = @intCast(child);

    // Capture pid before wait, since wait() doesn't return it and procStat needs it.
    const pid_or_err = ferrite.handlePid(handle);
    if (pid_or_err < 0) {
        con.print("time: handlePid: errno={d}\n", .{pid_or_err}) catch {};
        return;
    }
    const pid: u32 = @intCast(pid_or_err);

    // Poll for exit so procStat can snapshot before the destroying wait().
    while (true) {
        const t = ferrite.tryWait(handle);
        if (t == 1) break;
        if (t < 0) {
            con.print("time: tryWait: errno={d}\n", .{t}) catch {};
            return;
        }
        ferrite.yield();
    }
    var stat: ferrite.ProcStat = undefined;
    const rc = ferrite.procStat(pid, &stat);
    _ = ferrite.wait(handle);
    const t1 = ferrite.clockMono();
    if (rc < 0) {
        con.print("\ntime: procStat({d}): errno={d}\n", .{ pid, rc }) catch {};
        return;
    }

    _ = con.writeAll("\n") catch {};
    printDuration("real", t1 - t0);
    printDuration("user", stat.user_cpu_ns);
    printDuration("sys", stat.sys_cpu_ns);
}
