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

  outputs = { self, nixpkgs, nix-darwin, home-manager, ... }:
    let
      darwinUsername = "jakobevangelista";
      odinUsername = "jakob";
      linuxSystem = "x86_64-linux";
      linuxPkgs = nixpkgs.legacyPackages.${linuxSystem};
      localPackagesOverlay = _final: prev: {
        codex = prev.callPackage ./pkgs/codex { };
        opencode = prev.callPackage ./pkgs/opencode {
          opencode = prev.opencode;
        };
      };
    in {
      packages.${linuxSystem} = {
        huginn = linuxPkgs.callPackage ./pkgs/huginn { };

        huginn-base-manifest =
          let cfg = self.nixosConfigurations.huginn-base.config;
          in linuxPkgs.writeText "huginn-base-manifest.json" (builtins.toJSON {
            kernel = "${cfg.system.build.kernel}/${cfg.system.boot.loader.kernelFile}";
            initrd = "${cfg.system.build.initialRamdisk}/${cfg.system.boot.loader.initrdFile}";
            system = "${cfg.system.build.toplevel}";
            cmdline = "console=ttyS0 reboot=t panic=-1 init=${cfg.system.build.toplevel}/init";
          });
      };

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

      nixosConfigurations."huginn-base" = nixpkgs.lib.nixosSystem {
        system = linuxSystem;
        modules = [ ./hosts/huginn-base ];
      };

      nixosConfigurations."odin" = nixpkgs.lib.nixosSystem {
        system = linuxSystem;
        specialArgs = { dotfilesPackages = self.packages.${linuxSystem}; };
        modules = [
          ./hosts/nixos/odin
          home-manager.nixosModules.home-manager
          { nixpkgs.overlays = [ localPackagesOverlay ]; }
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.${odinUsername} = import ./homes/odin.nix;
          }
        ];
      };
    };
}
