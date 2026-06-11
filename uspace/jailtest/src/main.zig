// jailtest, a tiny program to validate the vmexec sandbox.
//
// Prints its argv, exercises proxied syscalls (uid, uname, clock, sleep), then
// the fs sentry: reads an allowed file and a denied one, reads a /dev submount,
// and tries to defeat the path filter with a hand-built URI. Exits with code 7.
// Run it sandboxed, e.g.:
//   vmexec --allow=write,getuid,uname,clock,sleep,fs --fs-allow=/etc,/dev jailtest
// Anything outside --allow / --fs-allow is refused by the policy; the program
// copes and still exits cleanly.
const std = @import("std");
const ferrite = std.os.ferrite;
const sys = ferrite.syscall;

pub const panic = ferrite.panic;

pub fn main() u8 {
    const argv = ferrite.argv;
    ferrite.console.print("jailtest: hello from inside the sandbox\n", .{}) catch {};
    ferrite.console.print("jailtest: argc = {d}\n", .{argv.len}) catch {};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        ferrite.console.print("  argv[{d}] = {s}\n", .{ i, std.mem.span(argv[i]) }) catch {};
    }

    ferrite.console.print("jailtest: uid = {d}\n", .{sys.getUid()}) catch {};

    var u: sys.UnameInfo = undefined;
    _ = sys.uname(&u);
    ferrite.console.print("jailtest: uname = {s}/{s}\n", .{ u.fieldSlice("name"), u.fieldSlice("arch") }) catch {};

    const t0 = sys.clockMono();
    sys.nanosleep(5_000_000); // 5 ms
    const t1 = sys.clockMono();
    ferrite.console.print("jailtest: slept ~5ms, mono delta = {d} ns\n", .{t1 -% t0}) catch {};

    // fs: read files through the gVisor-style sentry (needs --allow=fs). With
    // --fs-allow=/etc the first read is permitted and the second is refused.
    catFile("/etc/services");
    catFile("/bin/jailtest");
    readDev("/dev/initrd"); // a submount: devfs hands off the walk to the initrd driver
    bypassAttempt();

    return 7;
}

// Read from a /dev node: devfs redirects (walk_redirect) the walk to the driver's
// own service, so this only works if the sentry re-tags the submount and lets the
// post-redirect walk through.
fn readDev(path: []const u8) void {
    var uri_buf: [256]u8 = undefined;
    const uri = ferrite.fs.resolvePath(path, &uri_buf) catch |e| {
        ferrite.console.print("jailtest: {s}: resolve refused ({s})\n", .{ path, @errorName(e) }) catch {};
        return;
    };
    const file = ferrite.fs.open(uri, .{ .mode = .read }) catch |e| {
        ferrite.console.print("jailtest: {s}: open refused ({s})\n", .{ path, @errorName(e) }) catch {};
        return;
    };
    defer file.close();
    var b: [16]u8 = undefined;
    const n = file.read(0, &b) catch 0;
    ferrite.console.print("jailtest: {s}: read {d} bytes via submount redirect\n", .{ path, n }) catch {};
}

// Try to defeat the path filter by skipping resolvePath: learn the mount's
// authority from an ALLOWED path, then hand-build a URI for a DENIED path and
// open it directly. The sentry must still refuse it at the walk.
fn bypassAttempt() void {
    var ub: [256]u8 = undefined;
    const uri = ferrite.fs.resolvePath("/etc/services", &ub) catch return; // allowed
    const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return;
    // The URI is `authority@version:/path`; keep the `authority@version:` prefix
    // and swap in a DENIED path (it must start with `/` to parse).
    var bb: [256]u8 = undefined;
    const evil = std.fmt.bufPrint(&bb, "{s}:/bin/jailtest", .{uri[0..colon]}) catch return;
    if (ferrite.fs.open(evil, .{ .mode = .read })) |f| {
        f.close();
        ferrite.console.print("jailtest: BYPASS succeeded opening {s}: FILTER HOLE\n", .{evil}) catch {};
    } else |e| {
        ferrite.console.print("jailtest: hand-built URI for /bin blocked at walk ({s})\n", .{@errorName(e)}) catch {};
    }
}

fn catFile(path: []const u8) void {
    var uri_buf: [256]u8 = undefined;
    const uri = ferrite.fs.resolvePath(path, &uri_buf) catch |e| {
        ferrite.console.print("jailtest: {s}: resolve refused ({s})\n", .{ path, @errorName(e) }) catch {};
        return;
    };
    const file = ferrite.fs.open(uri, .{ .mode = .read }) catch |e| {
        ferrite.console.print("jailtest: {s}: open refused ({s})\n", .{ path, @errorName(e) }) catch {};
        return;
    };
    defer file.close();
    var buf: [128]u8 = undefined;
    const n = file.read(0, &buf) catch 0;
    var i: usize = 0;
    while (i < n and buf[i] != '\n') : (i += 1) {}
    ferrite.console.print("jailtest: {s}: read {d} bytes, first line: {s}\n", .{ path, n, buf[0..i] }) catch {};
}
