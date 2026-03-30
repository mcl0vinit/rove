{
  description = "Rove Fly devbox base package set";

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
      packages = forAllSystems ({ pkgs, ... }: {
        default = pkgs.buildEnv {
          name = "rove-fly-devbox";
          paths =
            with pkgs;
            [
              bashInteractive
              cacert
              coreutils
              curl
              direnv
              fd
              findutils
              gh
              git
              gnugrep
              gnutar
              gzip
              jq
              less
              nix
              nix-direnv
              openssh
              ripgrep
              rsync
              tmux
              unzip
              vim
              which
              zip
            ]
            ++ lib.optionals pkgs.stdenv.isLinux [
              procps
            ];
        };
      });
    };
}
