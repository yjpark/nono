{
  description = "nono - capability-based sandboxing for AI agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, crane, rust-overlay, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        # Stable Rust; no rust-toolchain.toml in the repo (MSRV 1.74)
        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "clippy" "rustfmt" ];
        };

        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        # aws-lc-rs (used by nono-cli for TLS/crypto) vendors and compiles
        # AWS-LC (a BoringSSL fork), which requires cmake, perl, and a C compiler.
        nativeBuildInputs = with pkgs; [
          cmake
          perl
          pkg-config
        ];

        buildInputs = pkgs.lib.optionals pkgs.stdenv.isLinux (with pkgs; [
          # keyring sync-secret-service feature links against libdbus
          dbus
        ]) ++ pkgs.lib.optionals pkgs.stdenv.isDarwin (with pkgs; [
          darwin.apple_sdk.frameworks.Security
          darwin.apple_sdk.frameworks.CoreFoundation
          darwin.apple_sdk.frameworks.SystemConfiguration
        ]);

        src = craneLib.cleanCargoSource ./.;

        commonArgs = {
          inherit src nativeBuildInputs buildInputs;
          pname = "nono-workspace";
          version = "0.22.0";
          strictDeps = true;
        };

        # Build all dependencies once and cache the result
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # CLI binary (primary output)
        nonoCli = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;
          pname = "nono";
          cargoExtraArgs = "--package nono-cli";
        });

        # C FFI shared + static libraries
        nonoFfi = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;
          pname = "nono-ffi";
          cargoExtraArgs = "--package nono-ffi";
        });

      in
      {
        packages = {
          default = nonoCli;
          nono = nonoCli;
          nono-ffi = nonoFfi;
        };

        checks = {
          inherit nonoCli nonoFfi;

          clippy = craneLib.cargoClippy (commonArgs // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "--all-targets -- -D warnings -D clippy::unwrap_used";
          });

          fmt = craneLib.cargoFmt { inherit src; };

          tests = craneLib.cargoTest (commonArgs // {
            inherit cargoArtifacts;
          });
        };

        devShells.default = craneLib.devShell {
          inputsFrom = [ nonoCli ];
          packages = with pkgs; [
            cargo-audit
            cargo-watch
          ];
        };
      });
}
