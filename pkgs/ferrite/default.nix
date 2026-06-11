{
  lib,
  flakever,
  stdenv,
  mkShell,
  zig,
  qemu,
  limine-full,
  ovmfX86_64,
  ovmfAarch64,
  ubootRiscv64,
  xorriso,
  mtools,
  dosfstools,
  e2fsprogs,
  cpio,
  esptool,
  tio,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "ferrite";
  inherit (flakever) version;

  src = lib.cleanSource ../../.;

  zigDeps = zig.fetchDeps {
    inherit (finalAttrs) src pname version;
    hash = "sha256-tvyGHbB5fkls7zB6iSiIoMMRhgA29UZpCexG59eb5pc=";
  };

  nativeBuildInputs = [ zig ];

  postConfigure = ''
    ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  passthru.shell = mkShell {
    name = "ferrite-dev-shell";

    packages = [
      zig
      qemu
      limine-full
      xorriso
      mtools
      dosfstools
      e2fsprogs
      cpio
      esptool
      tio
    ];

    OVMF_X86_64_FD = "${ovmfX86_64.fd}/FV/OVMF.fd";
    OVMF_AARCH64_FD = "${ovmfAarch64.fd}/FV/AAVMF_CODE.fd";
    UBOOT_RISCV64 = "${ubootRiscv64}/u-boot.bin";
    LIMINE_DIR = "${limine-full}/share/limine";
  };
})
