// Multiboot/limine link via `zig ld.lld` directly: Zig 0.16's link step for
// x86_64-freestanding silently ignores the GNU-ld linker script.

const std = @import("std");
const common = @import("common.zig");

fn target() std.Target.Query {
    return .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .baseline,
        // Keep LLVM off SSE/x87: movdqa traps on unaligned struct copies.
        .cpu_features_sub = std.Target.x86.featureSet(&.{
            .mmx,   .sse,    .sse2,   .sse3,
            .ssse3, .sse4_1, .sse4_2, .sse4a,
            .avx,   .avx2,   .x87,
        }),
        .cpu_features_add = std.Target.x86.featureSet(&.{.soft_float}),
    };
}

fn assemble(b: *std.Build, source: std.Build.LazyPath, name: []const u8) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        "zig",     "cc",                       "-c",
        "-target", "x86_64-freestanding-none",
    });
    cmd.addArg("-o");
    const obj = cmd.addOutputFileArg(name);
    cmd.addFileArg(source);
    return obj;
}

const LinkOpts = struct {
    zig_obj: *std.Build.Step.Compile,
    asm_objs: []const std.Build.LazyPath = &.{},
    link_script: std.Build.LazyPath,
    output_name: []const u8,
};

fn linkElf(b: *std.Build, opts: LinkOpts) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        "zig",     "ld.lld",
        "-static", "--no-pie",
        "-z",      "max-page-size=0x1000",
        "-m",      "elf_x86_64",
        "-T",
    });
    cmd.addFileArg(opts.link_script);
    cmd.addArg("-o");
    const elf = cmd.addOutputFileArg(opts.output_name);
    cmd.addFileArg(opts.zig_obj.getEmittedBin());
    for (opts.asm_objs) |a| cmd.addFileArg(a);
    return elf;
}

pub fn buildMultiboot(b: *std.Build, optimize: std.builtin.OptimizeMode, kernel_options: *std.Build.Module, initrd_lp: std.Build.LazyPath) void {
    _ = initrd_lp;
    const t = b.resolveTargetQuery(target());
    const arch_dir = "kernel/src/arch/x86_64";

    const arch_mod = common.freestandingModule(b, b.path(b.fmt("{s}/arch.zig", .{arch_dir})), t, optimize, .default);
    const x86_mod = common.freestandingModule(b, b.path("kernel/src/arch/x86/x86.zig"), t, optimize, .default);
    arch_mod.addImport("x86", x86_mod);
    const kernel_mod = common.freestandingModule(b, b.path("kernel/src/kmain.zig"), t, optimize, .default);
    kernel_mod.addImport("arch", arch_mod);
    kernel_mod.addImport("kernel-options", kernel_options);
    // Kernel only needs libc's freestanding mem* exports (manual ld.lld link
    // has no compiler_rt). mem.zig has no userspace deps, unlike libc.zig.
    const libc_mod = common.freestandingModule(b, b.path("libc/src/mem.zig"), t, optimize, .default);

    const start_mod = common.freestandingModule(b, b.path(b.fmt("{s}/start.zig", .{arch_dir})), t, optimize, .default);
    start_mod.addImport("kernel", kernel_mod);
    start_mod.addImport("arch", arch_mod);
    start_mod.addImport("libc", libc_mod);

    const zig_obj = b.addObject(.{
        .name = "ferrite_zig",
        .root_module = start_mod,
        // Zig 0.16 defaults x86_64-freestanding to its self-hosted backend,
        // which can't encode our soft-float/SSE-disabled FP, naked-fn stack
        // operands, or f128. Pin LLVM. Other arches already default to LLVM.
        .use_llvm = true,
    });

    const mb_obj = assemble(b, b.path(b.fmt("{s}/boot/multiboot.S", .{arch_dir})), "multiboot.o");
    const isr_obj = assemble(b, b.path(b.fmt("{s}/isr.S", .{arch_dir})), "x86_64_isr.o");
    const ctx_obj = assemble(b, b.path(b.fmt("{s}/context_switch.S", .{arch_dir})), "x86_64_ctx.o");
    const sysc_obj = assemble(b, b.path(b.fmt("{s}/syscall_entry.S", .{arch_dir})), "x86_64_syscall.o");

    const elf = linkElf(b, .{
        .zig_obj = zig_obj,
        .asm_objs = &.{ mb_obj, isr_obj, ctx_obj, sysc_obj },
        .link_script = b.path(b.fmt("{s}/link/multiboot.ld", .{arch_dir})),
        .output_name = "ferrite.elf",
    });

    const install_elf = b.addInstallFile(elf, "bin/ferrite.elf");
    b.getInstallStep().dependOn(&install_elf.step);

    // qemu -kernel rejects ELF64 multiboot1/2; needs GRUB on an ISO.
    const run_fail = b.addFail(
        "x86_64 multiboot can't boot via `qemu -kernel` (QEMU limitation: ELF64 rejected). " ++
            "The kernel built at zig-out/bin/ferrite.elf has valid MB1+MB2 headers. " ++
            "Use GRUB on an ISO to boot it. For x86_64 dev loop, use `-Dboot=limine` or `-Dboot=uefi`.",
    );
    const run_step = b.step("run", "(unsupported by qemu -kernel; see message)");
    run_step.dependOn(&run_fail.step);
}

