const std = @import("std");

const zone_files = [_][]const u8{
    "africa",
    "antarctica",
    "asia",
    "australasia",
    "etcetera",
    "europe",
    "northamerica",
    "southamerica",
    "backward",
    "factory",
};

pub fn buildZoneinfo(b: *std.Build, optimize: std.builtin.OptimizeMode) std.Build.LazyPath {
    const dep = b.dependency("tzdata", .{});

    // Stand in for version.h that tzdata's Makefile would normally generate.
    const version_wf = b.addWriteFiles();
    const version_h = version_wf.add("version.h", "#define VERSION \"2025b\"\n");
    _ = version_wf.add("tzdir.h", "#ifndef TZDIR\n#define TZDIR \"/etc/zoneinfo\"\n#endif\n");

    const zic_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    zic_mod.addCSourceFile(.{
        .file = dep.path("zic.c"),
        .flags = &.{
            "-std=c99",
            "-DHAVE_GETTEXT=0",
            "-DHAVE_LINK=1",
            "-DHAVE_SYMLINK=1",
            "-DHAVE_STDINT_H=1",
            "-DHAVE_INTTYPES_H=1",
            "-DTZDEFAULT=\"/etc/localtime\"",
            "-DTZDIR=\"/etc/zoneinfo\"",
            "-DREPORT_BUGS_TO=\"https://github.com/Midstall/ferrite/issues\"",
            "-DPKGVERSION=\"ferrite-tzdata \"",
            "-DTZVERSION=\"2025b\"",
            "-Wno-format-truncation",
            "-Wno-format-overflow",
            "-Wno-unused-parameter",
        },
    });
    zic_mod.addIncludePath(dep.path("."));
    zic_mod.addIncludePath(version_h.dirname());

    const zic = b.addExecutable(.{
        .name = "zic",
        .root_module = zic_mod,
    });

    const run = b.addRunArtifact(zic);
    run.addArg("-b");
    run.addArg("slim");
    run.addArg("-d");
    const out = run.addOutputDirectoryArg("zoneinfo");
    for (zone_files) |zf| {
        run.addFileArg(dep.path(zf));
    }

    return out;
}
