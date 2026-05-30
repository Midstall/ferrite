const std = @import("std");

pub const Tools = struct {
    keygen: *std.Build.Step.Compile,
    sigtool: *std.Build.Step.Compile,
    elf2macho: *std.Build.Step.Compile,
    elf2espimage: *std.Build.Step.Compile,
    kernelimage: *std.Build.Step.Compile,
    partitiontable: *std.Build.Step.Compile,
    cpio: *std.Build.Step.Compile,
    certdata2pem: *std.Build.Step.Compile,
};

const Spec = struct {
    name: []const u8,
    bin: []const u8,
    src: []const u8,
    description: []const u8,
    needs_common: bool = false,
    needs_partition: bool = false,
};

const all_tools: []const Spec = &.{
    .{
        .name = "keygen",
        .bin = "ferrite-keygen",
        .src = "tools/keygen.zig",
        .description = "Build & install ferrite-keygen (Ed25519 keypair generator)",
        .needs_common = true,
    },
    .{
        .name = "sigtool",
        .bin = "ferrite-sigtool",
        .src = "tools/sigtool.zig",
        .description = "Build & install ferrite-sigtool (Mach-O signing & verification)",
        .needs_common = true,
    },
    .{
        .name = "elf2macho",
        .bin = "ferrite-elf2macho",
        .src = "tools/elf2macho.zig",
        .description = "Build & install ferrite-elf2macho (wrap PIE ELF as signed Ferrite Mach-O)",
        .needs_common = true,
    },
    .{
        .name = "elf2espimage",
        .bin = "ferrite-elf2espimage",
        .src = "tools/elf2espimage.zig",
        .description = "Build & install ferrite-elf2espimage (wrap ELF as Espressif v3 boot image)",
        .needs_common = true,
    },
    .{
        .name = "kernelimage",
        .bin = "ferrite-kernelimage",
        .src = "tools/kernelimage.zig",
        .description = "Build & install ferrite-kernelimage (ESP32-C6 XIP kernel image builder)",
        .needs_common = true,
    },
    .{
        .name = "partitiontable",
        .bin = "ferrite-partitiontable",
        .src = "tools/partitiontable.zig",
        .description = "Build & install ferrite-partitiontable (ESP32-C6 flash partition table builder)",
        .needs_common = true,
        .needs_partition = true,
    },
    .{
        .name = "cpio",
        .bin = "ferrite-cpio",
        .src = "tools/cpio.zig",
        .description = "Build & install ferrite-cpio (cpio newc archive writer)",
        .needs_common = true,
    },
    .{
        .name = "certdata2pem",
        .bin = "ferrite-certdata2pem",
        .src = "tools/certdata2pem.zig",
        .description = "Build & install ferrite-certdata2pem (NSS certdata.txt -> PEM bundle)",
        .needs_common = true,
    },
};

pub fn register(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Tools {
    const umbrella = b.step("tools", "Build & install every host tool");
    var out: Tools = undefined;
    for (all_tools) |s| {
        const exe = compile(b, target, optimize, s);
        const install = b.addInstallArtifact(exe, .{});
        const step_name = std.fmt.allocPrint(b.allocator, "tools:{s}", .{s.name}) catch @panic("OOM");
        const step = b.step(step_name, s.description);
        step.dependOn(&install.step);
        umbrella.dependOn(&install.step);
        assignTool(&out, s.name, exe);
    }
    return out;
}

pub fn buildForHost(b: *std.Build, optimize: std.builtin.OptimizeMode) Tools {
    var out: Tools = undefined;
    for (all_tools) |s| {
        assignTool(&out, s.name, compile(b, b.graph.host, optimize, s));
    }
    return out;
}

fn compile(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    s: Spec,
) *std.Build.Step.Compile {
    const root_mod = b.createModule(.{
        .root_source_file = b.path(s.src),
        .target = target,
        .optimize = optimize,
    });
    if (s.needs_common) {
        root_mod.addImport("common", b.createModule(.{
            .root_source_file = b.path("tools/common.zig"),
            .target = target,
            .optimize = optimize,
        }));
    }
    if (s.needs_partition) {
        root_mod.addImport("partition", b.createModule(.{
            .root_source_file = b.path("kernel/src/arch/riscv32/board/esp32c6/partition.zig"),
            .target = target,
            .optimize = optimize,
        }));
    }
    return b.addExecutable(.{ .name = s.bin, .root_module = root_mod });
}

fn assignTool(out: *Tools, name: []const u8, exe: *std.Build.Step.Compile) void {
    if (std.mem.eql(u8, name, "keygen")) out.keygen = exe;
    if (std.mem.eql(u8, name, "sigtool")) out.sigtool = exe;
    if (std.mem.eql(u8, name, "elf2macho")) out.elf2macho = exe;
    if (std.mem.eql(u8, name, "elf2espimage")) out.elf2espimage = exe;
    if (std.mem.eql(u8, name, "kernelimage")) out.kernelimage = exe;
    if (std.mem.eql(u8, name, "partitiontable")) out.partitiontable = exe;
    if (std.mem.eql(u8, name, "cpio")) out.cpio = exe;
    if (std.mem.eql(u8, name, "certdata2pem")) out.certdata2pem = exe;
}
