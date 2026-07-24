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
      aiUpdaters = linuxPkgs.callPackage ./pkgs/ai-updaters { };
      localPackagesOverlay = _final: prev: {
        amp-cli = prev.callPackage ./pkgs/amp-cli { };
        claude-code = prev.callPackage ./pkgs/claude-code { };
        codex = prev.callPackage ./pkgs/codex { };
        grok = prev.callPackage ./pkgs/grok { };
        opencode = prev.callPackage ./pkgs/opencode {
          opencode = prev.opencode;
        };
      };
    in {
      packages.${linuxSystem} = {
        inherit (aiUpdaters)
          update-ai-tools
          update-amp
          update-claude-code
          update-codex
          update-grok
          update-opencode;

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

      apps.${linuxSystem} =
        let
          mkUpdaterApp = name: {
            type = "app";
            program = "${self.packages.${linuxSystem}.${name}}/bin/${name}";
          };
        in {
          update-ai-tools = mkUpdaterApp "update-ai-tools";
          update-amp = mkUpdaterApp "update-amp";
          update-claude-code = mkUpdaterApp "update-claude-code";
          update-codex = mkUpdaterApp "update-codex";
          update-grok = mkUpdaterApp "update-grok";
          update-opencode = mkUpdaterApp "update-opencode";
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
