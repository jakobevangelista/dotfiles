{ dotfilesPackages, pkgs, ... }:

let
  bridgeName = "virbr0";
  bridgeAddress = "10.88.0.1";
  stateDir = "/var/lib/huginn";
  prometheusTargetsDir = "/var/lib/prometheus-targets";

  dnsmasqConfig = pkgs.writeText "huginn-dnsmasq.conf" ''
    interface=${bridgeName}
    bind-interfaces
    listen-address=${bridgeAddress}
    dhcp-authoritative
    dhcp-range=10.88.0.100,10.88.0.250,255.255.255.0,12h
    dhcp-leasefile=${stateDir}/dnsmasq.leases
    dhcp-option=option:router,${bridgeAddress}
    dhcp-option=option:dns-server,${bridgeAddress}
    domain=huginn
    local=/huginn/
    domain-needed
    bogus-priv
    no-resolv
    server=1.1.1.1
    server=8.8.8.8
  '';
in {
  environment.systemPackages = [ dotfilesPackages.huginn ];
  environment.etc."huginn/base-manifest.json".source =
    dotfilesPackages.huginn-base-manifest;

  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  networking = {
    nat = {
      enable = true;
      externalInterface = "enp1s0";
      internalInterfaces = [ bridgeName ];
    };

    networkmanager.unmanaged = [
      "interface-name:${bridgeName}"
      "interface-name:th-*"
    ];

    firewall.interfaces.${bridgeName} = {
      allowedUDPPorts = [ 53 67 ];
      allowedTCPPorts = [ 53 ];
    };
  };

  systemd.network = {
    enable = true;

    netdevs."10-${bridgeName}".netdevConfig = {
      Kind = "bridge";
      Name = bridgeName;
    };

    networks."10-${bridgeName}" = {
      matchConfig.Name = bridgeName;
      addresses = [{ Address = "${bridgeAddress}/24"; }];
      networkConfig = {
        ConfigureWithoutCarrier = true;
        IPv4Forwarding = true;
      };
      linkConfig.RequiredForOnline = "no";
    };

    networks."20-huginn-taps" = {
      matchConfig.Name = "th-*";
      networkConfig.Bridge = bridgeName;
      linkConfig.RequiredForOnline = "no";
    };
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0755 root root - -"
    "d ${stateDir}/instances 0755 root root - -"
    "d ${prometheusTargetsDir} 0755 root root - -"
    "d /run/huginn 0755 root root - -"
  ];

  systemd.services.huginn-dnsmasq = {
    description = "dnsmasq for Huginn VMs";
    wantedBy = [ "multi-user.target" ];
    requires = [ "sys-subsystem-net-devices-${bridgeName}.device" ];
    after = [
      "systemd-networkd.service"
      "sys-subsystem-net-devices-${bridgeName}.device"
    ];
    serviceConfig = {
      ExecStartPre = "${pkgs.runtimeShell} -c 'for i in $(${pkgs.coreutils}/bin/seq 1 30); do ${pkgs.iproute2}/bin/ip -4 addr show dev ${bridgeName} | ${pkgs.gnugrep}/bin/grep -q ${bridgeAddress}/24 && exit 0; ${pkgs.coreutils}/bin/sleep 1; done; exit 1'";
      ExecStart =
        "${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --conf-file=${dnsmasqConfig}";
      Restart = "on-failure";
      RestartSec = "2s";
    };
  };
}
