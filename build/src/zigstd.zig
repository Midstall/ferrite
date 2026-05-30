const std = @import("std");

/// Supported Zig versions for the std overlay. Each entry has a patch
/// directory under `patches/zig/<version>/` containing 0001-*.patch etc.
/// Patches are applied in alphabetical order via `patch -p1`.
const supported_zig_versions = [_][]const u8{
    "0.16.0",
};

pub fn buildLibDir(b: *std.Build) std.Build.LazyPath {
    const zig_lib_path = b.graph.zig_lib_directory.path orelse
        @panic("zig-std overlay needs a resolved zig lib path");

    // Pick the matching patch directory. Unknown versions get no patches
    // (the build will still try, but unpatched std bits like Io.File.Handle
    // being void will surface as compile errors in our overlay).
    const zig_version = std.fmt.allocPrint(
        b.allocator,
        "{f}",
        .{@import("builtin").zig_version},
    ) catch @panic("OOM");
    var matched: ?[]const u8 = null;
    for (supported_zig_versions) |v| {
        if (std.mem.eql(u8, v, zig_version)) {
            matched = v;
            break;
        }
    }

    const script =
        \\set -e
        \\OUT="$1"
        \\SRC="$2"
        \\PATCH_DIR="$3"
        \\FERRITE_SRC="$4"
        \\SYSCALL_SRC="$5"
        \\P9_SRC="$6"
        \\URI_SRC="$7"
        \\NS_SRC="$8"
        \\FS_SRC="$9"
        \\PROBE_SRC="${10}"
        \\PANIC_SRC="${11}"
        \\START_SRC="${12}"
        \\BARRIER_SRC="${13}"
        \\IO_SRC="${14}"
        \\SYSTEM_SRC="${15}"
        \\rm -rf "$OUT"
        \\mkdir -p "$OUT"
        \\cp -rL "$SRC"/. "$OUT"/
        \\chmod -R u+w "$OUT"
        \\# Apply std patches if we have a patch dir for this Zig version.
        \\# Patches use `a/lib/...` and `b/lib/...` headers, so cd into $OUT
        \\# and -p1 strips one prefix.
        \\if [ -n "$PATCH_DIR" ] && [ -d "$PATCH_DIR" ]; then
        \\  for p in "$PATCH_DIR"/*.patch; do
        \\    [ -f "$p" ] || continue
        \\    (cd "$OUT" && patch -p1 --no-backup-if-mismatch -i "$p")
        \\  done
        \\fi
        \\mkdir -p "$OUT/std/os/ferrite"
        \\cp "$FERRITE_SRC" "$OUT/std/os/ferrite.zig"
        \\cp "$SYSCALL_SRC" "$OUT/std/os/ferrite/syscall.zig"
        \\cp "$P9_SRC" "$OUT/std/os/ferrite/p9.zig"
        \\cp "$URI_SRC" "$OUT/std/os/ferrite/uri.zig"
        \\cp "$NS_SRC" "$OUT/std/os/ferrite/nameserver.zig"
        \\cp "$FS_SRC" "$OUT/std/os/ferrite/fs.zig"
        \\cp "$PROBE_SRC" "$OUT/std/os/ferrite/probe.zig"
        \\cp "$PANIC_SRC" "$OUT/std/os/ferrite/panic.zig"
        \\cp "$START_SRC" "$OUT/std/os/ferrite/start.zig"
        \\cp "$BARRIER_SRC" "$OUT/std/os/ferrite/barrier.zig"
        \\cp "$IO_SRC" "$OUT/std/os/ferrite/io.zig"
        \\cp "$SYSTEM_SRC" "$OUT/std/os/ferrite/system.zig"
        \\OS_ZIG="$OUT/std/os.zig"
        \\if ! grep -q 'pub const ferrite' "$OS_ZIG"; then
        \\  printf '\npub const ferrite = @import("os/ferrite.zig");\n' >> "$OS_ZIG"
        \\fi
    ;

    const run = b.addSystemCommand(&.{ "sh", "-c", script, "sh" });
    const lib = run.addOutputDirectoryArg("lib");
    run.addArg(zig_lib_path);
    if (matched) |v| {
        run.addDirectoryArg(b.path(b.fmt("patches/zig/{s}", .{v})));
    } else {
        run.addArg(""); // empty PATCH_DIR -> the loop in the script no-ops
    }
    run.addFileArg(b.path("zig-std/src/ferrite.zig"));
    run.addFileArg(b.path("zig-std/src/syscall.zig"));
    run.addFileArg(b.path("zig-std/src/p9.zig"));
    run.addFileArg(b.path("zig-std/src/uri.zig"));
    run.addFileArg(b.path("zig-std/src/nameserver.zig"));
    run.addFileArg(b.path("zig-std/src/fs.zig"));
    run.addFileArg(b.path("zig-std/src/probe.zig"));
    run.addFileArg(b.path("zig-std/src/panic.zig"));
    run.addFileArg(b.path("zig-std/src/start.zig"));
    run.addFileArg(b.path("zig-std/src/barrier.zig"));
    run.addFileArg(b.path("zig-std/src/io.zig"));
    run.addFileArg(b.path("zig-std/src/system.zig"));

    // addDirectoryArg does not content-hash the directory, so adding or
    // editing a patch would not invalidate this step's cache. Register each
    // patch as an explicit input. These are appended after the positional
    // args the script reads ($1..$15), so they only affect the cache key.
    // Sorted for a deterministic key.
    if (matched) |v| {
        const io = b.graph.io;
        const rel = b.fmt("patches/zig/{s}", .{v});
        var dir = b.build_root.handle.openDir(io, rel, .{ .iterate = true }) catch
            @panic("zig-std: cannot open patch dir");
        defer dir.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (it.next(io) catch @panic("zig-std: patch dir iterate failed")) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".patch"))
                names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, c: []const u8) bool {
                return std.mem.lessThan(u8, a, c);
            }
        }.lt);
        for (names.items) |n| run.addFileArg(b.path(b.fmt("{s}/{s}", .{ rel, n })));
    }

    return lib;
}

pub fn registerStep(b: *std.Build) void {
    const lib = buildLibDir(b);
    const install = b.addInstallDirectory(.{
        .source_dir = lib,
        .install_dir = .{ .custom = "zig-std" },
        .install_subdir = "lib",
    });
    const step = b.step("zig-std", "Install a Ferrite-patched Zig std at zig-out/zig-std/lib (pass to --zig-lib-dir)");
    step.dependOn(&install.step);
}
