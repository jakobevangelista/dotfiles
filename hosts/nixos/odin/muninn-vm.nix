{
  dotfilesPackages,
  lib,
  pkgs,
  ...
}:

let
  vmUser = "muninn";
  vmMac = "02:4d:55:4e:49:4e";
  tapName = "mn-muninn";
  bridgeName = "virbr0";
  stateDir = "/var/lib/muninn";
  runtimeDir = "/run/muninn";
  stateDisk = "${stateDir}/muninn-state.raw";
  manifest = "/etc/muninn/manifest.json";

  persistentSkeleton = pkgs.runCommand "muninn-state-skeleton" { } ''
    mkdir -p \
      "$out/nix-store/upper" \
      "$out/nix-store/work" \
      "$out/nix-var" \
      "$out/home/jakob/.codex" \
      "$out/home/jakob/.claude" \
      "$out/home/jakob/.local/share/opencode" \
      "$out/home/jakob/.local/share/amp" \
      "$out/home/jakob/inngest-work" \
      "$out/home/jakob/personal" \
      "$out/home/jakob/dotfiles" \
      "$out/etc-ssh" \
      "$out/var-lib-docker"
    install -d -m 0700 "$out/var-lib-tailscale"
  '';

  prepare = pkgs.writeShellApplication {
    name = "muninn-prepare";
    runtimeInputs = with pkgs; [
      coreutils
      e2fsprogs
      iproute2
      util-linux
    ];
    text = ''
      state_dir=${lib.escapeShellArg stateDir}
      runtime_dir=${lib.escapeShellArg runtimeDir}
      state_disk=${lib.escapeShellArg stateDisk}
      creating_disk="$state_disk.creating"
      tap_name=${lib.escapeShellArg tapName}
      bridge_name=${lib.escapeShellArg bridgeName}

      install -d -m 0750 -o root -g ${vmUser} "$state_dir"
      install -d -m 0750 -o ${vmUser} -g ${vmUser} "$state_dir/logs"
      install -d -m 0770 -o root -g users "$runtime_dir"

      for share in \
        /home/jakob/.codex \
        /home/jakob/.codex/sessions \
        /home/jakob/.claude \
        /home/jakob/.local/share/opencode \
        /home/jakob/.local/share/amp \
        /home/jakob/inngest-work \
        /home/jakob/personal \
        /home/jakob/dotfiles
      do
        if [[ ! -d "$share" ]]; then
          echo "Muninn share does not exist: $share" >&2
          exit 1
        fi
      done

      if [[ ! -e "$state_disk" ]]; then
        if [[ -e "$creating_disk" ]]; then
          echo "Refusing to replace incomplete disk: $creating_disk" >&2
          echo "Inspect it, then remove it manually before retrying." >&2
          exit 1
        fi

        read -r free_blocks block_size < <(stat -f --format='%a %S' "$state_dir")
        free_bytes=$((free_blocks * block_size))
        required_bytes=$((100 * 1024 * 1024 * 1024))
        if (( free_bytes < required_bytes )); then
          echo "Muninn needs 100 GiB free before first start:" >&2
          echo "80 GiB for its reserved state disk and 20 GiB host headroom." >&2
          echo "Currently available: $(numfmt --to=iec "$free_bytes")" >&2
          exit 1
        fi

        echo "Creating Muninn's reserved 80 GiB state disk..."
        fallocate --length 80G "$creating_disk"
        mkfs.ext4 -q -F -E nodiscard -L muninn-state -d ${persistentSkeleton} "$creating_disk"
        chown ${vmUser}:${vmUser} "$creating_disk"
        chmod 0600 "$creating_disk"
        mv "$creating_disk" "$state_disk"
      fi

      if [[ "$(blkid -o value -s TYPE "$state_disk")" != ext4 ]]; then
        echo "Refusing to use non-ext4 Muninn state disk: $state_disk" >&2
        exit 1
      fi
      if [[ "$(blkid -o value -s LABEL "$state_disk")" != muninn-state ]]; then
        echo "Refusing to use state disk without the muninn-state label: $state_disk" >&2
        exit 1
      fi
      chown ${vmUser}:${vmUser} "$state_disk"
      chmod 0600 "$state_disk"

      rm -f \
        "$runtime_dir/api.sock" \
        "$runtime_dir/events.log" \
        "$runtime_dir"/virtiofs-*.sock

      if ip link show dev "$tap_name" >/dev/null 2>&1; then
        echo "Refusing to replace existing network interface: $tap_name" >&2
        echo "Stop its owner or remove the stale interface explicitly." >&2
        exit 1
      fi

      cleanup_failed_network_setup() {
        status=$?
        if ip link show dev "$tap_name" >/dev/null 2>&1; then
          ip link delete dev "$tap_name" || true
        fi
        exit "$status"
      }
      trap cleanup_failed_network_setup ERR

      ip tuntap add dev "$tap_name" mode tap user ${vmUser} group ${vmUser} multi_queue
      ip link set dev "$tap_name" master "$bridge_name"
      ip link set dev "$tap_name" up
      trap - ERR
    '';
  };

  cleanup = pkgs.writeShellApplication {
    name = "muninn-cleanup";
    runtimeInputs = with pkgs; [
      coreutils
      iproute2
    ];
    text = ''
      tap_name=${lib.escapeShellArg tapName}
      runtime_dir=${lib.escapeShellArg runtimeDir}

      if ip link show dev "$tap_name" >/dev/null 2>&1; then
        ip link delete dev "$tap_name" || true
      fi
      rm -f \
        "$runtime_dir/api.sock" \
        "$runtime_dir/events.log" \
        "$runtime_dir"/virtiofs-*.sock
    '';
  };

  waitForSocket = pkgs.writeShellApplication {
    name = "muninn-wait-for-socket";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      socket="$1"
      for _ in $(seq 1 100); do
        if [[ -S "$socket" ]]; then
          exit 0
        fi
        sleep 0.1
      done
      echo "Timed out waiting for virtiofs socket: $socket" >&2
      exit 1
    '';
  };

  startVm = pkgs.writeShellApplication {
    name = "muninn-start-vm";
    runtimeInputs = with pkgs; [
      cloud-hypervisor
      jq
    ];
    text = ''
      kernel=$(jq -er .kernel ${manifest})
      initrd=$(jq -er .initrd ${manifest})
      cmdline=$(jq -er .cmdline ${manifest})

      exec cloud-hypervisor \
        --kernel "$kernel" \
        --initramfs "$initrd" \
        --cmdline "$cmdline" \
        --cpus boot=12,topology=2:6:1:1 \
        --memory size=20G,shared=on,prefault=off \
        --disk path=${stateDisk},image_type=raw,sparse=off,num_queues=4 \
        --fs \
          tag=ro-store,socket=${runtimeDir}/virtiofs-ro-store.sock,num_queues=1,queue_size=1024 \
          tag=inngest-work,socket=${runtimeDir}/virtiofs-inngest-work.sock,num_queues=1,queue_size=1024 \
          tag=personal,socket=${runtimeDir}/virtiofs-personal.sock,num_queues=1,queue_size=1024 \
          tag=dotfiles,socket=${runtimeDir}/virtiofs-dotfiles.sock,num_queues=1,queue_size=1024 \
          tag=codex-state,socket=${runtimeDir}/virtiofs-codex-state.sock,num_queues=1,queue_size=1024 \
          tag=codex-sessions,socket=${runtimeDir}/virtiofs-codex-sessions.sock,num_queues=1,queue_size=1024 \
          tag=claude-state,socket=${runtimeDir}/virtiofs-claude-state.sock,num_queues=1,queue_size=1024 \
          tag=opencode-state,socket=${runtimeDir}/virtiofs-opencode-state.sock,num_queues=1,queue_size=1024 \
          tag=amp-state,socket=${runtimeDir}/virtiofs-amp-state.sock,num_queues=1,queue_size=1024 \
        --net tap=${tapName},mac=${vmMac},num_queues=4 \
        --api-socket path=${runtimeDir}/api.sock \
        --serial file=${stateDir}/logs/serial.log \
        --console off \
        --event-monitor path=${runtimeDir}/events.log \
        --log-file ${stateDir}/logs/cloud-hypervisor.log \
        --seccomp true \
        --watchdog
    '';
  };

  stopVm = pkgs.writeShellApplication {
    name = "muninn-stop-vm";
    runtimeInputs = with pkgs; [
      cloud-hypervisor
      coreutils
    ];
    text = ''
      api_socket=${lib.escapeShellArg "${runtimeDir}/api.sock"}

      if [[ -S "$api_socket" ]]; then
        ch-remote --api-socket "$api_socket" power-button >/dev/null 2>&1 || true
      fi

      if [[ -n "''${MAINPID:-}" ]]; then
        for _ in $(seq 1 25); do
          kill -0 "$MAINPID" >/dev/null 2>&1 || exit 0
          sleep 1
        done
      fi

      if [[ -S "$api_socket" ]]; then
        ch-remote --api-socket "$api_socket" shutdown-vmm >/dev/null 2>&1 || true
      fi
    '';
  };

  shares = {
    ro-store = {
      hostPath = "/nix/store";
      readOnly = true;
      cache = "metadata";
    };
    inngest-work = {
      hostPath = "/home/jakob/inngest-work";
      readOnly = false;
      cache = "never";
    };
    personal = {
      hostPath = "/home/jakob/personal";
      readOnly = false;
      cache = "never";
    };
    dotfiles = {
      hostPath = "/home/jakob/dotfiles";
      readOnly = false;
      cache = "never";
    };
    codex-state = {
      hostPath = "/home/jakob/.codex";
      readOnly = false;
      cache = "never";
    };
    codex-sessions = {
      hostPath = "/home/jakob/.codex/sessions";
      readOnly = false;
      cache = "never";
    };
    claude-state = {
      hostPath = "/home/jakob/.claude";
      readOnly = false;
      cache = "never";
    };
    opencode-state = {
      hostPath = "/home/jakob/.local/share/opencode";
      readOnly = true;
      cache = "metadata";
    };
    amp-state = {
      hostPath = "/home/jakob/.local/share/amp";
      readOnly = false;
      cache = "never";
    };
  };

  mkVirtiofsService =
    name: share:
    let
      socket = "${runtimeDir}/virtiofs-${name}.sock";
      accessArgs =
        lib.optionals share.readOnly [ "--readonly" ]
        ++ lib.optionals (!share.readOnly) [
          "--xattr"
          "--translate-uid"
          "squash-guest:0:1000:4294967295"
          "--translate-gid"
          "squash-guest:0:100:4294967295"
          "--translate-uid"
          "host:1000:1000:1"
          "--translate-gid"
          "host:100:100:1"
        ];
    in
    {
      name = "muninn-virtiofs-${name}";
      value = {
        description = "Muninn virtiofs share: ${name}";
        requires = [ "muninn-prepare.service" ];
        after = [ "muninn-prepare.service" ];
        partOf = [ "muninn.service" ];
        unitConfig.StopWhenUnneeded = true;
        serviceConfig = {
          Type = "simple";
          User = "jakob";
          Group = "users";
          Slice = "muninn.slice";
          ExecStartPre = "${pkgs.coreutils}/bin/rm -f ${socket}";
          ExecStart = lib.concatStringsSep " " (
            [
              "${lib.getExe pkgs.virtiofsd}"
              "--shared-dir"
              (lib.escapeShellArg share.hostPath)
              "--socket-path"
              (lib.escapeShellArg socket)
              "--socket-group"
              "users"
              "--sandbox"
              "none"
              "--cache"
              share.cache
              "--thread-pool-size"
              "8"
              "--rlimit-nofile"
              "524288"
              "--inode-file-handles=never"
              "--log-level"
              "warn"
            ]
            ++ accessArgs
          );
          ExecStartPost = "${lib.getExe waitForSocket} ${socket}";
          Restart = "no";
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHome = if lib.hasPrefix "/home/" share.hostPath then "tmpfs" else true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectSystem = "strict";
          RestrictAddressFamilies = [ "AF_UNIX" ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          CapabilityBoundingSet = "";
          SystemCallArchitectures = "native";
          ReadWritePaths = [ runtimeDir ] ++ lib.optionals (!share.readOnly) [ share.hostPath ];
          BindPaths = lib.optionals (!share.readOnly) [ share.hostPath ];
          BindReadOnlyPaths = lib.optionals share.readOnly [ share.hostPath ];
        };
      };
    };

  virtiofsServices = lib.mapAttrs' mkVirtiofsService shares;
  virtiofsUnits = map (name: "muninn-virtiofs-${name}.service") (lib.attrNames shares);
in
{
  environment.systemPackages = [ dotfilesPackages.muninn ];
  environment.etc."muninn/manifest.json".source = dotfilesPackages.muninn-manifest;

  users.groups.${vmUser} = { };
  users.users.${vmUser} = {
    isSystemUser = true;
    group = vmUser;
    extraGroups = [
      "kvm"
      "users"
    ];
    home = stateDir;
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 root ${vmUser} - -"
    "d ${stateDir}/logs 0750 ${vmUser} ${vmUser} - -"
    "d ${runtimeDir} 0770 root users - -"
  ];

  systemd.slices.muninn = {
    description = "Resource boundary for the Muninn workstation VM";
    sliceConfig = {
      AllowedCPUs = "2-7,10-15";
      IOAccounting = true;
      IOWeight = 50;
      MemoryAccounting = true;
      MemoryHigh = "21G";
      MemoryMax = "23G";
      MemorySwapMax = "8G";
      ManagedOOMMemoryPressure = "kill";
      ManagedOOMMemoryPressureLimit = "70%";
      TasksAccounting = true;
      TasksMax = 16384;
    };
  };

  systemd.services = virtiofsServices // {
    muninn-prepare = {
      description = "Prepare persistent state and networking for Muninn";
      requires = [ "sys-subsystem-net-devices-${bridgeName}.device" ];
      after = [
        "systemd-networkd.service"
        "sys-subsystem-net-devices-${bridgeName}.device"
      ];
      before = virtiofsUnits ++ [ "muninn.service" ];
      partOf = [ "muninn.service" ];
      unitConfig.StopWhenUnneeded = true;
      serviceConfig = {
        Type = "oneshot";
        Slice = "muninn.slice";
        RemainAfterExit = true;
        ExecStart = lib.getExe prepare;
        ExecStop = lib.getExe cleanup;
      };
    };

    muninn = {
      description = "Muninn persistent Cloud Hypervisor workstation";
      requires = [ "muninn-prepare.service" ] ++ virtiofsUnits;
      after = [ "muninn-prepare.service" ] ++ virtiofsUnits;
      bindsTo = virtiofsUnits;
      unitConfig = {
        ConditionPathExists = [
          "/dev/kvm"
          manifest
        ];
      };
      serviceConfig = {
        Type = "simple";
        User = vmUser;
        Group = vmUser;
        SupplementaryGroups = [
          "kvm"
          "users"
        ];
        Slice = "muninn.slice";
        ExecStart = lib.getExe startVm;
        ExecStop = lib.getExe stopVm;
        Restart = "no";
        TimeoutStartSec = "30s";
        TimeoutStopSec = "35s";
        KillMode = "mixed";
        OOMPolicy = "stop";
        LimitNOFILE = 1048576;
        DevicePolicy = "closed";
        DeviceAllow = [
          "/dev/kvm rw"
          "/dev/net/tun rw"
        ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        ReadWritePaths = [
          stateDir
          runtimeDir
        ];
      };
    };
  };
}
