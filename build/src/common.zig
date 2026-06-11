const std = @import("std");

pub const Board = enum {
    @"qemu-virt-aarch64",
    @"qemu-virt-riscv64",
    @"qemu-pc-i386",
    @"qemu-pc-x86_64",
    @"esp32-c6",
};

pub const GicVersion = enum { auto, v2, v3 };

/// Where `/` comes from. `initrd` keeps the boot cpio as root (default);
/// `ext4` builds an ext4 disk image from the userspace tree and boots off it
/// (root=/dev/blk0 rootfstype=ext4).
pub const RootfsType = enum { initrd, ext4 };

pub const BootProtocol = enum {
    raw,
    multiboot,
    multiboot2,
    limine,
    uefi,
    /// Espressif image format (header + segments + SHA-256). ROM loader
    /// reads this from flash. We supply our own second-stage bootloader.
    esp_image,
};

pub fn supports(board: Board, boot: BootProtocol) bool {
    return switch (board) {
        .@"qemu-virt-aarch64" => switch (boot) {
            .raw, .limine, .uefi => true,
            .multiboot, .multiboot2, .esp_image => false,
        },
        .@"qemu-virt-riscv64" => switch (boot) {
            .raw, .limine => true,
            // Zig 0.16 COFF writer can't emit riscv64 PE.
            .uefi => false,
            .multiboot, .multiboot2, .esp_image => false,
        },
        .@"qemu-pc-i386" => switch (boot) {
            .multiboot, .multiboot2 => true,
            .raw => false,
            // Limine dropped IA-32; OVMF-IA32 missing from nixpkgs.
            .limine => false,
            .uefi, .esp_image => false,
        },
        .@"qemu-pc-x86_64" => switch (boot) {
            .multiboot, .multiboot2, .limine, .uefi => true,
            // qemu -kernel rejects ELF64 without a multiboot header.
            .raw, .esp_image => false,
        },
        .@"esp32-c6" => switch (boot) {
            .esp_image => true,
            else => false,
        },
    };
}

pub fn defaultProtocol(board: Board) BootProtocol {
    return switch (board) {
        .@"qemu-virt-aarch64" => .raw,
        .@"qemu-virt-riscv64" => .raw,
        .@"qemu-pc-i386" => .multiboot,
        .@"qemu-pc-x86_64" => .multiboot,
        .@"esp32-c6" => .esp_image,
    };
}

pub fn aarch64ArchOptions(b: *std.Build, gic_version: GicVersion) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(GicVersion, "gic_version", gic_version);
    return options.createModule();
}

// Policy for deciding which optional CPU features the kernel uses at runtime.
//   detect  - trust runtime ID-register/CPUID/misa probing only
//   fixed   - trust the build-time -Dcpu feature set only (fully static)
//   auto    - prefer runtime detection; fall back to the build-time set per
//             feature when the silicon doesn't report it
pub const CpuFeaturesPolicy = enum { auto, detect, fixed };

pub const KernelOptions = struct {
    sig_max_keys: u32,
    page_size: u32,
    cpu_features: CpuFeaturesPolicy = .auto,
    hyp: bool = false,
    /// Whether this board wires conduit into the kernel module. The kernel uses
    /// it (kmain) only behind this comptime flag, so boards that do not provide
    /// the conduit import still compile.
    have_conduit: bool = false,
};

pub fn kernelOptions(b: *std.Build, opts: KernelOptions) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(u32, "sig_max_keys", opts.sig_max_keys);
    options.addOption(u32, "page_size", opts.page_size);
    options.addOption(CpuFeaturesPolicy, "cpu_features", opts.cpu_features);
    options.addOption(bool, "hyp", opts.hyp);
    options.addOption(bool, "have_conduit", opts.have_conduit);
    return options.createModule();
}

/// The conduit HAL module, built for the kernel's target. conduit's build.zig
/// wires its own transitive deps (dtree/almanac), so the kernel only ever talks
/// to conduit. Used by boards that set `have_conduit`.
pub fn conduitModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const dep = b.dependency("conduit", .{ .target = target, .optimize = optimize });
    return dep.module("conduit");
}

// virtio-net-pci + virtio-rng-pci with slirp v4/v6 + hostfwd 2222->22 + pcap.
// Both ipv4=on,ipv6=on required: setting either alone disables v4.
pub fn addQemuVirtioArgs(run_cmd: *std.Build.Step.Run, pcap_name: []const u8) void {
    const b = run_cmd.step.owner;
    run_cmd.addArgs(&.{
        "-netdev",
        "user,id=n0,ipv4=on,ipv6=on,hostfwd=tcp::2222-:22",
        "-device",
        "virtio-net-pci,disable-legacy=on,disable-modern=off,netdev=n0",
        "-object",
        b.fmt("filter-dump,id=pcap,netdev=n0,file=/tmp/{s}", .{pcap_name}),
        "-device",
        "virtio-rng-pci,disable-legacy=on,disable-modern=off",
        "-device",
        "virtio-gpu-pci,disable-legacy=on,disable-modern=off",
        "-device",
        "virtio-sound-pci,audiodev=snd0",
        "-device",
        "virtio-keyboard-pci,disable-legacy=on,disable-modern=off",
        "-device",
        "virtio-mouse-pci,disable-legacy=on,disable-modern=off",
        "-device",
        "virtio-tablet-pci,disable-legacy=on,disable-modern=off",
    });
    // The sound device needs a backend named snd0. Default to a silent one so
    // headless runs work; skip it if you bring your own (e.g. `zig build run --
    // -audiodev pa,id=snd0` to actually hear it, or `-audiodev wav,id=snd0,...`).
    const extra = b.args orelse &[_][]const u8{};
    var has_audiodev = false;
    for (extra) |a| {
        if (std.mem.eql(u8, a, "-audiodev")) has_audiodev = true;
    }
    if (!has_audiodev) run_cmd.addArgs(&.{ "-audiodev", "none,id=snd0" });
}

/// Append the display + pass-through tail to a QEMU run command. Anything after
/// `zig build run --` is forwarded to QEMU, so e.g. `zig build run -- -display gtk`
/// (or `-display sdl`) opens a window to watch the virtio-gpu output. We add
/// `-nographic` (headless, serial on stdio) only when you have not picked a
/// display yourself.
pub fn addQemuRunTail(run_cmd: *std.Build.Step.Run) void {
    const b = run_cmd.step.owner;
    const extra = b.args orelse &[_][]const u8{};
    var has_display = false;
    for (extra) |a| {
        if (std.mem.eql(u8, a, "-nographic") or
            std.mem.eql(u8, a, "-display") or
            std.mem.eql(u8, a, "-curses"))
        {
            has_display = true;
        }
    }
    if (!has_display) run_cmd.addArg("-nographic");
    run_cmd.addArgs(extra);
}

pub fn freestandingModule(
    b: *std.Build,
    src: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    code_model: std.builtin.CodeModel,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = src,
        .target = target,
        .optimize = optimize,
        .code_model = code_model,
        .pic = false,
        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,
        .single_threaded = true,
        .strip = false,
    });
}