pub fn buildLimine(b: *std.Build, optimize: std.builtin.OptimizeMode, kernel_options: *std.Build.Module, initrd_lp: std.Build.LazyPath) void {
    const t = b.resolveTargetQuery(target());
    const arch_dir = "kernel/src/arch/x86_64";

    // Higher-half at 0xffffffff80000000; code_model=.kernel keeps refs in the top 2 GB.
    const code_model: std.builtin.CodeModel = .kernel;

    const arch_mod = common.freestandingModule(b, b.path(b.fmt("{s}/arch.zig", .{arch_dir})), t, optimize, code_model);
    const x86_mod = common.freestandingModule(b, b.path("kernel/src/arch/x86/x86.zig"), t, optimize, code_model);
    arch_mod.addImport("x86", x86_mod);
    const kernel_mod = common.freestandingModule(b, b.path("kernel/src/kmain.zig"), t, optimize, code_model);
    kernel_mod.addImport("arch", arch_mod);
    kernel_mod.addImport("kernel-options", kernel_options);
    // Kernel only needs libc's freestanding mem* exports (manual ld.lld link
    // has no compiler_rt). mem.zig has no userspace deps, unlike libc.zig.
    const libc_mod = common.freestandingModule(b, b.path("libc/src/mem.zig"), t, optimize, code_model);

    const start_mod = common.freestandingModule(b, b.path(b.fmt("{s}/boot/limine.zig", .{arch_dir})), t, optimize, code_model);
    start_mod.addImport("kernel", kernel_mod);
    start_mod.addImport("arch", arch_mod);
    start_mod.addImport("libc", libc_mod);

    const zig_obj = b.addObject(.{
        .name = "ferrite_limine",
        .root_module = start_mod,
        // See buildMultiboot: pin LLVM, the self-hosted x86_64 backend
        // can't encode our soft-float/naked-fn/f128 code.
        .use_llvm = true,
    });

    const asm_obj = assemble(b, b.path(b.fmt("{s}/isr.S", .{arch_dir})), "x86_64_isr.o");
    const start_obj = assemble(b, b.path(b.fmt("{s}/boot/limine_start.S", .{arch_dir})), "limine_start.o");
    const ctx_obj = assemble(b, b.path(b.fmt("{s}/context_switch.S", .{arch_dir})), "x86_64_ctx.o");
    const sysc_obj = assemble(b, b.path(b.fmt("{s}/syscall_entry.S", .{arch_dir})), "x86_64_syscall.o");

    const kernel_elf = linkElf(b, .{
        .zig_obj = zig_obj,
        .asm_objs = &.{ asm_obj, start_obj, ctx_obj, sysc_obj },
        .link_script = b.path(b.fmt("{s}/link/limine.ld", .{arch_dir})),
        .output_name = "kernel.elf",
    });

    const install_kernel = b.addInstallFile(kernel_elf, "bin/kernel.elf");
    b.getInstallStep().dependOn(&install_kernel.step);

    const limine_dir = b.graph.environ_map.get("LIMINE_DIR");

    if (limine_dir) |ld| {
        const iso_dir = b.addWriteFiles();
        _ = iso_dir.addCopyFile(kernel_elf, "boot/kernel.elf");
        _ = iso_dir.add("boot/limine/limine.conf",
            \\timeout: 0
            \\serial: yes
            \\
            \\/Ferrite
            \\    protocol: limine
            \\    path: boot():/boot/kernel.elf
            \\    module_path: boot():/boot/initrd.cpio
            \\
        );
        _ = iso_dir.addCopyFile(initrd_lp, "boot/initrd.cpio");
        _ = iso_dir.addCopyFile(.{ .cwd_relative = b.fmt("{s}/limine-bios.sys", .{ld}) }, "boot/limine/limine-bios.sys");
        _ = iso_dir.addCopyFile(.{ .cwd_relative = b.fmt("{s}/limine-bios-cd.bin", .{ld}) }, "boot/limine/limine-bios-cd.bin");
        _ = iso_dir.addCopyFile(.{ .cwd_relative = b.fmt("{s}/limine-uefi-cd.bin", .{ld}) }, "boot/limine/limine-uefi-cd.bin");
        _ = iso_dir.addCopyFile(.{ .cwd_relative = b.fmt("{s}/BOOTX64.EFI", .{ld}) }, "EFI/BOOT/BOOTX64.EFI");

        // Hybrid BIOS+UEFI ISO; incantation from upstream Limine examples.
        const xorriso = b.addSystemCommand(&.{
            "xorriso",                        "-as",
            "mkisofs",                        "-R",
            "-r",                             "-J",
            "-b",                             "boot/limine/limine-bios-cd.bin",
            "-no-emul-boot",                  "-boot-load-size",
            "4",                              "-boot-info-table",
            "-hfsplus",                       "-apm-block-size",
            "2048",                           "--efi-boot",
            "boot/limine/limine-uefi-cd.bin", "-efi-boot-part",
            "--efi-boot-image",               "--protective-msdos-label",
        });
        xorriso.addDirectoryArg(iso_dir.getDirectory());
        xorriso.addArg("-o");
        const iso_file = xorriso.addOutputFileArg("ferrite-limine.iso");

        // Patches the ISO so the BIOS path boots.
        const limine_install = b.addSystemCommand(&.{ "limine", "bios-install" });
        limine_install.addFileArg(iso_file);

        const install_iso = b.addInstallFile(iso_file, "ferrite-limine.iso");
        install_iso.step.dependOn(&limine_install.step);
        b.getInstallStep().dependOn(&install_iso.step);

        // Prefer UEFI Limine when OVMF is available: BIOS Limine on q35 has
        // proven flaky with our higher-half kernel (wedges in struct stores
        // post-handoff). The aarch64 path also uses UEFI Limine and works.
        const ovmf_fd = b.graph.environ_map.get("OVMF_X86_64_FD");
        const run_cmd = b.addSystemCommand(&.{
            "qemu-system-x86_64",
            "-M",
            "q35",
            "-m",
            "256M",
            "-boot",
            "d",
        });
        if (ovmf_fd) |ovmf| {
            run_cmd.addArg("-bios");
            run_cmd.addArg(ovmf);
        }
        common.addQemuVirtioArgs(run_cmd, "ferrite-x86_64-limine.pcap");
        run_cmd.addArg("-cdrom");
        run_cmd.addFileArg(iso_file);
        run_cmd.step.dependOn(&limine_install.step);
        common.addQemuRunTail(run_cmd);

        const run_step = b.step("run", "Run kernel in QEMU (limine)");
        run_step.dependOn(&run_cmd.step);
    } else {
        const fail = b.addFail("LIMINE_DIR env var not set. Run `direnv reload` after the flake.nix update to add the limine bootloader to the dev shell.");
        const run_step = b.step("run", "Run (requires LIMINE_DIR; direnv reload)");
        run_step.dependOn(&fail.step);
    }
}

