// gfx-demo: ferrite-gpu smoke test. Connects to drv.virtio-gpu, draws a
// distinct gradient on every scanout (zero-copy shared buffers), sets a
// hardware cursor, then animates a box on display 0 while the cursor tracks
// it. Exercises the full client path: nameserver lookup, per-display buffer
// cap grant + mmap, draw, present-with-damage, and the cursor queue.

const std = @import("std");
const ferrite = std.os.ferrite;
const gpu = @import("ferrite-gpu");

pub const panic = ferrite.panic;

const MAX_DISPLAYS = 4;

fn paint(fb: *gpu.Buffer, disp: u32) void {
    const pitch = fb.stride / 4;
    var y: u32 = 0;
    while (y < fb.height) : (y += 1) {
        const g: u32 = (y * 255) / fb.height;
        var x: u32 = 0;
        while (x < fb.width) : (x += 1) {
            const r: u32 = (x * 255) / fb.width;
            // Distinct per display: display 0 is red/green, display 1 swaps to
            // green/blue, etc., so each scanout is visually identifiable.
            fb.pixels[y * pitch + x] = switch (disp) {
                0 => (r << 16) | (g << 8) | 0x40,
                1 => (g << 8) | r | 0x400000,
                else => (g << 16) | (r << 8) | (disp * 0x30),
            };
        }
    }
}

pub fn main() void {
    var dev: gpu.Device = blk: {
        var tries: u32 = 0;
        while (tries < 200) : (tries += 1) {
            if (gpu.Device.connect()) |d| break :blk d else |_| {}
            ferrite.nanosleep(50 * std.time.ns_per_ms);
        }
        ferrite.console.print("[gfx-demo] could not reach drv.virtio-gpu\n", .{}) catch {};
        return;
    };

    const count = dev.displayCount() catch 1;
    ferrite.console.print("[gfx-demo] {d} display(s)\n", .{count}) catch {};

    var fb0: ?gpu.Buffer = null;
    var d: u32 = 0;
    while (d < count and d < MAX_DISPLAYS) : (d += 1) {
        if (dev.displayInfo(d) == null) continue;
        var fb = dev.createBuffer(d, 0, 0) catch {
            ferrite.console.print("[gfx-demo] display {d}: createBuffer failed\n", .{d}) catch {};
            continue;
        };
        paint(&fb, d);
        dev.present(d, 0, 0, fb.width, fb.height) catch {};
        ferrite.console.print("[gfx-demo] display {d}: {d}x{d} drawn\n", .{ d, fb.width, fb.height }) catch {};
        if (d == 0) fb0 = fb;
    }

    // Hardware cursor: a small opaque white arrow on a transparent field.
    if (dev.createCursor()) |cur| {
        var cy: u32 = 0;
        while (cy < cur.height) : (cy += 1) {
            var cx: u32 = 0;
            while (cx < cur.width) : (cx += 1) {
                const on = cx <= cy and cy < 28 and cx < 20; // arrow-ish triangle
                cur.pixels[cy * (cur.stride / 4) + cx] = if (on) 0xFFFFFFFF else 0x00000000;
            }
        }
        if (dev.setCursor(0, 120, 120, 0, 0)) {
            ferrite.console.print("[gfx-demo] cursor shown\n", .{}) catch {};
        } else |_| {
            ferrite.console.print("[gfx-demo] setCursor failed\n", .{}) catch {};
        }
    } else |_| {
        ferrite.console.print("[gfx-demo] createCursor failed\n", .{}) catch {};
    }

    // Animate a box on display 0 with damage-rect presents; the cursor rides
    // along on top of it.
    var fb = fb0 orelse return;
    const pitch = fb.stride / 4;
    const box: u32 = 80;
    const by: u32 = if (fb.height > box) (fb.height - box) / 2 else 0;
    var bx: u32 = 0;
    var prev_bx: u32 = 0;
    var dir: i32 = 4;
    while (true) {
        const lo = @min(prev_bx, bx);
        const hi = @min(@max(prev_bx, bx) + box, fb.width);
        var ry: u32 = by;
        while (ry < by + box and ry < fb.height) : (ry += 1) {
            const g: u32 = (ry * 255) / fb.height;
            var rx: u32 = lo;
            while (rx < hi) : (rx += 1) {
                const inside = rx >= bx and rx < bx + box;
                const r: u32 = (rx * 255) / fb.width;
                fb.pixels[ry * pitch + rx] = if (inside) 0x00FFFFFF else (r << 16) | (g << 8) | 0x40;
            }
        }
        dev.present(0, lo, by, hi - lo, @min(box, fb.height - by)) catch {};
        dev.moveCursor(0, bx + box / 2, by + box / 2) catch {};

        prev_bx = bx;
        const nx: i32 = @as(i32, @intCast(bx)) + dir;
        if (nx <= 0) {
            bx = 0;
            dir = 4;
        } else if (@as(u32, @intCast(nx)) + box >= fb.width) {
            bx = fb.width - box;
            dir = -4;
        } else {
            bx = @intCast(nx);
        }
        ferrite.nanosleep(16 * std.time.ns_per_ms);
    }
}
