const std = @import("std");

/// Build the ferrite-libc module. Wires the Plan-9 fs client + syscall +
/// p9 helpers from zig-std/src/ as named module imports so glue.zig can
/// reach them without depending on the patched zig-std overlay.
pub fn buildModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const syscall_mod = b.createModule(.{
        .root_source_file = b.path("zig-std/src/syscall.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .single_threaded = true,
    });
    const p9_mod = b.createModule(.{
        .root_source_file = b.path("zig-std/src/p9.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .single_threaded = true,
    });
    const uri_mod = b.createModule(.{
        .root_source_file = b.path("zig-std/src/uri.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .single_threaded = true,
    });
    const fs_mod = b.createModule(.{
        .root_source_file = b.path("zig-std/src/fs.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .single_threaded = true,
    });
    // fs.zig imports p9, uri, syscall as relative paths; that works for
    // the zig-std overlay because they're copied to sibling locations,
    // but for the libc build we need explicit module imports.
    fs_mod.addImport("p9.zig", p9_mod);
    fs_mod.addImport("uri.zig", uri_mod);
    fs_mod.addImport("syscall.zig", syscall_mod);

    const mod = b.createModule(.{
        .root_source_file = b.path("libc/src/libc.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .single_threaded = true,
    });
    mod.addImport("ferrite_fs", fs_mod);
    mod.addImport("ferrite_syscall", syscall_mod);
    mod.addImport("ferrite_p9", p9_mod);

    // printf/sprintf/snprintf/fprintf live in C because Zig 0.16 stage2
    // disables @cVaArg on aarch64 (and likely other arches we target).
    // <stdarg.h> macros are compiler intrinsics that survive.
    const c_flags: []const []const u8 = &.{
        "-fPIC",
        "-fPIE",
        "-ffunction-sections",
        "-fdata-sections",
        "-fno-stack-protector",
        "-fno-strict-aliasing",
        "-O2",
    };
    // C sources need libc/include for sys/types.h (and friends) so the
    // ssize_t/off_t typedefs agree with what user code sees.
    mod.addIncludePath(b.path("libc/include"));
    mod.addCSourceFile(.{ .file = b.path("libc/src/printf.c"), .flags = c_flags });
    // FILE * layer (fopen/fclose/fread/fwrite/fgets/puts/putchar/etc.) +
    // the stdin/stdout/stderr globals. Defines `struct _FILE` that
    // printf.c forward-declares for fprintf.
    mod.addCSourceFile(.{ .file = b.path("libc/src/stdio_file.c"), .flags = c_flags });

    return mod;
}

pub fn buildLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = buildModule(b, target, optimize);
    return b.addLibrary(.{
        .name = "ferrite_libc",
        .linkage = .static,
        .root_module = mod,
        // x86_64-freestanding defaults to Zig's self-hosted backend, which
        // can't encode our soft-float/naked-fn/f128 code. Pin LLVM there.
        .use_llvm = if (target.result.cpu.arch == .x86_64) true else null,
    });
}

pub fn registerStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const lib = buildLibrary(b, target, optimize);

    const install_lib = b.addInstallArtifact(lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib" } },
    });

    // Mirror libc/include/ into the install prefix's include/ for
    // downstream consumers.
    const install_headers = b.addInstallDirectory(.{
        .source_dir = b.path("libc/include"),
        .install_dir = .header,
        .install_subdir = "",
    });

    // `zig build libc` builds AND installs (libferrite_libc.a + headers).
    // We deliberately do NOT hook into the default install step so that
    // the kernel `zig build install` doesn't pollute its prefix with
    // the libc artifact.
    const step = b.step("libc", "Build + install libferrite_libc.a and headers");
    step.dependOn(&install_lib.step);
    step.dependOn(&install_headers.step);
}
