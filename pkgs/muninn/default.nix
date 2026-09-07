{
  coreutils,
  netcat-openbsd,
  openssh,
  procps,
  sudo,
  systemd,
  writeShellApplication,
}:

writeShellApplication {
  name = "muninn";
  runtimeInputs = [
    coreutils
    netcat-openbsd
    openssh
    procps
    sudo
    systemd
  ];
  text = ''
    vm_host=10.88.0.10
    vm_user=jakob
    unit=muninn.service
    ssh_args=(
      -o BatchMode=yes
      -o ConnectTimeout=5
      -o StrictHostKeyChecking=accept-new
    )

    usage() {
      cat <<'EOF'
    Usage: muninn <command> [args]

    Commands:
      start          Start the workstation and wait for SSH
      stop           Gracefully stop the workstation
      restart        Stop and start the workstation
      import-opencode
                     Import Odin's OpenCode state into an empty Muninn state
      status         Show service and resource status
      ssh [command]  Connect to the workstation
      logs           Follow host-side VM logs
      serial         Follow the guest serial console log
      ip             Print the workstation IP address
    EOF
    }

    start_vm() {
      sudo systemctl start "$unit"
      printf 'Waiting for Muninn SSH at %s' "$vm_host"
      for _ in $(seq 1 60); do
        if nc -z -w 1 "$vm_host" 22 >/dev/null 2>&1; then
          printf '\nMuninn is ready. Run: muninn ssh\n'
          return 0
        fi
        printf '.'
        sleep 1
      done
      printf '\nMuninn started, but SSH did not become ready within 60 seconds.\n' >&2
      systemctl status "$unit" --no-pager || true
      return 1
    }

    stop_vm() {
      if systemctl is-active --quiet "$unit"; then
        ssh "''${ssh_args[@]}" "$vm_user@$vm_host" sudo systemctl poweroff >/dev/null 2>&1 || true
        for _ in $(seq 1 20); do
          systemctl is-active --quiet "$unit" || break
          sleep 1
        done
      fi
      sudo systemctl stop "$unit"
    }

    import_opencode() {
      if ! systemctl is-active --quiet "$unit"; then
        echo "Muninn must be running before importing OpenCode state." >&2
        exit 1
      fi

      if pgrep -u jakob -x opencode >/dev/null; then
        echo "Close every OpenCode process on Odin before importing its database." >&2
        exit 1
      fi

      ssh "''${ssh_args[@]}" "$vm_user@$vm_host" '
        set -e
        source_dir=/run/muninn-host/opencode
        target_dir=/home/jakob/.local/share/opencode
        staging_dir=/home/jakob/.local/share/opencode.importing

        if pgrep -u "$(id -u)" -x opencode >/dev/null; then
          echo "Close every OpenCode process in Muninn before importing." >&2
          exit 1
        fi
        if [[ ! -d "$source_dir" ]]; then
          echo "Odin OpenCode import source is not mounted: $source_dir" >&2
          exit 1
        fi
        if [[ -e "$staging_dir" ]]; then
          echo "An incomplete OpenCode import needs inspection: $staging_dir" >&2
          exit 1
        fi
        if [[ -d "$target_dir" && -n "$(ls -A "$target_dir")" ]]; then
          echo "Refusing to replace non-empty Muninn OpenCode state: $target_dir" >&2
          exit 1
        fi

        source_bytes=$(du -sb "$source_dir" | cut -f1)
        available_bytes=$(df -B1 --output=avail /home/jakob/.local/share | tail -1)
        required_bytes=$((source_bytes + 1024 * 1024 * 1024))
        if (( available_bytes < required_bytes )); then
          echo "Not enough Muninn state-disk space for the OpenCode import." >&2
          exit 1
        fi

        install -d -m 0700 "$staging_dir"
        cp --archive --reflink=auto --sparse=always "$source_dir"/. "$staging_dir"/
        touch "$staging_dir/.imported-from-odin"
        if [[ -d "$target_dir" ]]; then
          rmdir "$target_dir"
        fi
        mv "$staging_dir" "$target_dir"
        echo "Imported Odin OpenCode state into Muninn."
      '
    }

    command="''${1:-help}"
    if (( $# > 0 )); then
      shift
    fi

    case "$command" in
      start)
        start_vm
        ;;
      stop)
        stop_vm
        ;;
      restart)
        stop_vm
        start_vm
        ;;
      import-opencode)
        import_opencode
        ;;
      status)
        systemctl status "$unit" --no-pager || true
        systemctl show "$unit" \
          -p MemoryCurrent -p MemoryPeak -p MemoryHigh -p MemoryMax \
          -p CPUUsageNSec -p TasksCurrent
        ;;
      ssh)
        exec ssh "''${ssh_args[@]}" "$vm_user@$vm_host" "$@"
        ;;
      logs)
        exec sudo journalctl -u "$unit" -f
        ;;
      serial)
        exec sudo tail -F /var/lib/muninn/logs/serial.log
        ;;
      ip)
        printf '%s\n' "$vm_host"
        ;;
      help|-h|--help)
        usage
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  '';
  meta.description = "Lifecycle helper for the Muninn workstation VM";
}
