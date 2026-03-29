{
  description = "Rove: a personal execution CLI for on-demand remote compute";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f:
        lib.genAttrs systems (system:
          f {
            inherit system;
            pkgs = import nixpkgs { inherit system; };
          });
    in
    {
      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixpkgs-fmt);

      packages = forAllSystems ({ pkgs, ... }: {
        default = pkgs.stdenv.mkDerivation {
          pname = "rove";
          version = "0.1.0";
          src = self;
          strictDeps = true;

          nativeBuildInputs = [
            pkgs.zig
          ];

          dontConfigure = true;
          dontStrip = true;

          buildPhase = ''
            runHook preBuild
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
            export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
            zig build install --prefix "$out" -Doptimize=ReleaseSafe
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            runHook postInstall
          '';
        };
      });

      apps = forAllSystems ({ system, ... }: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/rove";
        };
      });

      devShells = forAllSystems ({ pkgs, ... }: {
        default = pkgs.mkShell {
          packages =
            with pkgs;
            [
              zig
              git
              openssh
              rsync
              tmux
              jq
              shellcheck
            ]
            ++ lib.optional (pkgs ? zls) pkgs.zls
            ++ lib.optional (pkgs ? flyctl) pkgs.flyctl;

          shellHook = ''
            echo "Rove dev shell"
            echo "Available commands: zig build, zig build test, nix run . -- status"
          '';
        };
      });
    };
}
