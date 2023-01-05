{
  description = "cardano coin selection algorithms";

  inputs = {
    nixpkgs = {
      follows = "haskell-nix/nixpkgs-unstable";
    };

    haskell-nix = {
      url = "github:input-output-hk/haskell.nix";
      inputs.nixpkgs.follows = "haskell-nix/nixpkgs-2111";
    };

    plutus-flake-utils = {
      url = "github:chessai/plutus-flake-utils/bea038937c0626a76f0085bdc57d0bb55b2232d6";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        haskell-nix.follows = "haskell-nix";
      };
    };

    flake-utils = {
      url = "github:numtide/flake-utils";
    };

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs =
    { self
    , nixpkgs
    , haskell-nix
    , plutus-flake-utils
    , flake-utils
    , ...
    }:
    let
      # can be extended if we ever have anyone on MacOS or need to cross compile.
      # systems outside of this list have not been tested
      supportedSystems =
        [ "x86_64-linux" ];

      projectArgs = isDocker: {
        packages = [
          "cardano-coin-selection"
        ];
        src = ./.;
        compiler-nix-name = "ghc8107";
      };
    in
    flake-utils.lib.eachSystem supportedSystems (system: {
      pkgs = plutus-flake-utils.pkgs system;

      # we build everything unoptimised except for the docker image
      # which is only built on `main`
      inherit (plutus-flake-utils.plutusProject system (projectArgs false))
        project flake devShell;
    });
}
