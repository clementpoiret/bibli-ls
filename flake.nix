{
  description = "A simple LSP server for your bibliographies";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      uv2nix,
      pyproject-nix,
      pyproject-build-systems,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;

      # Load workspace from current directory
      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

      # Create package overlay from workspace
      overlay = workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
      };

      # Python sets grouped per system
      pythonSets = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Base Python package set from pyproject.nix
          baseSet = pkgs.callPackage pyproject-nix.build.packages {
            python = pkgs.python312;
          };

          # Build fixups for problematic packages
          # Those packages are using setuptools, so we need to pass setuptools
          # as a build input
          pyprojectOverrides = final: prev: {
            sgmllib3k = prev.sgmllib3k.overrideAttrs (old: {
              nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
                final.setuptools
              ];
            });

            ripgrepy = prev.ripgrepy.overrideAttrs (old: {
              nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
                final.setuptools
              ];
            });

            docstring-parser = prev.docstring-parser.overrideAttrs (old: {
              nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
                final.setuptools
              ];
            });

            # Add override for bibli-ls to ensure proper installation
            bibli-ls = prev.bibli-ls.overrideAttrs (old: {
              nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
                final.setuptools
                pkgs.makeWrapper
              ];

              # Ensure the package is properly installed with its entry points
              postInstall = ''
                for f in $out/bin/*; do
                  wrapProgram $f \
                    --prefix PYTHONPATH : $PYTHONPATH:$out/${final.python.sitePackages}
                done
              '';
            });
          };

        in
        baseSet.overrideScope (
          lib.composeManyExtensions [
            pyproject-build-systems.overlays.default
            overlay
            pyprojectOverrides
          ]
        )
      );

    in
    {
      packages = forAllSystems (
        system:
        let
          pythonSet = pythonSets.${system};
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.symlinkJoin {
            name = "bibli-ls";
            paths = [ pythonSet.bibli-ls ];
            buildInputs = [ pkgs.makeWrapper ];
            # Ensure Python path is properly set for the executable
            postBuild = ''
              for f in $out/bin/*; do
                wrapProgram $f \
                  --prefix PYTHONPATH : $PYTHONPATH:$out/${pythonSet.python.sitePackages}
              done
            '';
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Create editable overlay for development
          editableOverlay = workspace.mkEditablePyprojectOverlay {
            root = "$REPO_ROOT";
          };

          editablePythonSet = pythonSets.${system}.overrideScope editableOverlay;

          # Create development environment with all dependencies
          venv = editablePythonSet.mkVirtualEnv "bibli-ls-dev-env" workspace.deps.all;
        in
        {
          default = pkgs.mkShell {
            packages = [
              venv
              pkgs.uv
            ];
            shellHook = ''
              unset PYTHONPATH
              export REPO_ROOT=$(git rev-parse --show-toplevel)
              export UV_NO_SYNC=1
              export UV_PYTHON_DOWNLOADS=never
            '';
          };
        }
      );
    };
}
