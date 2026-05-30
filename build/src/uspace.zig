const std = @import("std");
const common = @import("common.zig");
const zigstd = @import("zigstd.zig");
const libc_mod = @import("libc.zig");
const tools_mod = @import("tools.zig");

fn uspaceTarget(board: common.Board) std.Target.Query {
    return switch (board) {
        .@"qemu-virt-aarch64" => .{
            .cpu_arch = .aarch64,
            .os_tag = .freestanding,
            .abi = .none,
            // neon+sha2 required: std sha2 SIMD path traps under ubsan without them.
            .cpu_features_add = std.Target.aarch64.featureSet(&.{ .neon, .crypto, .sha2 }),
        },
        .@"qemu-virt-riscv64" => .{
            .cpu_arch = .riscv64,
            .os_tag = .freestanding,
            .abi = .none,
            .cpu_model = .baseline,
        },
        .@"qemu-pc-i386" => .{
            .cpu_arch = .x86,
            .os_tag = .freestanding,
            .abi = .none,
            .cpu_model = .baseline,
            // SSE/x87 lowering needs CR4.OSFXSR; we leave that unset in userspace.
            .cpu_features_sub = std.Target.x86.featureSet(&.{
                .mmx,   .sse,    .sse2,   .sse3,
                .ssse3, .sse4_1, .sse4_2, .sse4a,
                .avx,   .avx2,   .x87,
            }),
            .cpu_features_add = std.Target.x86.featureSet(&.{.soft_float}),
        },
        .@"qemu-pc-x86_64" => .{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
            .abi = .none,
            .cpu_model = .baseline,
            .cpu_features_sub = std.Target.x86.featureSet(&.{
                .mmx,   .sse,    .sse2,   .sse3,
                .ssse3, .sse4_1, .sse4_2, .sse4a,
                .avx,   .avx2,   .x87,
            }),
            .cpu_features_add = std.Target.x86.featureSet(&.{.soft_float}),
        },
        .@"esp32-c6" => .{
            .cpu_arch = .riscv32,
            .os_tag = .freestanding,
            .abi = .none,
            // ESP32-C6 HP core is rv32imac_zicsr_zifencei (no float, no
            // compressed FP). Pick the closest LLVM cpu_model.
            .cpu_model = .{ .explicit = &std.Target.riscv.cpu.baseline_rv32 },
        },
    };
}

const Bin = struct {
    name: []const u8,
    src: []const u8,
    authority: []const u8,
    binds: []const []const u8 = &.{},
    /// Make `@import("ferrite-gpu")` (lib/gpu) available to this binary.
    gpu: bool = false,
    /// Make `@import("ferrite-audio")` (lib/audio) available to this binary.
    audio: bool = false,
};

const Built = struct {
    macho: std.Build.LazyPath,
};

fn uspacePageSize(arch: std.Target.Cpu.Arch) u64 {
    // Must match the kernel's mmu page granule for this target so the
    // loader's per-page mapping doesn't overlap and clobber R+X TEXT with
    // later R+W DATA. zig ld.lld already spaces aarch64 PT_LOADs by 0x10000
    // (the largest aarch64 granule), so picking 64 KB here keeps elf2macho
    // identity-compatible with 4 K, 16 K, and 64 K kernel granules. Other
    // arches lay PT_LOADs out by 4 K, so 4 K is the only safe alignment.
    return switch (arch) {
        .aarch64 => 0x10000,
        .x86, .x86_64, .riscv64, .riscv32 => 0x1000,
        else => 0x1000,
    };
}

