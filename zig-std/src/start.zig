//! Ferrite process entry point + main-dispatch shim.
//!
//! `_start` is exported via `@export(&std.os.ferrite.start._start, ...)`
//! in the patched `std/start.zig` (see patches/zig/<ver>/0003-start-ferrite-entry.patch).
//! The patch makes std/start.zig pick this entry up whenever our overlay
//! is active (`@hasDecl(std.os, "ferrite")`).
//!
//! `ferriteStartShim` needs an explicit linker name because the naked
//! `_start` references it via inline asm `bl ferriteStartShim`. The
//! comptime block below force-exports it with that name.

const builtin = @import("builtin");
const std = @import("std");
const root = @import("root");

comptime {
    if (@hasDecl(root, "main")) {
        @export(&ferriteStartShim, .{ .name = "ferriteStartShim", .linkage = .strong });
    }
}

pub fn _start() callconv(.naked) noreturn {
    // SYS_EXIT=3 hardcoded; renumbering breaks main's return path.
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\ ldr x0, [sp]
            \\ add x1, sp, #8
            \\ bl ferriteStartShim
            \\ mov x8, #3
            \\ svc #0
            \\0: b 0b
        ),
        .riscv64 => asm volatile (
            \\ ld   a0, 0(sp)
            \\ addi a1, sp, 8
            \\ call ferriteStartShim
            \\ li   a7, 3
            \\ ecall
            \\0: j 0b
        ),
        .riscv32 => asm volatile (
            \\ lw   a0, 0(sp)
            \\ addi a1, sp, 4
            \\ call ferriteStartShim
            \\ li   a7, 3
            \\ ecall
            \\0: j 0b
        ),
        .x86_64 => asm volatile (
            \\ movq 0(%rsp), %rdi
            \\ leaq 8(%rsp), %rsi
            \\ call ferriteStartShim
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
            \\ call ferriteStartShim
            \\ movl %eax, %ebx
            \\ movl $3, %eax
            \\ int $0x80
            \\0: jmp 0b
        ),
        else => @compileError("ferrite _start: unsupported arch"),
    }
}

pub fn ferriteStartShim(argc: usize, argv_ptr: [*]const [*:0]const u8) callconv(.c) u64 {
    std.os.ferrite.argv = argv_ptr[0..argc];

    const main_fn = root.main;
    const Ret = @typeInfo(@TypeOf(main_fn)).@"fn".return_type orelse void;

    return switch (@typeInfo(Ret)) {
        .void => blk: {
            main_fn();
            break :blk @as(u64, 0);
        },
        .int => blk: {
            const v = main_fn();
            break :blk @as(u64, @intCast(v));
        },
        .error_union => |eu| switch (@typeInfo(eu.payload)) {
            .void => blk: {
                main_fn() catch break :blk @as(u64, 1);
                break :blk @as(u64, 0);
            },
            .int => blk: {
                const v = main_fn() catch break :blk @as(u64, 1);
                break :blk @as(u64, @intCast(v));
            },
            else => @compileError("ferrite main: unsupported error-union payload"),
        },
        else => @compileError("ferrite main: unsupported return type"),
    };
}
