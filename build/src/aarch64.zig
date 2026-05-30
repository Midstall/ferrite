const std = @import("std");
const common = @import("common.zig");

pub fn buildLimine(b: *std.Build, optimize: std.builtin.OptimizeMode, arch_options: *std.Build.Module, kernel_options: *std.Build.Module, initrd_lp: std.Build.LazyPath, rootfs: common.RootfsType) void {
    const arch_dir = "kernel/src/arch/aarch64";
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .baseline,
    });

    const arch_mod = common.freestandingModule(b, b.path(b.fmt("{s}/arch.zig", .{arch_dir})), target, optimize, .default);
    arch_mod.addImport("arch-options", arch_options);
    const kernel_mod = common.freestandingModule(b, b.path("kernel/src/kmain.zig"), target, optimize, .default);
    kernel_mod.addImport("arch", arch_mod);
    kernel_mod.addImport("kernel-options", kernel_options);

    const start_mod = common.freestandingModule(b, b.path(b.fmt("{s}/boot/limine.zig", .{arch_dir})), target, optimize, .default);
    start_mod.addImport("kernel", kernel_mod);
    start_mod.addImport("arch", arch_mod);

    arch_mod.addAssemblyFile(b.path(b.fmt("{s}/vectors.S", .{arch_dir})));
    arch_mod.addAssemblyFile(b.path(b.fmt("{s}/context_switch.S", .{arch_dir})));
    arch_mod.addAssemblyFile(b.path(b.fmt("{s}/secondary_entry.S", .{arch_dir})));

    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = start_mod,
    });
    kernel.setLinkerScript(b.path(b.fmt("{s}/link/limine.ld", .{arch_dir})));
    kernel.entry = .{ .symbol_name = "_start" };
    kernel.pie = false;
    kernel.linkage = .static;
    kernel.bundle_compiler_rt = true;

    b.installArtifact(kernel);

    const limine_dir = b.graph.environ_map.get("LIMINE_DIR");
    const ovmf_fd = b.graph.environ_map.get("OVMF_AARCH64_FD");

    if (limine_dir == null or ovmf_fd == null) {
        const fail = b.addFail("LIMINE_DIR or OVMF_AARCH64_FD missing. Run `direnv reload`.");
        const run_step = b.step("run", "Run (requires LIMINE_DIR + OVMF_AARCH64_FD)");
        run_step.dependOn(&fail.step);
        return;
    }

    const ld = limine_dir.?;
    const fw = ovmf_fd.?;

    const iso_dir = b.addWriteFiles();
    _ = iso_dir.addCopyFile(kernel.getEmittedBin(), "boot/kernel.elf");
    // root=ext4 boots off the ext4 disk built below; default keeps the initrd.
    const cmdline_line = if (rootfs == .ext4) "    cmdline: root=/dev/blk0 rootfstype=ext4\n" else "";
    _ = iso_dir.add("boot/limine/limine.conf", b.fmt(
        \\timeout: 0
        \\
        \\/Ferrite
        \\    protocol: limine
        \\    path: boot():/boot/kernel.elf
        \\{s}    module_path: boot():/boot/initrd.cpio
        \\
    , .{cmdline_line}));
    _ = iso_dir.addCopyFile(initrd_lp, "boot/initrd.cpio");
    _ = iso_dir.addCopyFile(.{ .cwd_relative = b.fmt("{s}/limine-uefi-cd.bin", .{ld}) }, "boot/limine/limine-uefi-cd.bin");
    _ = iso_dir.addCopyFile(.{ .cwd_relative = b.fmt("{s}/BOOTAA64.EFI", .{ld}) }, "EFI/BOOT/BOOTAA64.EFI");

    const xorriso = b.addSystemCommand(&.{
        "xorriso",                  "-as",
        "mkisofs",                  "-R",
        "-r",                       "-J",
        "--efi-boot",               "boot/limine/limine-uefi-cd.bin",
        "-efi-boot-part",           "--efi-boot-image",
        "--protective-msdos-label",
    });
    xorriso.addDirectoryArg(iso_dir.getDirectory());
    // addDirectoryArg keys the Run cache on the directory path, not its contents,
    // so a changed kernel/initrd leaves a stale ISO. Add them as explicit inputs
    // so the manifest tracks their hashes and the ISO rebuilds when they change.
    xorriso.addFileInput(kernel.getEmittedBin());
    xorriso.addFileInput(initrd_lp);
    xorriso.addArg("-o");
    const iso_file = xorriso.addOutputFileArg("ferrite-limine.iso");

    const install_iso = b.addInstallFile(iso_file, "ferrite-limine.iso");
    b.getInstallStep().dependOn(&install_iso.step);

    const run_cmd = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-M",
        "virt",
        "-cpu",
        "cortex-a72",
        "-m",
        "256M",
        "-bios",
        fw,
    });
    common.addQemuVirtioArgs(run_cmd, "ferrite-aarch64-limine.pcap");
    run_cmd.addArg("-cdrom");
    run_cmd.addFileArg(iso_file);

    if (rootfs == .ext4) {
        const rootfs_img = buildExt4Image(b, initrd_lp);
        b.getInstallStep().dependOn(&b.addInstallFile(rootfs_img, "rootfs.img").step);
        run_cmd.addArg("-drive");
        run_cmd.addPrefixedFileArg("format=raw,if=none,id=rootfs,file=", rootfs_img);
        run_cmd.addArgs(&.{ "-device", "virtio-blk-pci,drive=rootfs,disable-legacy=on,disable-modern=off" });
    }

    common.addQemuRunTail(run_cmd);

    const run_step = b.step("run", "Run kernel in QEMU (limine)");
    run_step.dependOn(&run_cmd.step);
}

