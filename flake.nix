{
  description = "Rigor Ruby static analyzer development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          ruby = pkgs.ruby_4_0 or (throw "ruby_4_0 is not available in this nixpkgs revision; update nixpkgs or add a Ruby 4.0 overlay.");
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
        in
        {
          default = pkgs.mkShell {
            packages = [
              rubyEnv
              git
              pkgs.gnumake
            ];

            BUNDLE_PATH = "vendor/bundle";
            BUNDLE_BIN = "bin";
          };
        });
    };
}
