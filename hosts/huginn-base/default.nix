{ pkgs, ... }:

{
  system.stateVersion = "25.05";

  boot.loader.grub.enable = false;
  boot.supportedFilesystems = [ "virtiofs" ];
  boot.initrd.availableKernelModules = [
    "fuse"
    "overlay"
    "virtio_pci"
    "virtiofs"
  ];

  fileSystems."/" = {
    device = "rootfs";
    fsType = "tmpfs";
    options = [ "size=4G" "mode=0755" ];
    neededForBoot = true;
  };

  fileSystems."/nix/.ro-store" = {
    device = "ro-store";
    fsType = "virtiofs";
    options = [ "ro" ];
    neededForBoot = true;
  };

  fileSystems."/nix/.rw-store" = {
    device = "rw-store";
    fsType = "tmpfs";
    options = [ "mode=0755" ];
    neededForBoot = true;
  };

  fileSystems."/nix/store" = {
    neededForBoot = true;
    overlay = {
      lowerdir = [ "/nix/.ro-store" ];
      upperdir = "/nix/.rw-store/upper";
      workdir = "/nix/.rw-store/work";
    };
  };

  fileSystems."/run/huginn/metadata" = {
    device = "metadata";
    fsType = "virtiofs";
    options = [ "nofail" ];
  };

  networking = {
    hostName = "huginn-base";
    useDHCP = false;
    useNetworkd = true;
    firewall.allowedTCPPorts = [ 9100 ];
  };

  systemd.network = {
    enable = true;
    networks."10-ether" = {
      matchConfig.Type = "ether";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = false;
      };
    };
  };

  systemd.tmpfiles.rules = [
    "d /run/huginn 0755 root root - -"
  ];

  systemd.services.huginn-metadata = {
    description = "Apply Huginn VM metadata";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -euo pipefail

      metadata=/run/huginn/metadata
      hostname_file=$metadata/hostname

      if [ -r "$hostname_file" ]; then
        hostname="$(${pkgs.coreutils}/bin/tr -cd 'A-Za-z0-9.-' < "$hostname_file" | ${pkgs.coreutils}/bin/head -c 63)"
        if [ -n "$hostname" ]; then
          ${pkgs.systemd}/bin/hostnamectl set-hostname "$hostname" || true
        fi
      fi
    '';
  };

  services.openssh = {
    enable = true;
    settings = {
      KbdInteractiveAuthentication = false;
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  users.users.jakob = {
    isNormalUser = true;
    description = "Jakob Evangelista";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIlygks670GFZRs9qEinFIZspiSciH7gD47Bougpcz3O odin"
    ];
  };

  environment.systemPackages = with pkgs; [
    curl
    fd
    git
    jq
    neovim
    nodejs
    python3
    ripgrep
    tmux
  ];

  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "0.0.0.0";
    port = 9100;
  };
}
