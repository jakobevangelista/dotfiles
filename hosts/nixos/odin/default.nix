{
  config,
  pkgs,
  ...
}:

let
  username = "jakob";
  macWifiIp = "10.0.0.230";
  macEthernetIp = "10.0.0.236";
  dockerLoopbackDefaults = {
    # Require an explicit host address for containers that should be reachable
    # from the LAN or tailnet.
    ip = "127.0.0.1";
    "default-network-opts".bridge = {
      "com.docker.network.bridge.host_binding_ipv4" = "127.0.0.1";
    };
  };
in
{
  imports = [
    ./hardware-configuration.nix
    ./huginn-vms.nix
  ];

  nixpkgs.config.allowUnfree = true;
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  networking = {
    hostName = "odin";
    networkmanager.enable = true;

    firewall = {
      trustedInterfaces = [ ];
      interfaces.tailscale0.allowedTCPPorts = [ 22 ];

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
    settings = {
      AllowUsers = [ username ];
      KbdInteractiveAuthentication = false;
      PasswordAuthentication = true;
      PermitRootLogin = "no";
      PubkeyAuthentication = true;
    };
  };

  services.tailscale = {
    enable = true;
    openFirewall = true;
  };

  virtualisation.docker = {
    # Keep the system daemon during the rootless migration. It remains
    # accessible through sudo after Jakob's group membership is refreshed.
    enable = true;

    rootless = {
      enable = true;
      setSocketVariable = true;
      daemon.settings = dockerLoopbackDefaults;
    };
  };

  # Rootful Docker publishes ports through forwarding rules rather than the
  # host INPUT chain. Block new tailnet connections there as well so that the
  # only tailnet service exposed by this host is SSH above.
  systemd.services.docker-tailnet-firewall = {
    description = "Restrict rootful Docker ingress from Tailscale";
    wantedBy = [
      "multi-user.target"
      "docker.service"
    ];
    partOf = [ "docker.service" ];
    after = [ "docker.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      firewall_bin=${config.networking.firewall.package}/bin

      if ! "$firewall_bin/iptables" -nL DOCKER-USER >/dev/null 2>&1; then
        echo "Docker did not create the IPv4 DOCKER-USER chain" >&2
        exit 1
      fi

      "$firewall_bin/iptables" -C DOCKER-USER -i tailscale0 \
        -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        "$firewall_bin/iptables" -I DOCKER-USER 1 -i tailscale0 \
          -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
      "$firewall_bin/iptables" -C DOCKER-USER -i tailscale0 -j DROP 2>/dev/null || \
        "$firewall_bin/iptables" -I DOCKER-USER 2 -i tailscale0 -j DROP

      if "$firewall_bin/ip6tables" -nL DOCKER-USER >/dev/null 2>&1; then
        "$firewall_bin/ip6tables" -C DOCKER-USER -i tailscale0 \
          -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
          "$firewall_bin/ip6tables" -I DOCKER-USER 1 -i tailscale0 \
            -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        "$firewall_bin/ip6tables" -C DOCKER-USER -i tailscale0 -j DROP 2>/dev/null || \
          "$firewall_bin/ip6tables" -I DOCKER-USER 2 -i tailscale0 -j DROP
      fi
    '';
  };

  programs.zsh.enable = true;

  security.sudo = {
    execWheelOnly = true;
    extraConfig = ''
      Defaults timestamp_timeout=0
    '';
  };

  users.users.${username} = {
    isNormalUser = true;
    description = "Jakob Evangelista";
    linger = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.zsh;
  };

  environment.systemPackages = with pkgs; [
    curl
    git
    gnumake
    grok
    openssl
    vim
    wget
  ];

  # Keep this at the release used for the first install.
  system.stateVersion = "25.05";
}
