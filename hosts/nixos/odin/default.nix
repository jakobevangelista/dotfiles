{ pkgs, ... }:

let username = "jakob";
in {
  imports = [
    ./hardware-configuration.nix
    ./huginn-vms.nix
  ];

  nixpkgs.config.allowUnfree = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  networking = {
    hostName = "odin";
    networkmanager.enable = true;
  };

  time.timeZone = "Etc/UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # Change this before install if the server is not UEFI/systemd-boot.
  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  services.openssh.enable = true;

  services.tailscale = {
    enable = true;
    openFirewall = true;
  };

  programs.zsh.enable = true;

  users.users.${username} = {
    isNormalUser = true;
    description = "Jakob Evangelista";
    extraGroups = [ "wheel" "networkmanager" ];
    shell = pkgs.zsh;
  };

  environment.systemPackages = with pkgs; [ curl git vim wget ];

  # Keep this at the release used for the first install.
  system.stateVersion = "25.05";
}
