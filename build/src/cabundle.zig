const std = @import("std");
const tools_mod = @import("tools.zig");

pub fn buildBundle(b: *std.Build, certdata2pem: *std.Build.Step.Compile) std.Build.LazyPath {
    _ = tools_mod;
    const nss = b.dependency("nss", .{});
    const run = b.addRunArtifact(certdata2pem);
    run.addFileArg(nss.path("lib/ckfw/builtins/certdata.txt"));
    return run.addOutputFileArg("ca-bundle.pem");
}
