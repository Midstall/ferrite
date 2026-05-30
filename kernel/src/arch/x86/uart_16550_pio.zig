// 16550 UART over x86 PIO at COM1 (port 0x3F8).

const io = @import("io.zig");

const PORT: u16 = 0x3F8;

const LSR_THRE: u8 = 1 << 5;

inline fn inb(port: u16) u8 {
    return io.inb(port);
}

inline fn outb(port: u16, val: u8) void {
    io.outb(port, val);
}

pub fn putc(c: u8) void {
    while ((inb(PORT + 5) & LSR_THRE) == 0) {}
    outb(PORT, c);
}

pub fn write(s: []const u8) void {
    for (s) |c| putc(c);
}

fn writeDec(v: u64) void {
    if (v == 0) {
        putc('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var n = v;
    while (n > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    write(buf[i..]);
}

fn writeHex(v: u64, width: usize) void {
    const digits = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var i: usize = buf.len;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
    } else {
        var n = v;
        while (n > 0) {
            i -= 1;
            buf[i] = digits[@intCast(n & 0xf)];
            n >>= 4;
        }
    }
    var len = buf.len - i;
    while (len < width) : (len += 1) putc('0');
    write(buf[i..]);
}

inline fn comptimeEql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (a, b) |x, y| if (x != y) return false;
    return true;
}

inline fn emit(comptime spec: []const u8, arg: anytype) void {
    if (comptime comptimeEql(spec, "s")) {
        write(arg);
    } else if (comptime comptimeEql(spec, "d")) {
        writeDec(@intCast(arg));
    } else if (comptime spec.len >= 1 and spec[0] == 'x') {
        // {x} or {x:0>N}: parse trailing decimal digits of spec as the
        // zero-pad width (our only padded specs use 0>).
        const width = comptime blk: {
            var w: usize = 0;
            var mul: usize = 1;
            var k = spec.len;
            while (k > 0 and spec[k - 1] >= '0' and spec[k - 1] <= '9') {
                k -= 1;
                w += (spec[k] - '0') * mul;
                mul *= 10;
            }
            break :blk w;
        };
        writeHex(@intCast(arg), width);
    } else {
        write("?fmt?");
    }
}

// Minimal manual formatter. Supports {s} {d} {x} {x:0>N} (the only specifiers the
// kernel uses) plus literal {{ }}. Deliberately avoids std.fmt / std.Io.Writer:
// on the x86_64 kernel build an indirect call through the Writer vtable's `drain`
// (incl. the one std.fmt.bufPrint uses internally) disagrees with the call site
// on sret and faults early in boot ("incorrect alignment" safety panic) -- the
// same Zig 0.16 x86_64 bug zig-std works around in userspace. See
// ferrite-zig-io-writer-sret-bug. This formatter emits bytes via putc directly.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    comptime var ai: usize = 0;
    comptime var i: usize = 0;
    inline while (i < fmt.len) {
        if (fmt[i] == '{') {
            if (i + 1 < fmt.len and fmt[i + 1] == '{') {
                putc('{');
                i += 2;
                continue;
            }
            comptime var j = i + 1;
            inline while (j < fmt.len and fmt[j] != '}') j += 1;
            emit(fmt[i + 1 .. j], args[ai]);
            ai += 1;
            i = j + 1;
        } else if (fmt[i] == '}') {
            if (i + 1 < fmt.len and fmt[i + 1] == '}') putc('}');
            i += if (i + 1 < fmt.len and fmt[i + 1] == '}') 2 else 1;
        } else {
            putc(fmt[i]);
            i += 1;
        }
    }
}

pub var rx_wake: ?*const fn () void = null;

pub var rx_echo: bool = false;

pub fn enableRx() void {}

pub fn tryRead(_: []u8) usize {
    return 0;
}
