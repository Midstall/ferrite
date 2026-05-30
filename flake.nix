{
  description = "A modular RT microkernel";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flakever.url = "github:numinit/flakever";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-parts,
      flakever,
      treefmt-nix,
      ...
    }@inputs:
    let
      flakeverConfig = flakever.lib.mkFlakever {
        inherit inputs;

        digits = [
          1
          2
          2
        ];
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.flake-parts.flakeModules.easyOverlay
        inputs.treefmt-nix.flakeModule
      ];

      flake.versionTemplate = "1.1pre-<lastModifiedDate>-<rev>";

      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];

      perSystem =
        {
          system,
          pkgs,
          ...
        }:
        let
          inherit (pkgs) lib;

          ovmfX86_64 = if system != "x86_64-linux" then pkgs.pkgsCross.gnu64.OVMF else pkgs.OVMF;
          ovmfAarch64 = if system != "aarch64-linux" then pkgs.pkgsCross.aarch64-multiplatform else pkgs.OVMF;
          ubootRiscv64 =
            if system != "riscv64-linux" then
              pkgs.pkgsCross.riscv64.ubootQemuRiscv64Smode
            else
              pkgs.ubootQemuRiscv64Smode;
        in
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [
              self.overlays.default
            ];
          };

          treefmt.programs = {
            clang-format.enable = true;
            nixfmt.enable = true;
            zig.enable = true;
          };

          overlayAttrs = {
            flakever = flakeverConfig;
            ferrite = pkgs.callPackage ./pkgs/ferrite {
              inherit ovmfX86_64 ovmfAarch64 ubootRiscv64;
            };
            ferrite-libc = pkgs.callPackage ./pkgs/ferrite-libc { };
          };

          packages.default = pkgs.ferrite;
          packages.ferrite-libc = pkgs.ferrite-libc;
          devShells.default = pkgs.ferrite.shell;
          legacyPackages = pkgs;
        };
    };
}
