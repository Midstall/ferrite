const std = @import("std");
const common = @import("common.zig");

pub fn buildLimine(b: *std.Build, optimize: std.builtin.OptimizeMode, kernel_options: *std.Build.Module, initrd_lp: std.Build.LazyPath) void {
    const arch_dir = "kernel/src/arch/riscv64";
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .baseline,
    });
    // Higher-half via Sv39 sign extension; .medium PC-rel reach fits.
    const code_model: std.builtin.CodeModel = .medium;

    const arch_mod = common.freestandingModule(b, b.path(b.fmt("{s}/arch_smode.zig", .{arch_dir})), target, optimize, code_model);
    arch_mod.addAssemblyFile(b.path(b.fmt("{s}/trap_entry_smode.S", .{arch_dir})));
    arch_mod.addAssemblyFile(b.path(b.fmt("{s}/context_switch.S", .{arch_dir})));

    const riscv_mod = common.freestandingModule(b, b.path("kernel/src/arch/riscv/riscv.zig"), target, optimize, code_model);
    arch_mod.addImport("riscv", riscv_mod);
    // The arch leaf drivers (uart_ns16550) bind conduit drivers, so conduit must
    // reach arch_mod as well as kernel_mod. Same cached instance, types match.
    arch_mod.addImport("conduit", common.conduitModule(b, target, optimize));
    const kernel_mod = common.freestandingModule(b, b.path("kernel/src/kmain.zig"), target, optimize, code_model);
    kernel_mod.addImport("arch", arch_mod);
    kernel_mod.addImport("kernel-options", kernel_options);
    kernel_mod.addImport("conduit", common.conduitModule(b, target, optimize));

    const start_mod = common.freestandingModule(b, b.path(b.fmt("{s}/boot/limine.zig", .{arch_dir})), target, optimize, code_model);
    start_mod.addImport("kernel", kernel_mod);
    start_mod.addImport("arch", arch_mod);

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
    const uboot_path = b.graph.environ_map.get("UBOOT_RISCV64");

    if (limine_dir == null or uboot_path == null) {
        const fail = b.addFail("LIMINE_DIR or UBOOT_RISCV64 missing. Run `direnv reload`.");
        const run_step = b.step("run", "Run (requires LIMINE_DIR + UBOOT_RISCV64)");
        run_step.dependOn(&fail.step);
        return;
    }

    const ld = limine_dir.?;
    const fw = uboot_path.?;

    const iso_dir = b.addWriteFiles();
    _ = iso_dir.addCopyFile(kernel.getEmittedBin(), "boot/kernel.elf");
    _ = iso_dir.add("boot/limine/limine.conf",
        \\timeout: 0
        \\
        \\/Ferrite
        \\    protocol: limine
        \\    path: boot():/boot/kernel.elf
        \\    module_path: boot():/boot/initrd.cpio
        \\
    );
    _ = iso_dir.addCopyFile(initrd_lp, "boot/initrd.cpio");
    _ = iso_dir.addCopyFile(.{ .cwd_relative = b.fmt("{s}/limine-uefi-cd.bin", .{ld}) }, "boot/limine/limine-uefi-cd.bin");
    _ = iso_dir.addCopyFile(.{ .cwd_relative = b.fmt("{s}/BOOTRISCV64.EFI", .{ld}) }, "EFI/BOOT/BOOTRISCV64.EFI");

    const xorriso = b.addSystemCommand(&.{
        "xorriso",                  "-as",
        "mkisofs",                  "-R",
        "-r",                       "-J",
        "--efi-boot",               "boot/limine/limine-uefi-cd.bin",
        "-efi-boot-part",           "--efi-boot-image",
        "--protective-msdos-label",
    });
    xorriso.addDirectoryArg(iso_dir.getDirectory());
    xorriso.addArg("-o");
    const iso_file = xorriso.addOutputFileArg("ferrite-limine.iso");

    const install_iso = b.addInstallFile(iso_file, "ferrite-limine.iso");
    b.getInstallStep().dependOn(&install_iso.step);

    // -bios defaults to OpenSBI; U-Boot via -kernel chains into BOOTRISCV64.EFI.
    const run_cmd = b.addSystemCommand(&.{
        "qemu-system-riscv64",
        "-M",
        "virt",
        "-m",
        "256M",
        "-kernel",
        fw,
    });
    common.addQemuVirtioArgs(run_cmd, "ferrite-riscv64-limine.pcap");
    run_cmd.addArg("-drive");
    run_cmd.addPrefixedFileArg("if=virtio,format=raw,id=cdrom,file=", iso_file);
    common.addQemuRunTail(run_cmd);

    const run_step = b.step("run", "Run kernel in QEMU (limine via U-Boot EFI)");
    run_step.dependOn(&run_cmd.step);
}

/// Bare S-mode kernel for an SBI handoff (the Midstall creek SoC under Weir).
/// Same S-mode arch surface as the Limine build, but the `boot/sbi.zig` entry
/// takes Weir's a0=hartid/a1=dtb handoff and links low (0x8020_0000, above the
/// SBI). Emits only the ELF - Weir embeds it via `-Dpayload`; there is no host
/// QEMU run step (the target is real silicon reached over JTAG/UART).
pub fn buildSbi(b: *std.Build, optimize: std.builtin.OptimizeMode, kernel_options: *std.Build.Module, initrd_lp: std.Build.LazyPath) void {
    _ = initrd_lp; // The initrd arrives via the device tree Weir hands off, not the host build.
    const arch_dir = "kernel/src/arch/riscv64";
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .baseline,
    });
    // Kernel links low (identity, bare S-mode); .medium PC-rel reach fits.
    const code_model: std.builtin.CodeModel = .medium;

    const arch_mod = common.freestandingModule(b, b.path(b.fmt("{s}/arch_smode.zig", .{arch_dir})), target, optimize, code_model);
    arch_mod.addAssemblyFile(b.path(b.fmt("{s}/trap_entry_smode.S", .{arch_dir})));
    arch_mod.addAssemblyFile(b.path(b.fmt("{s}/context_switch.S", .{arch_dir})));

    const riscv_mod = common.freestandingModule(b, b.path("kernel/src/arch/riscv/riscv.zig"), target, optimize, code_model);
    arch_mod.addImport("riscv", riscv_mod);
    arch_mod.addImport("conduit", common.conduitModule(b, target, optimize));

    const kernel_mod = common.freestandingModule(b, b.path("kernel/src/kmain.zig"), target, optimize, code_model);
    kernel_mod.addImport("arch", arch_mod);
    kernel_mod.addImport("kernel-options", kernel_options);
    kernel_mod.addImport("conduit", common.conduitModule(b, target, optimize));

    const start_mod = common.freestandingModule(b, b.path(b.fmt("{s}/boot/sbi.zig", .{arch_dir})), target, optimize, code_model);
    start_mod.addImport("kernel", kernel_mod);
    start_mod.addImport("arch", arch_mod);

    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = start_mod,
    });
    kernel.setLinkerScript(b.path(b.fmt("{s}/link/sbi.ld", .{arch_dir})));
    kernel.entry = .{ .symbol_name = "_start" };
    kernel.pie = false;
    kernel.linkage = .static;
    kernel.bundle_compiler_rt = true;

    b.installArtifact(kernel);
}
