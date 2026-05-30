{
  description = "Jakob's Darwin and NixOS dotfiles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin = {
      url = "github:LnL7/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, nix-darwin, home-manager, ... }:
    let
      darwinUsername = "jakobevangelista";
      odinUsername = "jakob";
      opencodeOverlay = _final: prev: {
        opencode = prev.callPackage ./pkgs/opencode {
          opencode = prev.opencode;
        };
      };
    in {
      darwinConfigurations."jakobs-goated-inngest-macbook" =
        nix-darwin.lib.darwinSystem {
          system = "aarch64-darwin";
          modules = [
            ./darwin.nix
            home-manager.darwinModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.${darwinUsername} = import ./home.nix;
            }
          ];
        };

      nixosConfigurations."odin" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./hosts/nixos/odin
          home-manager.nixosModules.home-manager
          { nixpkgs.overlays = [ opencodeOverlay ]; }
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.${odinUsername} = import ./homes/odin.nix;
          }
        ];
      };
    };
}