// Build an ext4 disk image from the initrd's userspace tree: extract the cpio,
// add /sbin/init, and mke2fs it. Standard ext4 defaults (metadata_csum +
// has_journal + 64bit) - mount.ext4 now honors checksums and the journal.
// Needs `cpio` + `e2fsprogs` from the dev shell.
fn buildExt4Image(b: *std.Build, initrd_lp: std.Build.LazyPath) std.Build.LazyPath {
    const mkimg = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\set -e
        \\STAGE="$(mktemp -d)"
        \\(cd "$STAGE" && cpio -idmu) < "$1"
        \\mkdir -p "$STAGE/sbin" && cp "$STAGE/bin/init" "$STAGE/sbin/init"
        \\mke2fs -F -q -t ext4 -b 4096 -d "$STAGE" "$2" 65536
        \\rm -rf "$STAGE"
        ,
        "ferrite-mkrootfs",
    });
    mkimg.addFileArg(initrd_lp); // $1
    return mkimg.addOutputFileArg("rootfs.img"); // $2
}

pub fn buildUefi(b: *std.Build, optimize: std.builtin.OptimizeMode, arch_options: *std.Build.Module, kernel_options: *std.Build.Module, initrd_lp: std.Build.LazyPath) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .uefi,
        .abi = .msvc,
    });
    const arch_dir = "kernel/src/arch/aarch64";

    const arch_mod = b.createModule(.{
        .root_source_file = b.path(b.fmt("{s}/arch.zig", .{arch_dir})),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    arch_mod.addImport("arch-options", arch_options);
    arch_mod.addAssemblyFile(b.path(b.fmt("{s}/vectors.S", .{arch_dir})));
    arch_mod.addAssemblyFile(b.path(b.fmt("{s}/context_switch.S", .{arch_dir})));
    arch_mod.addAssemblyFile(b.path(b.fmt("{s}/secondary_entry.S", .{arch_dir})));
    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("kernel/src/kmain.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    kernel_mod.addImport("arch", arch_mod);
    kernel_mod.addImport("kernel-options", kernel_options);

    const uefi_mod = b.createModule(.{
        .root_source_file = b.path(b.fmt("{s}/boot/uefi.zig", .{arch_dir})),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    uefi_mod.addImport("kernel", kernel_mod);
    uefi_mod.addImport("arch", arch_mod);

    const kernel = b.addExecutable(.{
        .name = "BOOTAA64",
        .root_module = uefi_mod,
    });

    b.installArtifact(kernel);

    const ovmf_fd = b.graph.environ_map.get("OVMF_AARCH64_FD");

    if (ovmf_fd) |fw| {
        const make_esp = b.addSystemCommand(&.{
            "sh", "-c",
            \\set -e
            \\ESP=$1
            \\KERNEL=$2
            \\INITRD=$3
            \\rm -f "$ESP"
            \\dd if=/dev/zero of="$ESP" bs=1M count=64 status=none
            \\mformat -i "$ESP" -F ::
            \\mmd -i "$ESP" ::/EFI ::/EFI/BOOT
            \\mcopy -i "$ESP" "$KERNEL" ::/EFI/BOOT/BOOTAA64.EFI
            \\mcopy -i "$ESP" "$INITRD" ::/initrd.cpio
        });
        make_esp.addArg("--");
        const esp_img = make_esp.addOutputFileArg("esp.img");
        make_esp.addFileArg(kernel.getEmittedBin());
        make_esp.addFileArg(initrd_lp);

        const run_cmd = b.addSystemCommand(&.{
            "qemu-system-aarch64",
            "-M",
            "virt",
            "-cpu",
            "cortex-a72",
            "-m",
            "256M",
            "-bios",
            fw,
        });
        common.addQemuVirtioArgs(run_cmd, "ferrite-aarch64-uefi.pcap");
        run_cmd.addArg("-drive");
        run_cmd.addPrefixedFileArg("format=raw,file=", esp_img);
        common.addQemuRunTail(run_cmd);

        const run_step = b.step("run", "Run kernel in QEMU (UEFI)");
        run_step.dependOn(&run_cmd.step);
    } else {
        const fail = b.addFail("OVMF_AARCH64_FD env var not set. Run `direnv reload`.");
        const run_step = b.step("run", "Run (requires OVMF_AARCH64_FD)");
        run_step.dependOn(&fail.step);
    }
}
