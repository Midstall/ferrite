// wget <url>: HTTP/HTTPS via std.http.Client routed through the Ferrite
// std.Io backend. TLS goes through std.crypto.tls.Client; entropy comes
// from /dev/random, wall-clock from /sys/time/utc, CA roots from
// /etc/ssl/certs/ca-bundle.pem.

const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
pub const std_options_cwd = ferrite.io.cwdFn;

pub const os = struct {
    pub const PATH_MAX: usize = 4096;
    pub const NAME_MAX: usize = 255;
};

// 1 MiB arena: 320 KB for the parsed CA bundle, ~640 KB for std.http
// connection pool + TLS read/write buffers + redirect buffer.
var heap_buf: [1024 * 1024]u8 = undefined;

const CA_BUNDLE_PATH = "/etc/ssl/certs/ca-bundle.pem";

pub fn main() void {
    const argv = ferrite.argv;
    if (argv.len < 2) {
        ferrite.console.print("usage: wget <url>\n", .{}) catch {};
        return;
    }
    const url = std.mem.span(argv[1]);

    var fba = std.heap.FixedBufferAllocator.init(&heap_buf);
    const allocator = fba.allocator();

    var backend = ferrite.io.init();
    defer backend.deinit();
    const io = backend.io();

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    // std.http.Client's rescan path has no .ferrite arm and would leave
    // ca_bundle empty (every cert chain then fails to verify). Pre-load
    // the bundle ourselves and stamp `client.now` so the request flow
    // skips rescan altogether.
    const now = std.Io.Clock.real.now(io);
    client.ca_bundle.addCertsFromFilePathAbsolute(allocator, io, now, CA_BUNDLE_PATH) catch |e| {
        ferrite.console.print("wget: load CA bundle failed: {t}\n", .{e}) catch {};
        return;
    };
    client.now = now;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: std.Io.Writer = .{
        .vtable = &console_writer_vtable,
        .buffer = &stdout_buf,
    };
    defer stdout_writer.flush() catch {};

    var redirect_buf: [8 * 1024]u8 = undefined;

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &stdout_writer,
        .redirect_buffer = &redirect_buf,
    }) catch |e| {
        ferrite.console.print("wget: fetch failed: {t}\n", .{e}) catch {};
        return;
    };

    if (@intFromEnum(result.status) != 200) {
        ferrite.console.print("\nwget: HTTP {d}\n", .{@intFromEnum(result.status)}) catch {};
    }
}

const console_writer_vtable: std.Io.Writer.VTable = .{
    .drain = consoleDrain,
};

fn consoleDrain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    var total: usize = 0;
    if (io_w.end > 0) {
        ferrite.console.writeAll(io_w.buffer[0..io_w.end]) catch return error.WriteFailed;
        total += io_w.end;
        io_w.end = 0;
    }
    for (data, 0..) |chunk, i| {
        const reps: usize = if (i == data.len - 1 and splat > 0) splat else 1;
        var k: usize = 0;
        while (k < reps) : (k += 1) {
            ferrite.console.writeAll(chunk) catch return error.WriteFailed;
            total += chunk.len;
        }
    }
    return total;
}
