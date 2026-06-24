{
  description = "A flake for the clash-riscv workshop!";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Provides the RISC-V Rust toolchain (nightly + riscv32imc target) used to
    # build the firmware in firmware/.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  nixConfig = {
    extra-substituters = [ "https://clash-lang.cachix.org" ];
    extra-trusted-substituters = [ "https://clash-lang.cachix.org" ];
    extra-trusted-public-keys = [ "clash-lang.cachix.org-1:/2N1uka38B/heaOAC+Ztd/EWLmF0RLfizWgC5tamCBg=" ];
  };
  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        # RISC-V Rust toolchain (channel + targets from ./rust-toolchain.toml),
        # used to build the firmware in firmware/.
        rust-toolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;

        # What version of GHC you want to use.
        #
        # We provide a bare GHC + Cabal here and let `cabal` build everything in
        # cabal.project. We do
        # *not* use Nix to build the Haskell packages themselves.
        #
        # GHC 9.10 is required by the clash-cpus package: it depends on
        # clash-vexriscv (base >=4.18 && <4.22) and itself pins base ^>=4.20,
        # which is GHC 9.10. clash-riscv (clash-prelude >=1.10 && <1.12) builds
        # fine on 9.10 too.
        ghc-version = "ghc910";
        ghc = pkgs.haskell.compiler.${ghc-version};
        # Haskell tooling built against the same GHC, so HLS/fourmolu match the
        # compiler `cabal` uses.
        hs-pkgs = pkgs.haskell.packages.${ghc-version};

        # Options for `nix run`
        # Select the toplevel module
        top-module = "Workshop.Project";
        # Output VHDL or Verilog
        hdl = "verilog";
      in
        {
          # Develop the project using `nix develop`. Inside the shell, build with
          # `cabal build`, generate HDL with `nix run`, etc.
          devShells.default = pkgs.mkShell {
            nativeBuildInputs = [
              # Haskell toolchain. `cabal` resolves and builds all packages in
              # cabal.project (pulling clash-prelude, clash-vexriscv, etc. from
              # Hackage).
              ghc
              pkgs.cabal-install
              pkgs.haskellPackages.cabal-plan
              hs-pkgs.fourmolu
              hs-pkgs.haskell-language-server

              # Needed for Cabal to fetch + build `source-repository-package` git
              # dependencies declared in cabal.project.
              pkgs.git
              pkgs.cacert

              # Build-time toolchain for clash-vexriscv (used by clash-cpus): it
              # runs SpinalHDL (Scala) to emit Verilog, then verilates it and
              # builds an FFI library with make + a C compiler.
              pkgs.jre8
              pkgs.scala
              pkgs.sbt
              pkgs.verilator
              pkgs.gnumake

              # Native dependencies some Haskell packages link against.
              pkgs.pkg-config
              pkgs.zlib
              pkgs.gcc

              # RISC-V Rust toolchain for building the firmware (firmware/).
              rust-toolchain

              # Regular dependencies you may want to use in your project
              pkgs.hello
            ];

            shellHook = ''
              # Prevents Perl/locale warnings from some tools.
              export LC_ALL="C.UTF-8"
            '';
          };

          # Build the project with Clash and generate HDL.
          # Run with `nix run` from *inside* `nix develop`; outputs Verilog under
          # the `verilog` subdirectory. `top-module` and `hdl` are set above.
          apps.default = {
            type = "app";
            program = (pkgs.writeShellScript "compile" ''
              if [ -z "$IN_NIX_SHELL" ]; then
                echo "Run me from within a Nix developer shell!"
                echo "Simply run: nix develop"
                exit 1
              fi

              cabal build --write-ghc-environment-files=never
              cabal run clash ${top-module} -- --${hdl}
              echo "Removing" .ghc.environment.*
              rm -f .ghc.environment.*
            '').outPath;
          };
        }
    );
}
