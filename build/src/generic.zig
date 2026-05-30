const std = @import("std");
const common = @import("common.zig");
const Board = common.Board;
const BootProtocol = common.BootProtocol;

const Config = struct {
    arch_dir: []const u8,
    target: std.Target.Query,
    qemu_cmd: []const []const u8,
    code_model: std.builtin.CodeModel = .default,
    asm_files: []const []const u8 = &.{},
};

fn config(board: Board) Config {
    return switch (board) {
        .@"qemu-virt-aarch64" => .{
            .arch_dir = "kernel/src/arch/aarch64",
            .target = .{
                .cpu_arch = .aarch64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_model = .baseline,
            },
            .qemu_cmd = &.{
                "qemu-system-aarch64",
                "-M",
                "virt",
                "-cpu",
                "cortex-a53",
                "-m",
                "256M",
                "-kernel",
            },
            .asm_files = &.{
                "kernel/src/arch/aarch64/vectors.S",
                "kernel/src/arch/aarch64/context_switch.S",
                "kernel/src/arch/aarch64/secondary_entry.S",
            },
        },
        .@"qemu-virt-riscv64" => .{
            .arch_dir = "kernel/src/arch/riscv64",
            .target = .{
                .cpu_arch = .riscv64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_model = .baseline,
            },
            .qemu_cmd = &.{
                "qemu-system-riscv64",
                "-M",
                "virt",
                "-bios",
                "none",
                "-m",
                "256M",
                "-kernel",
            },
            .code_model = .medium,
            .asm_files = &.{
                "kernel/src/arch/riscv64/trap_entry.S",
                "kernel/src/arch/riscv64/context_switch.S",
            },
        },
        .@"qemu-pc-i386" => .{
            .arch_dir = "kernel/src/arch/i386",
            .target = .{
                .cpu_arch = .x86,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_model = .baseline,
                // Block SIMD/x87 lowering: FP regs fault in IRQ ctx without CR4.OSFXSR.
                .cpu_features_sub = std.Target.x86.featureSet(&.{
                    .mmx,   .sse,    .sse2,   .sse3,
                    .ssse3, .sse4_1, .sse4_2, .sse4a,
                    .avx,   .avx2,   .x87,
                }),
                .cpu_features_add = std.Target.x86.featureSet(&.{.soft_float}),
            },
            .qemu_cmd = &.{
                "qemu-system-i386",
                "-m",
                "256M",
                "-kernel",
            },
            .asm_files = &.{
                "kernel/src/arch/i386/isr.S",
                "kernel/src/arch/i386/context_switch.S",
            },
        },
        .@"qemu-pc-x86_64", .@"esp32-c6" => unreachable,
    };
}

pub fn build(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    board: Board,
    boot: BootProtocol,
    arch_options: ?*std.Build.Module,
    kernel_options: *std.Build.Module,
    initrd_lp: ?std.Build.LazyPath,
) void {
    const cfg = config(board);
    const target = b.resolveTargetQuery(cfg.target);

    const arch_mod = common.freestandingModule(b, b.path(b.fmt("{s}/arch.zig", .{cfg.arch_dir})), target, optimize, cfg.code_model);
    if (arch_options) |opts| arch_mod.addImport("arch-options", opts);
    if (board == .@"qemu-pc-i386") {
        const x86_mod = common.freestandingModule(b, b.path("kernel/src/arch/x86/x86.zig"), target, optimize, cfg.code_model);
        arch_mod.addImport("x86", x86_mod);
    }
    if (board == .@"qemu-virt-riscv64") {
        const riscv_mod = common.freestandingModule(b, b.path("kernel/src/arch/riscv/riscv.zig"), target, optimize, cfg.code_model);
        arch_mod.addImport("riscv", riscv_mod);
    }
    const kernel_mod = common.freestandingModule(b, b.path("kernel/src/kmain.zig"), target, optimize, cfg.code_model);
    kernel_mod.addImport("arch", arch_mod);
    kernel_mod.addImport("kernel-options", kernel_options);

    const start_mod = common.freestandingModule(b, b.path(b.fmt("{s}/start.zig", .{cfg.arch_dir})), target, optimize, cfg.code_model);
    start_mod.addImport("kernel", kernel_mod);
    start_mod.addImport("arch", arch_mod);
    for (cfg.asm_files) |f| {
        arch_mod.addAssemblyFile(b.path(f));
    }

    const kernel = b.addExecutable(.{
        .name = "ferrite.elf",
        .root_module = start_mod,
    });
    // multiboot1 + multiboot2 share one link script.
    const ld_name = if (boot == .multiboot2) "multiboot" else @tagName(boot);
    kernel.setLinkerScript(b.path(b.fmt("{s}/link/{s}.ld", .{ cfg.arch_dir, ld_name })));
    kernel.entry = .{ .symbol_name = "_start" };
    kernel.pie = false;
    kernel.linkage = .static;
    kernel.bundle_compiler_rt = true;

    b.installArtifact(kernel);

    // qemu aarch64 virt only delivers DTB in x0 for the Linux image format
    // (flat .img with magic at offset 0x38).
    const qemu_input: std.Build.LazyPath = if (board == .@"qemu-virt-aarch64" and boot == .raw) blk: {
        const img = b.addObjCopy(kernel.getEmittedBin(), .{
            .basename = "ferrite.img",
            .format = .bin,
        });
        const install_img = b.addInstallBinFile(img.getOutput(), "ferrite.img");
        b.getInstallStep().dependOn(&install_img.step);
        break :blk img.getOutput();
    } else kernel.getEmittedBin();

    const run_cmd = b.addSystemCommand(cfg.qemu_cmd);
    run_cmd.addFileArg(qemu_input);
    if (initrd_lp) |lp| {
        run_cmd.addArg("-initrd");
        run_cmd.addFileArg(lp);
    }
    const pcap_name = b.fmt("ferrite-{s}-{s}.pcap", .{ @tagName(board), @tagName(boot) });
    common.addQemuVirtioArgs(run_cmd, pcap_name);
    common.addQemuRunTail(run_cmd);

    const run_step = b.step("run", "Run kernel in QEMU");
    run_step.dependOn(&run_cmd.step);
}
