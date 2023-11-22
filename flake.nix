{
  description = "evaluation robo-eyes";
  # nixConfig.bash-prompt = "nix-develop $ ";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Used for shell.nix
    flake-compat = {
      url = github:edolstra/flake-compat;
      flake = false;
    };

    zig.url = "github:mitchellh/zig-overlay";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  } @ inputs: let
    overlays = [
      # Other overlays
      (final: prev: {
        zigpkgs = inputs.zig.packages.${prev.system};
      })
    ];
    systems = builtins.attrNames inputs.zig.packages;
  in
    flake-utils.lib.eachSystem systems (system: 
      let
        pkgs = import nixpkgs {inherit overlays system; };
      in rec {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            zigpkgs."0.11.0"
            zon2nix
            python3
            python3Packages.matplotlib
            python3Packages.numpy
          ];

          buildInputs = with pkgs; [
            # we need a version of bash capable of being interactive
            # as opposed to a bash just used for building this flake 
            # in non-interactive mode
            bashInteractive 
          ];

          shellHook = ''
            # once we set SHELL to point to the interactive bash, neovim will 
            # launch the correct $SHELL in its :terminal 
            export SHELL=${pkgs.bashInteractive}/bin/bash
          '';

        };

        # For compatibility with older versions of the `nix` binary
        devShell = self.devShells.${system}.default;


        packages.apiguard-run = pkgs.writeShellScriptBin "apiguard.run" ''
            # set a XDG_CONFIG_HOME if in docker
            export XDG_CONFIG_HOME=''${XDG_CONFIG_HOME:-/tmp}

            # Define the path to the .env file
            ENV_PATH="''${XDG_CONFIG_HOME}/api_guard/api_guard.rc"

            # Load .env file from the specified path
            if [ -f "$ENV_PATH" ]; then
                export $(${pkgs.busybox}/bin/cat "$ENV_PATH" | ${pkgs.busybox}/bin/grep -v '^#' | ${pkgs.busybox}/bin/xargs)
            else
                # DOCKER 
                export $(${pkgs.busybox}/bin/cat "/tmp/api_guard/api_guard.rc" | ${pkgs.busybox}/bin/grep -v '^#' | ${pkgs.busybox}/bin/xargs)
            fi

            # start the server
            cd ${packages.apiguard}/bin
            ls 
            ${packages.apiguard}/bin/apiguard
        '';

        packages.default = packages.apiguard-run;

        packages.apiguard = pkgs.stdenvNoCC.mkDerivation rec {
          name = "apiguard";
          version = "master";
          src = ./.;
          buildInputs = [ pkgs.zigpkgs."0.11.0" ];
          dontConfigure = true;
          dontInstall = true;


          postPatch = ''
            mkdir -p .cache
            ln -s ${pkgs.callPackage ./deps.nix { }} .cache/p
          '';

          buildPhase = ''
            mkdir -p $out
            mkdir -p .cache/{p,z,tmp}
            # ReleaseSafe CPU:baseline (runs on all machines) MUSL 
            zig build install --cache-dir $(pwd)/zig-cache --global-cache-dir $(pwd)/.cache -Doptimize=ReleaseSafe -Dcpu=baseline -Dtarget=x86_64-linux-musl --prefix $out
            '';
        };

        # Usage:
        #    Prepare the env file as for apiguard_docker and use:
        #
        #    nix build .#apiguard_docker
        #    docker load < result
        #    docker run -p5500:5500 -v $(realpath rundir):/tmp apiguard:lastest
        #
        packages.apiguard_docker = pkgs.dockerTools.buildImage { # helper to build Docker image
          name = "apiguard";                          # give docker image a name
          tag = "latest";                               # provide a tag
          created = "now";

          copyToRoot = pkgs.buildEnv {
            name = "image-root";
            paths = [ packages.apiguard-run.out packages.apiguard.out pkgs.coreutils];  # .out seems to not make a difference
            pathsToLink = [ "/bin" "/tmp"];
          };

          config = {

            Cmd = [ "/bin/apiguard.run" ];
            WorkingDir = "/bin";

            Volumes = { 
                "/tmp" = { }; 
            };
            ExposedPorts = {
              "5500/tcp" = {};
            };

          };
        };
        # // end of packages
      }
    );
}
