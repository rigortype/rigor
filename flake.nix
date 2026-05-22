{
  description = "Rigor Ruby static analyzer development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      # Ruby 4.0.5 — shared by the dev shell and the packaged
      # `rigor` executable. Bump via the rigor-ruby-version-bump
      # skill (flake.nix is Step 1).
      mkRuby = pkgs:
        (pkgs.mkRuby {
          version = pkgs.mkRubyVersion "4" "0" "5" "";
          hash = "sha256-fWFJB5pj+K4dMmyfplxgGbotwxVerns5FZgXkRyIlY4=";
          cargoHash = "sha256-z7NwWc4TaR042hNx0xgRkh/BQEpEJtE53cfrN0qNiE0=";
        }).override {
          docSupport = false;
        };
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          ruby = mkRuby pkgs;
          rubyEnv = ruby.withPackages (ps: [
            ps.rake
          ]);
          git = pkgs.git.overrideAttrs (oldAttrs: {
            version = "2.54.0";
            src = pkgs.fetchurl {
              url = "https://www.kernel.org/pub/software/scm/git/git-2.54.0.tar.xz";
              hash = "sha256-9okWI2TBDeee+Jqo2/SHMesFfjTtu9IKylEM4BVGgaM=";
            };
            patches = builtins.filter (
              patch:
              !(pkgs.lib.hasInfix "osxkeychain-define-build-targets-in-toplevel-Makefile.patch" (toString patch))
            ) oldAttrs.patches;
          });

          # microsoft/waza — CLI / framework for Agent Skills evaluation
          # (quantitative grading, token-budget analysis, eval scaffolding).
          # Distributed as static Go binaries; no `go install` because of
          # embedded Git LFS copilot artefacts, so we ship the upstream
          # release binary directly per platform. License: MIT.
          wazaVersion = "0.31.0";
          wazaAssets = {
            "aarch64-darwin" = {
              asset = "waza-darwin-arm64";
              hash = "sha256-gMMK9rUdePY5UMhGhFvFJeeHixzfaJV7r91Jh0/6FfE=";
            };
            "x86_64-darwin" = {
              asset = "waza-darwin-amd64";
              hash = "sha256-1bixv2g1gULHOBeXgbRKhecJ5KHOzPNKt8E+ykQn3S4=";
            };
            "aarch64-linux" = {
              asset = "waza-linux-arm64";
              hash = "sha256-oooOfWSh1IK9PMdAX42phZv83o279skUT/BRpcSFlfE=";
            };
            "x86_64-linux" = {
              asset = "waza-linux-amd64";
              hash = "sha256-vD2wYJcE0WPpDPexF/MbIUgsATciAGaiCHFNwxKV594=";
            };
          };
          waza = pkgs.stdenv.mkDerivation {
            pname = "waza";
            version = wazaVersion;
            src = pkgs.fetchurl {
              url = "https://github.com/microsoft/waza/releases/download/v${wazaVersion}/${wazaAssets.${system}.asset}";
              hash = wazaAssets.${system}.hash;
            };
            dontUnpack = true;
            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              install -m 0755 $src $out/bin/waza
              runHook postInstall
            '';
            meta = with pkgs.lib; {
              description = "CLI / framework for Agent Skills - create, test, measure and improve skill quality and effectiveness";
              homepage = "https://github.com/microsoft/waza";
              license = licenses.mit;
              platforms = builtins.attrNames wazaAssets;
              sourceProvenance = with sourceTypes; [ binaryNativeCode ];
            };
          };
        in
        {
          default = pkgs.mkShell {
            packages = [
              rubyEnv
              git
              pkgs.gnumake
              pkgs.bundix
              waza
            ];

            BUNDLE_PATH = "vendor/bundle";
            BUNDLE_BIN = "bin";
          };
        });

      # The packaged `rigor` executable — Ruby 4.0 plus the runtime
      # gems in its closure, so `nix run` / `nix profile install`
      # need nothing else on the host (ADR-27 slice 2).
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          ruby = mkRuby pkgs;

          # rigortype's runtime dependencies, resolved from
          # nix/Gemfile + nix/gemset.nix. Regenerate after a
          # dependency change with `cd nix && bundle lock && bundix`.
          rigorDeps = pkgs.bundlerEnv {
            name = "rigortype-deps";
            inherit ruby;
            gemdir = ./nix;
          };

          version =
            let
              m = builtins.match ''[^"]*"([^"]+)"[^"]*''
                (builtins.readFile ./lib/rigor/version.rb);
            in
            builtins.head m;

          rigor = pkgs.stdenv.mkDerivation {
            pname = "rigortype";
            inherit version;

            src = pkgs.lib.fileset.toSource {
              root = ./.;
              fileset = pkgs.lib.fileset.unions [
                ./lib
                ./exe
                ./data
                ./sig
              ];
            };

            nativeBuildInputs = [ pkgs.makeWrapper ];
            dontConfigure = true;
            dontBuild = true;

            # rigortype is pure Ruby — its own code is copied in and
            # `exe/rigor` is wrapped against a Ruby carrying the
            # runtime gems. The script puts its own lib/ on the load
            # path relative to itself.
            installPhase = ''
              runHook preInstall
              mkdir -p $out/share/rigor $out/bin
              cp -r lib exe data sig $out/share/rigor/
              makeWrapper ${rigorDeps.wrappedRuby}/bin/ruby $out/bin/rigor \
                --add-flags "$out/share/rigor/exe/rigor"
              runHook postInstall
            '';

            meta = with pkgs.lib; {
              description = "Inference-first static analysis for Ruby";
              homepage = "https://github.com/rigortype/rigor";
              license = licenses.mpl20;
              mainProgram = "rigor";
              platforms = systems;
            };
          };
        in
        {
          default = rigor;
          rigor = rigor;
        });

      apps = forAllSystems (system:
        let
          program = "${self.packages.${system}.default}/bin/rigor";
        in
        {
          default = {
            type = "app";
            inherit program;
          };
          rigor = {
            type = "app";
            inherit program;
          };
        });
    };
}
