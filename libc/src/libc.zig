// Userspace libc root. The comptime block forces each translation unit's
// `export fn`s to be emitted into libferrite_libc.a. The freestanding mem*
// exports live in mem.zig so the kernel can link just those without dragging
// in the userspace surface (glue/heap/time, which need ferrite_fs/syscall).

comptime {
    _ = @import("mem.zig");
    _ = @import("stubs.zig");
    _ = @import("crt0.zig");
    _ = @import("glue.zig");
    _ = @import("string.zig");
    _ = @import("stdio.zig");
    _ = @import("stdlib.zig");
    _ = @import("ctype.zig");
    _ = @import("time.zig");
    _ = @import("misc.zig");
    _ = @import("heap.zig");
}
