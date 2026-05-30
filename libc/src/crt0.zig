//! C startup. Provides `_start` (naked, per-arch) that parses argc/argv
//! off the stack, builds a null-terminated `char **argv` for C
//! conventions, calls `extern fn main(int, char**) int`, then feeds the
//! return value to `_ferrite_exit`.
//!
//! `_start` is exported as **weak**: Zig uspace binaries that link the
//! zig-std overlay get their own strong `_start` from `start.zig` and
//! these weak ones get dropped. Pure C binaries (no Zig std) take the
//! crt0 path. Same for `_ferrite_exit`, provided weakly by libc/src/stubs
//! and strongly by libc/src/glue when the latter is linked in.

const builtin = @import("builtin");

const MAX_CARGV: usize = 64;

extern fn main(argc: c_int, argv: ?[*]?[*:0]const u8) callconv(.c) c_int;
extern fn _ferrite_exit(code: c_int) callconv(.c) noreturn;

comptime {
    @export(&_start, .{ .name = "_start", .linkage = .weak });
    @export(&ferriteCStartShim, .{ .name = "ferriteCStartShim", .linkage = .weak });
}

fn _start() callconv(.naked) noreturn {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\ ldr x0, [sp]
            \\ add x1, sp, #8
            \\ bl ferriteCStartShim
            \\ mov x8, #3
            \\ svc #0
            \\0: b 0b
        ),
        .riscv64 => asm volatile (
            \\ ld   a0, 0(sp)
            \\ addi a1, sp, 8
            \\ call ferriteCStartShim
            \\ li   a7, 3
            \\ ecall
            \\0: j 0b
        ),
        .riscv32 => asm volatile (
            \\ lw   a0, 0(sp)
            \\ addi a1, sp, 4
            \\ call ferriteCStartShim
            \\ li   a7, 3
            \\ ecall
            \\0: j 0b
        ),
        .x86_64 => asm volatile (
            \\ movq 0(%rsp), %rdi
            \\ leaq 8(%rsp), %rsi
            \\ call ferriteCStartShim
            \\ movq %rax, %rdi
            \\ movq $3, %rax
            \\ syscall
            \\0: jmp 0b
        ),
        .x86 => asm volatile (
            \\ movl 0(%esp), %eax
            \\ leal 4(%esp), %edx
            \\ pushl %edx
            \\ pushl %eax
            \\ call ferriteCStartShim
            \\ movl %eax, %ebx
            \\ movl $3, %eax
            \\ int $0x80
            \\0: jmp 0b
        ),
        else => @compileError("crt0: unsupported arch"),
    }
}

/// Argv buffer with a null terminator slot. Static so we don't grow the
/// startup stack. main captures its address and may keep argv pointers
/// around for the lifetime of the process.
var c_argv_storage: [MAX_CARGV + 1]?[*:0]const u8 = @splat(null);

fn ferriteCStartShim(argc: usize, argv_ptr: [*]const [*:0]const u8) callconv(.c) u64 {
    const n = @min(argc, MAX_CARGV);
    var i: usize = 0;
    while (i < n) : (i += 1) c_argv_storage[i] = argv_ptr[i];
    c_argv_storage[n] = null;

    const ret = main(@intCast(n), &c_argv_storage);
    _ferrite_exit(ret);
}
