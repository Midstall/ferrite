{
  lib,
  flakever,
  stdenvNoCC,
  buildPackages,
}:
let
  # zig is a build-time tool, always run on the build host. In a
  # cross-splice context the bare `zig` argument would resolve to a
  # cross-compiled zig (zig-static-aarch64-unknown-ferrite), which would
  # need the cross stdenv we're trying to construct, closing a loop.
  zig = buildPackages.zig;
in
# Self-contained derivation: we deliberately do NOT inherit from the
# `ferrite` package the way we used to. cc-wrapper for the cross stdenv
# under `pkgsCross.<arch>-ferrite.*` consumes ferrite-libc as its libc,
# so if ferrite-libc reaches for the (cross-spliced) `ferrite` it closes
# a recursion: cross-stdenv → cc-wrapper → ferrite-libc → ferrite →
# cross-stdenv.
#
# stdenvNoCC because zig brings its own complete toolchain. We don't
# need a system cc at all, which also keeps us free of the cc-wrapper
# loop.
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "ferrite-libc";
  inherit (flakever) version;

  src = lib.cleanSource ../../.;

  zigDeps = zig.fetchDeps {
    inherit (finalAttrs) src pname version;
    hash = "sha256-tvyGHbB5fkls7zB6iSiIoMMRhgA29UZpCexG59eb5pc=";
  };

  nativeBuildInputs = [ zig ];

  outputs = [
    "out"
    "dev"
  ];

  postConfigure = ''
    ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  buildPhase = ''
    runHook preBuild
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    zig build libc -j$NIX_BUILD_CORES -Dminimal=true --prefix $out --verbose
    runHook postInstall
  '';

  meta = {
    description = "Ferrite freestanding libc (libferrite_libc.a + headers)";
    platforms = lib.platforms.unix;
  };
})
