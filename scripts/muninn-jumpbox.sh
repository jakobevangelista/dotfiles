#!/usr/bin/env bash
# Temporary, host-reboot-scoped resource limits for Muninn. Run on Odin.
set -euo pipefail
export PATH=/run/current-system/sw/bin
export SYSTEMD_PAGER=cat

runtime_dir=/run/muninn-jumpbox
service_override=/run/systemd/system/muninn.service.d/90-jumpbox.conf
slice_override=/run/systemd/system/muninn.slice.d/90-jumpbox.conf

fail() { printf '%s\n' "$*" >&2; exit 1; }

[[ $(hostname) == odin ]] || fail 'Run this script on Odin.'

require_stopped() {
  local state
  state=$(systemctl show muninn.service --value -p ActiveState)
  [[ $state == inactive || $state == failed ]] ||
    fail 'Stop Muninn with muninn stop before changing its resources.'
}

render_launcher() {
  local launcher contents old new fragment
  fragment=$(systemctl show muninn.service --value -p FragmentPath)
  launcher=$(sed -n 's/^ExecStart=//p' "$fragment")
  [[ $launcher == /nix/store/*/bin/muninn-start-vm && -f $launcher ]] ||
    fail 'Expected the original Nix launcher; inspect existing overrides first.'
  contents=$(cat "$launcher")
  while IFS='|' read -r old new; do
    [[ $(grep -Fc -- "$old" <<< "$contents") == 1 ]] ||
      fail "Launcher changed; expected exactly one occurrence of: $old"
    contents=${contents/"$old"/"$new"}
  done <<'REPLACEMENTS'
--cpus boot=12,topology=2:6:1:1|--cpus boot=2,topology=1:2:1:1
--memory size=20G,shared=on,prefault=off|--memory size=4G,shared=on,prefault=off
image_type=raw,sparse=off,num_queues=4|image_type=raw,sparse=off,num_queues=2
REPLACEMENTS
  printf '%s\n' "$contents"
}

show_status() {
  systemctl show muninn.service -p ActiveState -p ExecStart -p DropInPaths
  systemctl show muninn.slice -p MemoryHigh -p MemoryMax -p MemorySwapMax \
    -p CPUQuotaPerSecUSec -p AllowedCPUs -p DropInPaths
  if [[ -f $runtime_dir/launch ]]; then
    grep -E -- '--cpus |--memory ' "$runtime_dir/launch"
  fi
}

case ${1:-status} in
  start)
    [[ $EUID == 0 ]] || fail 'Start requires sudo.'
    require_stopped
    # Refresh only our overrides, including corrections to the launcher.
    bash "$0" restore
    bash "$0" apply
    muninn start
    ;;
  preview)
    render_launcher
    ;;
  apply)
    [[ $EUID == 0 ]] || fail 'Apply requires sudo.'
    require_stopped
    [[ ! -e $runtime_dir && ! -e $service_override && ! -e $slice_override ]] ||
      fail 'Jump-box files already exist; inspect status or restore first.'
    # Prepare and validate the complete launcher before installing overrides.
    launcher_contents=$(render_launcher)
    bash -n <<< "$launcher_contents"
    install -d -m 0755 "$runtime_dir" "${service_override%/*}" "${slice_override%/*}"
    printf '%s\n' "$launcher_contents" > "$runtime_dir/launch"
    chmod 0755 "$runtime_dir/launch"
    cat > "$service_override" <<'SERVICE'
[Service]
ExecStart=
ExecStart=/run/muninn-jumpbox/launch
SERVICE
    cat > "$slice_override" <<'SLICE'
[Slice]
MemoryHigh=5G
MemoryMax=6G
MemorySwapMax=1G
CPUQuota=200%
SLICE
    systemctl daemon-reload
    show_status
    printf '\nTemporary jump-box mode installed. Muninn remains stopped.\n'
    ;;
  restore)
    [[ $EUID == 0 ]] || fail 'Restore requires sudo.'
    require_stopped
    # Remove only this script's files, preserving any unrelated overrides.
    rm -f "$service_override" "$slice_override" "$runtime_dir/launch"
    if [[ -d $runtime_dir ]]; then rmdir "$runtime_dir"; fi
    systemctl daemon-reload
    show_status
    printf '\nJump-box overrides removed. The original launcher applies on next boot.\n'
    ;;
  status)
    show_status
    ;;
  *)
    fail 'Usage: muninn-jumpbox.sh [start|preview|apply|restore|status]'
    ;;
esac