fn buildBin(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ferrite_lib: std.Build.LazyPath,
    elf2macho: *std.Build.Step.Compile,
    dev_key: std.Build.LazyPath,
    spec: Bin,
) Built {
    const mod = b.createModule(.{
        .root_source_file = b.path(spec.src),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .single_threaded = true,
    });
    if (spec.gpu) {
        const gpu_mod = b.createModule(.{
            .root_source_file = b.path("lib/gpu/gpu.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
            .single_threaded = true,
        });
        mod.addImport("ferrite-gpu", gpu_mod);
    }
    if (spec.audio) {
        const audio_mod = b.createModule(.{
            .root_source_file = b.path("lib/audio/audio.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
            .single_threaded = true,
        });
        mod.addImport("ferrite-audio", audio_mod);
    }
    const exe = b.addExecutable(.{
        .name = spec.name,
        .root_module = mod,
        // x86_64-freestanding defaults to Zig's self-hosted backend, which
        // can't encode our soft-float/naked-fn/f128 code. Pin LLVM there.
        .use_llvm = if (target.result.cpu.arch == .x86_64) true else null,
    });
    exe.entry = .{ .symbol_name = "_start" };
    exe.pie = true;
    exe.link_function_sections = true;
    exe.link_data_sections = true;
    exe.zig_lib_dir = ferrite_lib;
    ferrite_lib.addStepDependencies(&exe.step);

    const wrap = b.addRunArtifact(elf2macho);
    wrap.addArg(b.fmt("--page-size={d}", .{uspacePageSize(target.result.cpu.arch)}));
    for (spec.binds) |bind| {
        wrap.addArg(b.fmt("--bind={s}", .{bind}));
    }
    wrap.addArg(b.fmt("--authority={s}", .{spec.authority}));
    wrap.addFileArg(dev_key);
    wrap.addFileArg(exe.getEmittedBin());
    const macho = wrap.addOutputFileArg(b.fmt("{s}.macho", .{spec.name}));

    return .{ .macho = macho };
}

/// C uspace binary spec. Sources are .c files; everything else lines up
/// with the Zig binary recipe.
const BinC = struct {
    name: []const u8,
    src: []const u8,
    authority: []const u8,
    binds: []const []const u8 = &.{},
    extra_includes: []const []const u8 = &.{},
};

/// Compile a C source file into a Ferrite Mach-O. Uses zig cc under the
/// hood with -nostdlib + our libferrite_libc.a; the libc's weak `_start`
/// in crt0.zig is the entry point.
fn buildBinC(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libc_lib: *std.Build.Step.Compile,
    elf2macho: *std.Build.Step.Compile,
    dev_key: std.Build.LazyPath,
    spec: BinC,
) Built {
    const mod = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
        .pic = true,
        .single_threaded = true,
        .link_libc = false,
    });
    mod.addCSourceFile(.{
        .file = b.path(spec.src),
        .flags = &.{
            "-fPIC",
            "-fPIE",
            "-ffunction-sections",
            "-fdata-sections",
            "-fno-stack-protector",
            "-fno-strict-aliasing",
        },
    });
    mod.addIncludePath(b.path("libc/include"));
    for (spec.extra_includes) |inc| {
        mod.addIncludePath(b.path(inc));
    }
    mod.linkLibrary(libc_lib);
    const exe = b.addExecutable(.{
        .name = spec.name,
        .root_module = mod,
        // x86_64-freestanding defaults to Zig's self-hosted backend, which
        // can't encode our soft-float/naked-fn/f128 code. Pin LLVM there.
        .use_llvm = if (target.result.cpu.arch == .x86_64) true else null,
    });
    exe.entry = .{ .symbol_name = "_start" };
    exe.pie = true;
    exe.link_function_sections = true;
    exe.link_data_sections = true;

    const wrap = b.addRunArtifact(elf2macho);
    wrap.addArg(b.fmt("--page-size={d}", .{uspacePageSize(target.result.cpu.arch)}));
    for (spec.binds) |bind| {
        wrap.addArg(b.fmt("--bind={s}", .{bind}));
    }
    wrap.addArg(b.fmt("--authority={s}", .{spec.authority}));
    wrap.addFileArg(dev_key);
    wrap.addFileArg(exe.getEmittedBin());
    const macho = wrap.addOutputFileArg(b.fmt("{s}.macho", .{spec.name}));

    return .{ .macho = macho };
}

