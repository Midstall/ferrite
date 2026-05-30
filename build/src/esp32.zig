const std = @import("std");
const common = @import("common.zig");
const tools = @import("tools.zig");

/// ESP32-C6 build. HP core is rv32imac_zicsr_zifencei. LP core ignored.
/// Three artifacts get flashed:
///   bootloader-esp32c6.bin   - ROM loads it, then it sets up the flash
///                              MMU + cache for kernel XIP, copies .data,
///                              and zeros .bss
///   partition-table.bin      - Ferrite partition table
///   kernel-esp32c6.bin       - kernelimage format (manifest + IROM
///                              payload + .data init values)
pub fn buildC6(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    kernel_options: *std.Build.Module,
    initrd_lp: ?std.Build.LazyPath,
    elf2espimage: *std.Build.Step.Compile,
) void {
    const host_tools = tools.buildForHost(b, optimize);
    const kernelimage = host_tools.kernelimage;
    const partitiontable = host_tools.partitiontable;

    const arch_dir = "kernel/src/arch/riscv32";
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv32,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.riscv.cpu.baseline_rv32 },
    });

    const arch_mod = common.freestandingModule(
        b,
        b.path(b.fmt("{s}/arch.zig", .{arch_dir})),
        target,
        optimize,
        .default,
    );
    arch_mod.addAssemblyFile(b.path(b.fmt("{s}/trap_entry.S", .{arch_dir})));
    arch_mod.addAssemblyFile(b.path(b.fmt("{s}/context_switch.S", .{arch_dir})));

    const riscv_mod = common.freestandingModule(
        b,
        b.path("kernel/src/arch/riscv/riscv.zig"),
        target,
        optimize,
        .default,
    );
    arch_mod.addImport("riscv", riscv_mod);

    const kernel_mod = common.freestandingModule(
        b,
        b.path("kernel/src/kmain.zig"),
        target,
        optimize,
        .default,
    );
    kernel_mod.addImport("arch", arch_mod);
    kernel_mod.addImport("kernel-options", kernel_options);

    const start_mod = common.freestandingModule(
        b,
        b.path(b.fmt("{s}/start.zig", .{arch_dir})),
        target,
        optimize,
        .default,
    );
    start_mod.addImport("arch", arch_mod);
    start_mod.addImport("kernel", kernel_mod);

    const kernel = b.addExecutable(.{
        .name = "ferrite.elf",
        .root_module = start_mod,
    });
    kernel.setLinkerScript(b.path(b.fmt("{s}/board/esp32c6/link/kernel_xip.ld", .{arch_dir})));
    kernel.entry = .{ .symbol_name = "_start" };
    kernel.pie = false;
    kernel.linkage = .static;
    kernel.bundle_compiler_rt = true;
    b.installArtifact(kernel);

    const wrap_kernel = b.addRunArtifact(kernelimage);
    wrap_kernel.addArg("--input");
    wrap_kernel.addFileArg(kernel.getEmittedBin());
    wrap_kernel.addArg("--output");
    const kernel_image = wrap_kernel.addOutputFileArg("kernel-esp32c6.bin");
    const install_kernel_image = b.addInstallBinFile(kernel_image, "kernel-esp32c6.bin");
    b.getInstallStep().dependOn(&install_kernel_image.step);

    // ReleaseSmall regardless of caller's -Doptimize. Debug + std
    // imports balloon the bootloader past its 144 KB SRAM allotment.
    const bootloader_mod = common.freestandingModule(
        b,
        b.path(b.fmt("{s}/board/esp32c6/bootloader.zig", .{arch_dir})),
        target,
        .ReleaseSmall,
        .default,
    );

    const bootloader = b.addExecutable(.{
        .name = "bootloader.elf",
        .root_module = bootloader_mod,
    });
    bootloader.setLinkerScript(b.path(b.fmt("{s}/board/esp32c6/link/bootloader.ld", .{arch_dir})));
    bootloader.entry = .{ .symbol_name = "_start" };
    bootloader.pie = false;
    bootloader.linkage = .static;
    bootloader.bundle_compiler_rt = true;
    b.installArtifact(bootloader);

    const wrap_bl = b.addRunArtifact(elf2espimage);
    wrap_bl.addArg("--input");
    wrap_bl.addFileArg(bootloader.getEmittedBin());
    wrap_bl.addArg("--output");
    const bl_image = wrap_bl.addOutputFileArg("bootloader-esp32c6.bin");
    const install_bl_image = b.addInstallBinFile(bl_image, "bootloader-esp32c6.bin");
    b.getInstallStep().dependOn(&install_bl_image.step);

    // Flash layout:
    //   0x000000  bootloader
    //   0x008000  partition table
    //   0x010000  kernel       (1.5 MB allotted, Debug kmain is ~1 MB)
    //   0x190000  initrd       (1 MB allotted)
    const KERNEL_OFFSET: u32 = 0x010000;
    const KERNEL_SIZE: u32 = 0x180000;
    const INITRD_OFFSET: u32 = 0x190000;
    const INITRD_SIZE: u32 = 0x100000;

    const ptable = b.addRunArtifact(partitiontable);
    ptable.addArg("--output");
    const ptable_bin = ptable.addOutputFileArg("partition-table.bin");
    ptable.addArg("--entry");
    ptable.addArg(b.fmt("kernel,offset=0x{x},size=0x{x},label=kernel", .{ KERNEL_OFFSET, KERNEL_SIZE }));
    if (initrd_lp) |_| {
        ptable.addArg("--entry");
        ptable.addArg(b.fmt("initrd,offset=0x{x},size=0x{x},label=initrd", .{ INITRD_OFFSET, INITRD_SIZE }));
    }
    const install_ptable = b.addInstallBinFile(ptable_bin, "partition-table-esp32c6.bin");
    b.getInstallStep().dependOn(&install_ptable.step);

    const port = b.option([]const u8, "esp-port", "Serial device (default: esptool auto-detect)") orelse "";
    const baud = b.option([]const u8, "esp-baud", "Flash baud rate (default 460800)") orelse "460800";

    const flash = b.addSystemCommand(&.{
        "esptool",
        "--chip",
        "esp32c6",
        "--baud",
        baud,
    });
    if (port.len != 0) {
        flash.addArg("--port");
        flash.addArg(port);
    }
    flash.addArgs(&.{ "write-flash", "0x0" });
    flash.addFileArg(bl_image);
    flash.addArg("0x8000");
    flash.addFileArg(ptable_bin);
    flash.addArg(b.fmt("0x{x}", .{KERNEL_OFFSET}));
    flash.addFileArg(kernel_image);
    if (initrd_lp) |lp| {
        flash.addArg(b.fmt("0x{x}", .{INITRD_OFFSET}));
        flash.addFileArg(lp);
    }
    const flash_step = b.step("flash", "Flash bootloader + partition table + kernel + initrd");
    flash_step.dependOn(&flash.step);

    const monitor_port = if (port.len != 0) port else "/dev/ttyACM0";
    const monitor = b.addSystemCommand(&.{ "tio", "-b", "115200", monitor_port });
    monitor.step.dependOn(&flash.step);
    const run_step = b.step("run", "Flash + open serial monitor");
    run_step.dependOn(&monitor.step);
}
