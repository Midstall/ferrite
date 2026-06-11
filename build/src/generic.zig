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
    hyp: bool,
    hyp_real: bool,
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
    // The arch leaf drivers (UART/CLINT/GIC) on migrated boards bind conduit's
    // drivers over the Mmio seam, so conduit must reach arch_mod too. It's the
    // same cached module instance kernel_mod gets, so the types match across the
    // boundary. Gated to the arches actually migrated so conduit isn't compiled
    // for boards that don't use it yet.
    if (board == .@"qemu-virt-riscv64" or board == .@"qemu-virt-aarch64") {
        arch_mod.addImport("conduit", common.conduitModule(b, target, optimize));
    }
    const kernel_mod = common.freestandingModule(b, b.path("kernel/src/kmain.zig"), target, optimize, cfg.code_model);
    kernel_mod.addImport("arch", arch_mod);
    kernel_mod.addImport("kernel-options", kernel_options);
    // conduit is available to the kernel module; kmain only references it when
    // kernel_options.have_conduit is set (today: qemu-virt-riscv64), so other
    // boards routed through generic.build never analyze it.
    kernel_mod.addImport("conduit", common.conduitModule(b, target, optimize));

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

    // Hyp mode: enter at EL2 by enabling the machine's virtualization extensions
    // so the kernel can install the microVM hypervisor (it then drops to EL1).
    // Only aarch64 needs the machine's virtualization extensions toggled on; the
    // riscv H extension is already in qemu's virt CPU, so -Dhyp there just enables
    // the in-kernel demo (via kernel-options) without touching the qemu machine.
    const qemu_cmd: []const []const u8 = if (hyp and board == .@"qemu-virt-aarch64") blk: {
        const out = b.allocator.alloc([]const u8, cfg.qemu_cmd.len) catch @panic("oom");
        for (cfg.qemu_cmd, 0..) |a, i| {
            // Stay on GICv2: the host's GICv3 backend intermittently faults under
            // this config, and GICv2 has the GICH/GICV hardware VGIC we need.
            out[i] = if (std.mem.eql(u8, a, "virt")) "virt,virtualization=on" else a;
        }
        break :blk out;
    } else cfg.qemu_cmd;

    const run_cmd = b.addSystemCommand(qemu_cmd);
    run_cmd.addFileArg(qemu_input);
    if (initrd_lp) |lp| {
        run_cmd.addArg("-initrd");
        run_cmd.addFileArg(lp);
    }
    // Hyp mode: load a pristine copy of the same image into the reserved guest
    // region (PA 0x48000000) so the hypervisor can boot it as a guest VM
    // (Ferrite-in-Ferrite). The run depends on the install that writes it.
    if (hyp and hyp_real) {
        run_cmd.step.dependOn(b.getInstallStep());
        run_cmd.addArg("-device");
        run_cmd.addArg(b.fmt("loader,file={s},addr=0x4e000000,force-raw=on", .{b.getInstallPath(.bin, "ferrite.img")}));
    }
    const pcap_name = b.fmt("ferrite-{s}-{s}.pcap", .{ @tagName(board), @tagName(boot) });
    common.addQemuVirtioArgs(run_cmd, pcap_name);
    common.addQemuRunTail(run_cmd);

    const run_step = b.step("run", "Run kernel in QEMU");
    run_step.dependOn(&run_cmd.step);
}