pub fn buildUefi(b: *std.Build, optimize: std.builtin.OptimizeMode, kernel_options: *std.Build.Module, initrd_lp: std.Build.LazyPath) void {
    const t = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .abi = .msvc,
    });
    const arch_dir = "kernel/src/arch/x86_64";

    const arch_mod = b.createModule(.{
        .root_source_file = b.path(b.fmt("{s}/arch.zig", .{arch_dir})),
        .target = t,
        .optimize = optimize,
        .single_threaded = true,
    });
    const x86_mod = b.createModule(.{
        .root_source_file = b.path("kernel/src/arch/x86/x86.zig"),
        .target = t,
        .optimize = optimize,
        .single_threaded = true,
    });
    arch_mod.addImport("x86", x86_mod);
    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("kernel/src/kmain.zig"),
        .target = t,
        .optimize = optimize,
        .single_threaded = true,
    });
    kernel_mod.addImport("arch", arch_mod);
    kernel_mod.addImport("kernel-options", kernel_options);

    const uefi_mod = b.createModule(.{
        .root_source_file = b.path(b.fmt("{s}/boot/uefi.zig", .{arch_dir})),
        .target = t,
        .optimize = optimize,
        .single_threaded = true,
    });
    uefi_mod.addImport("kernel", kernel_mod);
    uefi_mod.addImport("arch", arch_mod);
    // isr_uefi.S provides MSVC-ABI variants of every shared asm stub
    // (context_switch + syscall_entry included), so the SysV files stay out.
    uefi_mod.addAssemblyFile(b.path(b.fmt("{s}/isr_uefi.S", .{arch_dir})));

    const kernel = b.addExecutable(.{
        .name = "BOOTX64",
        .root_module = uefi_mod,
        // See buildMultiboot: pin LLVM, the self-hosted x86_64 backend
        // can't encode our soft-float/naked-fn/f128 code.
        .use_llvm = true,
    });

    b.installArtifact(kernel);

    const ovmf_fd = b.graph.environ_map.get("OVMF_X86_64_FD");

    if (ovmf_fd) |ovmf| {
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
            \\mcopy -i "$ESP" "$KERNEL" ::/EFI/BOOT/BOOTX64.EFI
            \\mcopy -i "$ESP" "$INITRD" ::/initrd.cpio
        });
        make_esp.addArg("--");
        const esp_img = make_esp.addOutputFileArg("esp.img");
        make_esp.addFileArg(kernel.getEmittedBin());
        make_esp.addFileArg(initrd_lp);

        const run_cmd = b.addSystemCommand(&.{
            "qemu-system-x86_64",
            "-M",
            "q35",
            "-m",
            "256M",
            "-bios",
            ovmf,
        });
        common.addQemuVirtioArgs(run_cmd, "ferrite-x86_64-uefi.pcap");
        run_cmd.addArg("-drive");
        run_cmd.addPrefixedFileArg("format=raw,file=", esp_img);
        common.addQemuRunTail(run_cmd);

        const run_step = b.step("run", "Run kernel in QEMU (UEFI)");
        run_step.dependOn(&run_cmd.step);
    } else {
        const fail = b.addFail("OVMF_X86_64_FD env var not set. Run `direnv reload` after the flake.nix update to add OVMF to the dev shell.");
        const run_step = b.step("run", "Run (requires OVMF_X86_64_FD; direnv reload)");
        run_step.dependOn(&fail.step);
    }
}
