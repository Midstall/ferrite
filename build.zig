const std = @import("std");
const common = @import("build/src/common.zig");
const generic = @import("build/src/generic.zig");
const aarch64 = @import("build/src/aarch64.zig");
const riscv64 = @import("build/src/riscv64.zig");
const x86_64 = @import("build/src/x86_64.zig");
const esp32 = @import("build/src/esp32.zig");
const libc = @import("build/src/libc.zig");
const tools = @import("build/src/tools.zig");
const zigstd = @import("build/src/zigstd.zig");
const uspace = @import("build/src/uspace.zig");
const tzdata = @import("build/src/tzdata.zig");
const cabundle = @import("build/src/cabundle.zig");

pub fn build(b: *std.Build) void {
    const board = b.option(common.Board, "board", "Target board") orelse .@"qemu-virt-aarch64";
    const boot = b.option(common.BootProtocol, "boot", "Boot protocol") orelse common.defaultProtocol(board);
    const gic_version = b.option(common.GicVersion, "gic-version", "GIC version (aarch64 only): auto detects at runtime; v2/v3 pin and dead-strip the other backend") orelse .auto;
    const sig_max_keys = b.option(u32, "sig-max-keys", "Max number of signature trust roots the kernel can hold at once (default 16)") orelse 16;
    const page_size = b.option(u32, "page-size", "Default page size in bytes. Sets the initial value of `memory.pageSize()`; cmdline `pagesize=N` overrides at boot. (default 4096)") orelse 4096;
    const rootfs = b.option(common.RootfsType, "rootfs", "Root filesystem: initrd (default), or ext4 (build an ext4 disk image from the userspace tree and boot off it). aarch64 limine only for now.") orelse .initrd;
    const hyp = b.option(bool, "hyp", "aarch64 raw only: enter at EL2 (qemu virtualization=on) so the kernel can run the microVM hypervisor. Host drops to EL1 to boot.") orelse false;
    const hyp_real = b.option(bool, "hyp-real", "aarch64 raw + -Dhyp: load a pristine ferrite.img into the guest region and boot it as a real guest VM (Ferrite-in-Ferrite). Default runs the synthetic guest demo.") orelse false;
    if (page_size != 4096 and page_size != 16384 and page_size != 65536) {
        const fail = b.addFail(b.fmt("-Dpage-size={d} not supported. Pick 4096, 16384, or 65536.", .{page_size}));
        b.getInstallStep().dependOn(&fail.step);
        return;
    }
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    libc.registerStep(b, target, optimize);

    // Bail out of the rest of the build graph if the caller only wants
    // the libc artifact (e.g. the nix ferrite-libc derivation). This
    // sidesteps b.dependency("tzdata"/"nss") fetches that the rest of
    // the graph needs but the libc doesn't.
    const minimal = b.option(bool, "minimal", "Skip everything except the libc step") orelse false;
    if (minimal) return;

    _ = tools.register(b, target, optimize);

    // uspace pipeline tools run on the host regardless of -Dtarget.
    const host_tools = tools.buildForHost(b, optimize);

    zigstd.registerStep(b);
    const zoneinfo_lp = tzdata.buildZoneinfo(b, optimize);
    const ca_bundle_lp = cabundle.buildBundle(b, host_tools.certdata2pem);
    const initrd_lp: ?std.Build.LazyPath = uspace.registerStep(b, optimize, host_tools, zoneinfo_lp, ca_bundle_lp, board);

    const arch_options: ?*std.Build.Module = switch (board) {
        .@"qemu-virt-aarch64" => common.aarch64ArchOptions(b, gic_version),
        else => null,
    };

    const cpu_features = b.option(common.CpuFeaturesPolicy, "cpu-features", "How to decide which optional CPU features (FP/SIMD, virtualization, crypto, atomics) to use: auto (prefer runtime detection, default), detect (runtime only), or fixed (build-time -Dcpu set only)") orelse .auto;

    const kernel_options = common.kernelOptions(b, .{
        .sig_max_keys = sig_max_keys,
        .page_size = page_size,
        .cpu_features = cpu_features,
        .hyp = hyp,
        // conduit's discovery + leaf drivers back the arch device layer on these
        // boards. kmain runs device discovery when this is set; the arch leaf
        // drivers bind conduit drivers over the Mmio seam.
        .have_conduit = board == .@"qemu-virt-riscv64" or board == .@"qemu-virt-aarch64" or board == .creek,
    });

    if (!common.supports(board, boot)) {
        const msg = b.fmt(
            "board={s} does not support boot={s}. See `supports()` in build/src/common.zig for the matrix.",
            .{ @tagName(board), @tagName(boot) },
        );
        const fail = b.addFail(msg);
        b.getInstallStep().dependOn(&fail.step);
        const run_step = b.step("run", "(unsupported combination)");
        run_step.dependOn(&fail.step);
        return;
    }

    switch (board) {
        .@"qemu-pc-x86_64" => switch (boot) {
            .multiboot, .multiboot2 => x86_64.buildMultiboot(b, optimize, kernel_options, initrd_lp.?),
            .limine => x86_64.buildLimine(b, optimize, kernel_options, initrd_lp.?),
            .uefi => x86_64.buildUefi(b, optimize, kernel_options, initrd_lp.?),
            .raw, .esp_image, .sbi => unreachable,
        },
        .@"qemu-virt-aarch64" => switch (boot) {
            .limine => aarch64.buildLimine(b, optimize, arch_options.?, kernel_options, initrd_lp.?, rootfs),
            .uefi => aarch64.buildUefi(b, optimize, arch_options.?, kernel_options, initrd_lp.?),
            .raw => generic.build(b, optimize, board, boot, arch_options, kernel_options, initrd_lp, hyp, hyp_real),
            .multiboot, .multiboot2, .esp_image, .sbi => unreachable,
        },
        .@"qemu-virt-riscv64" => switch (boot) {
            .limine => riscv64.buildLimine(b, optimize, kernel_options, initrd_lp.?),
            .raw => generic.build(b, optimize, board, boot, arch_options, kernel_options, initrd_lp, hyp, false),
            .multiboot, .multiboot2, .uefi, .esp_image, .sbi => unreachable,
        },
        .@"qemu-pc-i386" => generic.build(b, optimize, board, boot, arch_options, kernel_options, initrd_lp, false, false),
        .@"esp32-c6" => esp32.buildC6(b, optimize, kernel_options, initrd_lp, host_tools.elf2espimage),
        .creek => switch (boot) {
            .sbi => riscv64.buildSbi(b, optimize, kernel_options, initrd_lp.?),
            .raw, .multiboot, .multiboot2, .limine, .uefi, .esp_image => unreachable,
        },
    }
}
