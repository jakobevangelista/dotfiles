{ pkgs, ... }:

let
  username = "jakob";
  macWifiIp = "10.0.0.230";
  macEthernetIp = "10.0.0.236";
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

    firewall = {
      trustedInterfaces = [ "tailscale0" ];

      # LAN fallback for Jakob's MacBook. Keep these IPs reserved in DHCP.
      extraCommands = ''
        iptables -C nixos-fw -i enp6s0 -p tcp -s ${macWifiIp} --dport 22 -j nixos-fw-accept 2>/dev/null || \
          iptables -I nixos-fw -i enp6s0 -p tcp -s ${macWifiIp} --dport 22 -j nixos-fw-accept
        iptables -C nixos-fw -i enp6s0 -p tcp -s ${macEthernetIp} --dport 22 -j nixos-fw-accept 2>/dev/null || \
          iptables -I nixos-fw -i enp6s0 -p tcp -s ${macEthernetIp} --dport 22 -j nixos-fw-accept
      '';
      extraStopCommands = ''
        iptables -D nixos-fw -i enp6s0 -p tcp -s ${macWifiIp} --dport 22 -j nixos-fw-accept 2>/dev/null || true
        iptables -D nixos-fw -i enp6s0 -p tcp -s ${macEthernetIp} --dport 22 -j nixos-fw-accept 2>/dev/null || true
      '';
    };
  };

  time.timeZone = "Etc/UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # Change this before install if the server is not UEFI/systemd-boot.
  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  services.openssh = {
    enable = true;
    openFirewall = false;
    settings.AllowUsers = [ username ];
  };

  services.tailscale = {
    enable = true;
    openFirewall = true;
  };

  virtualisation.docker.enable = true;

  programs.zsh.enable = true;

  users.users.${username} = {
    isNormalUser = true;
    description = "Jakob Evangelista";
    extraGroups = [ "wheel" "networkmanager" "docker" ];
    shell = pkgs.zsh;
  };

  environment.systemPackages = with pkgs; [
    curl
    git
    vim
    wget
  ];

  # Keep this at the release used for the first install.
  system.stateVersion = "25.05";
}
