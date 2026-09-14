{
  config,
  lib,
  pkgs,
  ...
}:

{
  system.stateVersion = "25.05";

  nixpkgs.config.allowUnfree = true;
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  boot.loader.grub.enable = false;
  boot.initrd = {
    systemd.enable = true;
    availableKernelModules = [
      "ext4"
      "fuse"
      "overlay"
      "virtio_blk"
      "virtio_pci"
      "virtiofs"
    ];
  };
  boot.supportedFilesystems = [ "virtiofs" ];

  # The operating system remains declarative and disposable. Muninn's state
  # disk supplies the persistent Nix upper layer, home, Docker data, SSH host
  # identity, and Tailscale identity.
  fileSystems."/" = {
    device = "rootfs";
    fsType = "tmpfs";
    options = [
      "size=8G"
      "mode=0755"
    ];
    neededForBoot = true;
  };

  fileSystems."/persist" = {
    device = "/dev/disk/by-label/muninn-state";
    fsType = "ext4";
    options = [ "noatime" ];
    neededForBoot = true;
  };

  fileSystems."/nix/.ro-store" = {
    device = "ro-store";
    fsType = "virtiofs";
    options = [ "ro" ];
    neededForBoot = true;
  };

  fileSystems."/nix/store" = {
    depends = [
      "/persist"
      "/nix/.ro-store"
    ];
    neededForBoot = true;
    overlay = {
      lowerdir = [ "/nix/.ro-store" ];
      upperdir = "/persist/nix-store/upper";
      workdir = "/persist/nix-store/work";
    };
  };

  fileSystems."/nix/var/nix" = {
    device = "/persist/nix-var";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/persist" ];
  };

  fileSystems."/home/jakob" = {
    device = "/persist/home/jakob";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/persist" ];
  };

  fileSystems."/var/lib/docker" = {
    device = "/persist/var-lib-docker";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/persist" ];
  };

  fileSystems."/var/lib/tailscale" = {
    device = "/persist/var-lib-tailscale";
    fsType = "none";
    options = [
      "bind"
      "x-systemd.requires=muninn-tailscale-state.service"
    ];
    depends = [ "/persist" ];
  };

  # Existing state disks predate Tailscale. Prepare the source before the bind
  # mount, rather than relying on the first-disk skeleton or late tmpfiles.
  systemd.services.muninn-tailscale-state = {
    description = "Prepare persistent Muninn Tailscale state";
    unitConfig = {
      DefaultDependencies = false;
      RequiresMountsFor = [ "/persist" ];
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root /persist/var-lib-tailscale";
    };
  };

  # These paths are the host's live working trees, not copies or overlays.
  fileSystems."/home/jakob/inngest-work" = {
    device = "inngest-work";
    fsType = "virtiofs";
    options = [
      "nofail"
      "rw"
    ];
    depends = [ "/home/jakob" ];
  };

  fileSystems."/home/jakob/personal" = {
    device = "personal";
    fsType = "virtiofs";
    options = [
      "nofail"
      "rw"
    ];
    depends = [ "/home/jakob" ];
  };

  fileSystems."/home/jakob/dotfiles" = {
    device = "dotfiles";
    fsType = "virtiofs";
    options = [
      "nofail"
      "rw"
    ];
    depends = [ "/home/jakob" ];
  };

  # Agent state is shared live so conversations started on Odin can be resumed
  # from the same worktree path in Muninn. Do not use the same conversation
  # concurrently on both systems.
  # Codex's SQLite databases remain private on the state disk. Only portable
  # transcripts and selected configuration files are exposed from Odin.
  fileSystems."/run/muninn-host/codex" = {
    device = "codex-state";
    fsType = "virtiofs";
    options = [
      "nofail"
      "rw"
    ];
  };

  fileSystems."/run/muninn-host/codex-sessions" = {
    device = "codex-sessions";
    fsType = "virtiofs";
    options = [
      "nofail"
      "rw"
    ];
  };

  fileSystems."/home/jakob/.claude" = {
    device = "claude-state";
    fsType = "virtiofs";
    options = [
      "nofail"
      "rw"
    ];
    depends = [ "/home/jakob" ];
  };

  # OpenCode keeps conversations in a WAL-mode SQLite database, which cannot
  # safely be used directly over virtiofs. This is a read-only import source;
  # `muninn import-opencode` copies it to the private state disk once.
  fileSystems."/run/muninn-host/opencode" = {
    device = "opencode-state";
    fsType = "virtiofs";
    options = [
      "nofail"
      "ro"
    ];
  };

  fileSystems."/home/jakob/.local/share/amp" = {
    device = "amp-state";
    fsType = "virtiofs";
    options = [
      "nofail"
      "rw"
    ];
    depends = [ "/home/jakob" ];
  };

  networking = {
    hostName = "muninn";
    useDHCP = false;
    useNetworkd = true;
    firewall.allowedTCPPorts = [ 22 ];
  };

  services.tailscale = {
    enable = true;
    # Backport the upstream 1.98 fix: link changes otherwise drop MagicDNS
    # routes (including when Docker's bridge appears during guest boot).
    # Remove this override after the pinned nixpkgs provides a fixed release.
    package = pkgs.tailscale.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [
        (pkgs.fetchurl {
          url = "https://github.com/tailscale/tailscale/commit/b192880cb4850248ee8d1997b247709eb85c6d56.patch";
          hash = "sha256-VvADlFt56q4GPLtinBA/QBSIbKQp9Jmg+3HTJ4u7L4w=";
        })
      ];
      doCheck = true;
      checkPhase = ''
        runHook preCheck
        go test -p "$NIX_BUILD_CORES" ./cmd/cloner ./wgengine \
          -run '^(TestMapSlicePointerContainerNilValue|TestLinkChangeReapplyPreservesMagicDNSRoutes)$' \
          -count=1 -timeout=120s
        runHook postCheck
      '';
    });
    openFirewall = true; # Only the daemon's UDP port (41641).
    useRoutingFeatures = "none";
    extraSetFlags = [
      "--accept-dns=true"
      # Ashburn Kubernetes APIs use IPv6 subnets advertised by work bastions.
      "--accept-routes=true"
      "--advertise-exit-node=false"
      "--advertise-routes="
      "--ssh=true" # Tailnet identity authenticates SSH on the Tailscale IP.
      # Keep the NixOS firewall in charge of inbound access on tailscale0.
      "--netfilter-mode=off"
    ];
  };

  systemd.services.tailscaled.unitConfig.RequiresMountsFor = [ "/var/lib/tailscale" ];

  systemd.network = {
    enable = true;
    networks."10-ether" = {
      # Match only Cloud Hypervisor's fixed workstation NIC. A Type=ether
      # match also claims Docker's dynamic veth devices and breaks its bridge.
      matchConfig.MACAddress = "02:4d:55:4e:49:4e";
      networkConfig = {
        Address = "10.88.0.10/24";
        DNS = "10.88.0.1";
        Gateway = "10.88.0.1";
        IPv6AcceptRA = false;
      };
    };
  };

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 25;
  };

  systemd.oomd = {
    enable = true;
    enableUserSlices = true;
  };

  programs.zsh.enable = true;

  # GitHub HTTPS URLs are intentionally rewritten to SSH by the shared Git
  # config, so bootstrap tools such as lazy.nvim need non-interactive trust.
  # Source: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
  programs.ssh.knownHosts.github = {
    hostNames = [ "github.com" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
  };

  virtualisation.docker.enable = true;

  security.sudo.wheelNeedsPassword = false;

  users.users.jakob = {
    isNormalUser = true;
    uid = 1000;
    description = "Jakob Evangelista";
    extraGroups = [
      "docker"
      "wheel"
    ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [
      # Odin can connect directly for lifecycle and recovery operations.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPK+KglkNTvuL57ORBCX/npKJA7h6iVOTqkjhRIkwTbt odin"
      # Jakob's MacBook connects through Odin with ProxyJump.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIWpNawHRTkJb9uBKny2HYdtLJQXNwnX8kgkrAuOBDn4 jakobevangelista@gmail.com"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /home/jakob 0700 jakob users - -"
    "d /home/jakob/.codex 0700 jakob users - -"
    "d /home/jakob/.local 0700 jakob users - -"
    "d /home/jakob/.local/share 0700 jakob users - -"
    "d /home/jakob/.local/share/opencode 0700 jakob users - -"
    "d /home/jakob/.local/state 0700 jakob users - -"
    "d /home/jakob/.local/state/nix 0700 jakob users - -"
    "d /home/jakob/.local/state/nix/profiles 0700 jakob users - -"
    "d /home/jakob/.local/state/home-manager 0700 jakob users - -"
    "d /home/jakob/.local/state/home-manager/gcroots 0700 jakob users - -"
    "L+ /home/jakob/.codex/.credentials.json - - - - /run/muninn-host/codex/.credentials.json"
    "L+ /home/jakob/.codex/AGENTS.md - - - - /run/muninn-host/codex/AGENTS.md"
    "L+ /home/jakob/.codex/auth.json - - - - /run/muninn-host/codex/auth.json"
    "L+ /home/jakob/.codex/config.toml - - - - /run/muninn-host/codex/config.toml"
    "L+ /home/jakob/.codex/rules - - - - /run/muninn-host/codex/rules"
    "L+ /home/jakob/.codex/sessions - - - - /run/muninn-host/codex-sessions"
  ];

  # /nix/store is a read-only view of Odin's store, while the guest keeps its
  # own persistent Nix database. Register each manifest's complete closure
  # before the daemon or Home Manager tries to use those paths.
  systemd.services.muninn-register-store = {
    description = "Register Muninn system closure in the persistent Nix database";
    wantedBy = [ "sysinit.target" ];
    before = [
      "home-manager-jakob.service"
      "nix-daemon.service"
      "nix-daemon.socket"
      "shutdown.target"
      "sysinit.target"
    ];
    after = [ "local-fs.target" ];
    conflicts = [ "shutdown.target" ];
    restartIfChanged = false;
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      registration=
      for parameter in $(</proc/cmdline); do
        case "$parameter" in
          muninn.registration=*) registration="''${parameter#muninn.registration=}" ;;
        esac
      done

      case "$registration" in
        /nix/store/*/registration) ;;
        *)
          echo "Missing or invalid muninn.registration kernel parameter" >&2
          exit 1
          ;;
      esac

      if [[ ! -r "$registration" ]]; then
        echo "Muninn closure registration is not readable: $registration" >&2
        exit 1
      fi

      export NIX_REMOTE=local
      ${lib.getExe' config.nix.package.out "nix-store"} --load-db < "$registration"
      ${lib.getExe' config.nix.package.out "nix-env"} \
        --profile /nix/var/nix/profiles/system \
        --set /run/current-system
    '';
  };

  systemd.services.home-manager-jakob = {
    requires = [ "muninn-register-store.service" ];
    after = [ "muninn-register-store.service" ];
  };

  services.openssh = {
    enable = true;
    openFirewall = false;
    hostKeys = [
      {
        path = "/persist/etc-ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
    settings = {
      AllowUsers = [ "jakob" ];
      KbdInteractiveAuthentication = false;
      PasswordAuthentication = false;
      PermitRootLogin = "no";
      PubkeyAuthentication = true;
    };
  };

  systemd.services.sshd-keygen.unitConfig.RequiresMountsFor = [
    "/persist/etc-ssh"
  ];

  environment.systemPackages = with pkgs; [
    curl
    fd
    git
    gnumake
    jq
    neovim
    nodejs
    python3
    procps
    ripgrep
    tmux
    wget
  ];

  # The existing Odin conversations live in the historical stable-channel DB.
  environment.sessionVariables.OPENCODE_DB = "opencode-stable.db";
}
