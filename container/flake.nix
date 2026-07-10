{
  # Intentionally no flake.lock is committed alongside this file: each image build
  # re-locks nixpkgs to latest so the weekly CI rebuild ships fresh agent CLIs. Commit
  # a lock here only if you want byte-reproducible images instead.
  description = "capsule container image — home-manager profile for the agent user";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, home-manager, ... }:
    {
      # Named after the system so the Dockerfile can pick with `uname -m`.
      homeConfigurations = nixpkgs.lib.genAttrs [ "aarch64-linux" "x86_64-linux" ] (
        system:
        home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          modules = [ ./home.nix ];
        }
      );
    };
}