pub fn registerStep(b: *std.Build, optimize_in: std.builtin.OptimizeMode, tools: tools_mod.Tools, zoneinfo: std.Build.LazyPath, ca_bundle: std.Build.LazyPath, board: common.Board) std.Build.LazyPath {
    const keygen = tools.keygen;
    const elf2macho = tools.elf2macho;
    const cpio = tools.cpio;

    // ESP32-C6 has only 4 MB of flash and the initrd has to share that
    // with the bootloader + partition table + kernel. Force ReleaseSmall
    // so debug-sized userspace binaries don't blow past the budget. Other
    // boards respect the caller's -Doptimize choice.
    const optimize: std.builtin.OptimizeMode = if (board == .@"esp32-c6") .ReleaseSmall else optimize_in;
    const c6 = board == .@"esp32-c6";

    const ferrite_lib = zigstd.buildLibDir(b);

    const target = b.resolveTargetQuery(uspaceTarget(board));

    // libferrite_libc.a is the POSIX surface + crt0 + glue, built once and
    // shared across all C uspace binaries.
    const libc_lib = libc_mod.buildLibrary(b, target, optimize);

    const keygen_run = b.addRunArtifact(keygen);
    const dev_pub_lp = keygen_run.addOutputFileArg("dev.pub");
    const dev_key_lp = keygen_run.addOutputFileArg("dev.key");

    const init = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "init",
        .src = "uspace/init/src/main.zig",
        .authority = "0xFFFFFFFF",
    });

    const nameserver = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "nameserver",
        .src = "uspace/nameserver/src/main.zig",
        .authority = "0x00",
        .binds = &.{"nameserver-recv=channel_recv:rg"},
    });

    const mount_devfs = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "mount.devfs",
        .src = "uspace/mount.devfs/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const mount_tmpfs = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "mount.tmpfs",
        .src = "uspace/mount.tmpfs/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const mount_fat = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "mount.fat",
        .src = "uspace/mount.fat/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const mount_cpio = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "mount.cpio",
        .src = "uspace/mount.cpio/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const mount_ext4 = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "mount.ext4",
        .src = "uspace/mount.ext4/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const drv_tty = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "drv.tty",
        .src = "uspace/drv.tty/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const drv_initrd = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "drv.initrd",
        .src = "uspace/drv.initrd/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const drv_dtb = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "drv.dtb",
        .src = "uspace/drv.dtb/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const drv_acpi = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "drv.acpi",
        .src = "uspace/drv.acpi/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const drv_probe_dtb = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "drv.probe.dtb",
        .src = "uspace/drv.probe.dtb/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const drv_probe_acpi = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "drv.probe.acpi",
        .src = "uspace/drv.probe.acpi/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const drv_virtio_blk = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "drv.virtio-blk",
        .src = "uspace/drv.virtio-blk/src/main.zig",
        .authority = "0x16",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const drv_pci = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "drv.pci",
        .src = "uspace/drv.pci/src/main.zig",
        .authority = "0x14",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const drv_virtio_net = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "drv.virtio-net",
        .src = "uspace/drv.virtio-net/src/main.zig",
        .authority = "0x16",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const drv_virtio_rng = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "drv.virtio-rng",
        .src = "uspace/drv.virtio-rng/src/main.zig",
        .authority = "0x16",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const drv_virtio_gpu = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "drv.virtio-gpu",
        .src = "uspace/drv.virtio-gpu/src/main.zig",
        .authority = "0x16",
        .binds = &.{"nameserver=channel_send:wg"},
        .gpu = true,
    });

    const drv_virtio_sound = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "drv.virtio-sound",
        .src = "uspace/drv.virtio-sound/src/main.zig",
        .authority = "0x16",
        .binds = &.{"nameserver=channel_send:wg"},
        .audio = true,
    });

    const drv_virtio_input = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "drv.virtio-input",
        .src = "uspace/drv.virtio-input/src/main.zig",
        .authority = "0x16",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const gfx_demo = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "gfx-demo",
        .src = "uspace/gfx-demo/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
        .gpu = true,
    });

    const badapple = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "badapple",
        .src = "uspace/badapple/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
        .gpu = true,
        .audio = true,
    });

    const svc_net = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "svc.net",
        .src = "uspace/svc.net/src/main.zig",
        .authority = "0x70",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const svc_dns = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "svc.dns",
        .src = "uspace/svc.dns/src/main.zig",
        .authority = "0x30",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const svc_dhcp = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "svc.dhcp",
        .src = "uspace/svc.dhcp/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const svc_time = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "svc.time",
        .src = "uspace/svc.time/src/main.zig",
        .authority = "0x30",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const ping = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "ping",
        .src = "uspace/ping/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const ip_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "ip",
        .src = "uspace/ip/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const nslookup = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "nslookup",
        .src = "uspace/nslookup/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const ntpdate = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "ntpdate",
        .src = "uspace/ntpdate/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const svc_ntp = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "svc.ntp",
        .src = "uspace/svc.ntp/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const mount_procfs = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "mount.procfs",
        .src = "uspace/mount.procfs/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const wget = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "wget",
        .src = "uspace/wget/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const hello = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "hello",
        .src = "uspace/hello/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const hello_c = buildBinC(b, target, optimize, libc_lib, elf2macho, dev_key_lp, .{
        .name = "hello-c",
        .src = "uspace/hello-c/src/hello.c",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const cat = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "cat",
        .src = "uspace/cat/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const evtest = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "evtest",
        .src = "uspace/evtest/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const echo_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "echo",
        .src = "uspace/echo/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const grep_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "grep",
        .src = "uspace/grep/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const wc_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "wc",
        .src = "uspace/wc/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const ls = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "ls",
        .src = "uspace/ls/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const writebin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "write",
        .src = "uspace/write/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const uname_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "uname",
        .src = "uspace/uname/src/main.zig",
        .authority = "0x00",
        .binds = &.{},
    });

    const free_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "free",
        .src = "uspace/free/src/main.zig",
        .authority = "0x00",
        .binds = &.{},
    });

    const date_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "date",
        .src = "uspace/date/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const sleep_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "sleep",
        .src = "uspace/sleep/src/main.zig",
        .authority = "0x00",
        .binds = &.{},
    });

    const ps_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "ps",
        .src = "uspace/ps/src/main.zig",
        .authority = "0x00",
        .binds = &.{},
    });

    const top_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "top",
        .src = "uspace/top/src/main.zig",
        .authority = "0x00",
        .binds = &.{},
    });

    const time_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "time",
        .src = "uspace/time/src/main.zig",
        .authority = "0x11",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const uptime_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "uptime",
        .src = "uspace/uptime/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const sshd_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "sshd",
        .src = "uspace/sshd/src/main.zig",
        .authority = "0x11",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const kill_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "kill",
        .src = "uspace/kill/src/main.zig",
        .authority = "0x00",
        .binds = &.{},
    });

    const touch_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "touch",
        .src = "uspace/touch/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const ln_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "ln",
        .src = "uspace/ln/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const readlink_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "readlink",
        .src = "uspace/readlink/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const rmdir_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "rmdir",
        .src = "uspace/rmdir/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const mkdir_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "mkdir",
        .src = "uspace/mkdir/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const rm_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "rm",
        .src = "uspace/rm/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const svc_users = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "svc.users",
        .src = "uspace/svc.users/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const login_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "login",
        .src = "uspace/login/src/main.zig",
        .authority = "0x111",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const whoami_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "whoami",
        .src = "uspace/whoami/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const unshare_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "unshare",
        .src = "uspace/unshare/src/main.zig",
        .authority = "0x11",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const id_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "id",
        .src = "uspace/id/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const mount_bin = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "mount",
        .src = "uspace/mount/src/main.zig",
        .authority = "0x10",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const sh = buildBin(b, target, optimize, ferrite_lib, elf2macho, dev_key_lp, .{
        .name = "sh",
        .src = "uspace/sh/src/main.zig",
        .authority = "0x11",
        .binds = &.{"nameserver=channel_send:wg"},
    });

    const cpio_run = b.addRunArtifact(cpio);
    const initrd_lp = cpio_run.addOutputFileArg("initrd.cpio");
    cpio_run.addPrefixedFileArg("keys/root=", dev_pub_lp);
    cpio_run.addPrefixedFileArg("bin/init=", init.macho);
    cpio_run.addPrefixedFileArg("bin/nameserver=", nameserver.macho);
    cpio_run.addPrefixedFileArg("bin/mount.devfs=", mount_devfs.macho);
    cpio_run.addPrefixedFileArg("bin/mount.tmpfs=", mount_tmpfs.macho);
    cpio_run.addPrefixedFileArg("bin/mount.cpio=", mount_cpio.macho);
    cpio_run.addPrefixedFileArg("bin/mount.ext4=", mount_ext4.macho);
    cpio_run.addPrefixedFileArg("bin/mount.procfs=", mount_procfs.macho);
    cpio_run.addPrefixedFileArg("bin/drv.tty=", drv_tty.macho);
    cpio_run.addPrefixedFileArg("bin/drv.initrd=", drv_initrd.macho);
    cpio_run.addPrefixedFileArg("bin/hello=", hello.macho);
    cpio_run.addPrefixedFileArg("bin/hello-c=", hello_c.macho);
    cpio_run.addPrefixedFileArg("bin/cat=", cat.macho);
    cpio_run.addPrefixedFileArg("bin/evtest=", evtest.macho);
    cpio_run.addPrefixedFileArg("bin/echo=", echo_bin.macho);
    cpio_run.addPrefixedFileArg("bin/grep=", grep_bin.macho);
    cpio_run.addPrefixedFileArg("bin/wc=", wc_bin.macho);
    cpio_run.addPrefixedFileArg("bin/ls=", ls.macho);
    cpio_run.addPrefixedFileArg("bin/write=", writebin.macho);
    cpio_run.addPrefixedFileArg("bin/uname=", uname_bin.macho);
    cpio_run.addPrefixedFileArg("bin/free=", free_bin.macho);
    cpio_run.addPrefixedFileArg("bin/date=", date_bin.macho);
    cpio_run.addPrefixedFileArg("bin/sleep=", sleep_bin.macho);
    cpio_run.addPrefixedFileArg("bin/ps=", ps_bin.macho);
    cpio_run.addPrefixedFileArg("bin/top=", top_bin.macho);
    cpio_run.addPrefixedFileArg("bin/time=", time_bin.macho);
    cpio_run.addPrefixedFileArg("bin/uptime=", uptime_bin.macho);
    cpio_run.addPrefixedFileArg("bin/kill=", kill_bin.macho);
    cpio_run.addPrefixedFileArg("bin/touch=", touch_bin.macho);
    cpio_run.addPrefixedFileArg("bin/ln=", ln_bin.macho);
    cpio_run.addPrefixedFileArg("bin/readlink=", readlink_bin.macho);
    cpio_run.addPrefixedFileArg("bin/rmdir=", rmdir_bin.macho);
    cpio_run.addPrefixedFileArg("bin/mkdir=", mkdir_bin.macho);
    cpio_run.addPrefixedFileArg("bin/rm=", rm_bin.macho);
    cpio_run.addPrefixedFileArg("bin/svc.users=", svc_users.macho);
    cpio_run.addPrefixedFileArg("bin/login=", login_bin.macho);
    cpio_run.addPrefixedFileArg("bin/whoami=", whoami_bin.macho);
    cpio_run.addPrefixedFileArg("bin/unshare=", unshare_bin.macho);
    cpio_run.addPrefixedFileArg("bin/id=", id_bin.macho);
    cpio_run.addPrefixedFileArg("bin/mount=", mount_bin.macho);
    cpio_run.addPrefixedFileArg("bin/sh=", sh.macho);

    // Board-conditional: heavyweight stacks that don't make sense on ESP32-C6
    // (no PCI, no virtio devices, no network stack yet, no DTB/ACPI probes,
    // no FAT for now). Excluded to stay inside the 4 MB flash budget.
    if (!c6) {
        cpio_run.addPrefixedFileArg("bin/drv.virtio-blk=", drv_virtio_blk.macho);
        cpio_run.addPrefixedFileArg("bin/drv.pci=", drv_pci.macho);
        cpio_run.addPrefixedFileArg("bin/drv.virtio-net=", drv_virtio_net.macho);
        cpio_run.addPrefixedFileArg("bin/drv.virtio-rng=", drv_virtio_rng.macho);
        cpio_run.addPrefixedFileArg("bin/drv.virtio-gpu=", drv_virtio_gpu.macho);
        cpio_run.addPrefixedFileArg("bin/drv.virtio-sound=", drv_virtio_sound.macho);
        cpio_run.addPrefixedFileArg("bin/drv.virtio-input=", drv_virtio_input.macho);
        cpio_run.addPrefixedFileArg("bin/gfx-demo=", gfx_demo.macho);
        cpio_run.addPrefixedFileArg("bin/badapple=", badapple.macho);
        cpio_run.addPrefixedFileArg("bin/svc.net=", svc_net.macho);
        cpio_run.addPrefixedFileArg("bin/svc.dns=", svc_dns.macho);
        cpio_run.addPrefixedFileArg("bin/svc.dhcp=", svc_dhcp.macho);
        cpio_run.addPrefixedFileArg("bin/svc.time=", svc_time.macho);
        cpio_run.addPrefixedFileArg("bin/ping=", ping.macho);
        cpio_run.addPrefixedFileArg("bin/ip=", ip_bin.macho);
        cpio_run.addPrefixedFileArg("bin/nslookup=", nslookup.macho);
        cpio_run.addPrefixedFileArg("bin/ntpdate=", ntpdate.macho);
        cpio_run.addPrefixedFileArg("bin/svc.ntp=", svc_ntp.macho);
        cpio_run.addPrefixedFileArg("bin/wget=", wget.macho);
        cpio_run.addPrefixedFileArg("bin/mount.fat=", mount_fat.macho);
        cpio_run.addPrefixedFileArg("bin/drv.dtb=", drv_dtb.macho);
        cpio_run.addPrefixedFileArg("bin/drv.acpi=", drv_acpi.macho);
        cpio_run.addPrefixedFileArg("bin/drv.probe.dtb=", drv_probe_dtb.macho);
        cpio_run.addPrefixedFileArg("bin/drv.probe.acpi=", drv_probe_acpi.macho);
        cpio_run.addPrefixedFileArg("bin/sshd=", sshd_bin.macho);
    }

    cpio_run.addPrefixedFileArg("etc/services=", b.path("initrd/etc/services"));
    // NOTE: zig's Run cache does not always re-hash this directory's contents,
    // so after adding/removing/editing an /etc/init.d unit you may need to bust
    // the cache (`rm -rf .zig-cache/o .zig-cache/h`) for the change to land in
    // the initrd.
    cpio_run.addPrefixedDirectoryArg("dir:etc/init.d=", b.path("initrd/etc/init.d"));
    cpio_run.addPrefixedFileArg("etc/mounts=", b.path("initrd/etc/mounts"));
    cpio_run.addPrefixedFileArg("etc/devices=", b.path("initrd/etc/devices"));
    cpio_run.addPrefixedFileArg("etc/filesystems=", b.path("initrd/etc/filesystems"));
    cpio_run.addPrefixedFileArg("etc/users=", b.path("initrd/etc/users"));
    cpio_run.addPrefixedFileArg("etc/timezone=", b.path("initrd/etc/timezone"));
    if (!c6) {
        cpio_run.addPrefixedFileArg("etc/resolv.conf=", b.path("initrd/etc/resolv.conf"));
        cpio_run.addPrefixedFileArg("etc/net.conf=", b.path("initrd/etc/net.conf"));
        cpio_run.addPrefixedFileArg("etc/ssl/certs/ca-bundle.pem=", ca_bundle);
        cpio_run.addPrefixedDirectoryArg("dir:etc/zoneinfo=", zoneinfo);
    }

    const install_init_macho = b.addInstallBinFile(init.macho, "init.macho");
    const install_pub = b.addInstallFile(dev_pub_lp, "share/ferrite/dev.pub");
    const install_initrd = b.addInstallFile(initrd_lp, "initrd.cpio");

    const initrd_step = b.step("initrd", "Build initrd.cpio");
    initrd_step.dependOn(&install_initrd.step);
    initrd_step.dependOn(&install_pub.step);

    const uspace_step = b.step("uspace", "Build userspace binaries and assemble initrd.cpio");
    uspace_step.dependOn(&install_init_macho.step);
    uspace_step.dependOn(initrd_step);

    b.getInstallStep().dependOn(&install_initrd.step);
    return initrd_lp;
}
