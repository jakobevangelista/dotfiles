#!/usr/bin/env bash

set -uo pipefail

deep=false
if [[ ${1:-} == --deep ]]; then
  deep=true
elif [[ $# -gt 0 ]]; then
  printf 'usage: %s [--deep]\n' "$0" >&2
  exit 2
fi

section() {
  printf '\n[%s]\n' "$1"
}

bounded_size() {
  local path=$1
  if [[ ! -e $path ]]; then
    return
  fi
  if ! timeout 20s du -xsh -- "$path" 2>/dev/null; then
    printf 'scan timed out or was partially unreadable: %s\n' "$path"
  fi
}

host=$(hostname)
if [[ $host != odin ]]; then
  printf 'warning: expected hostname odin, found %s\n' "$host" >&2
fi

section filesystem
df -hT /
df -ih /

used_before=$(df -B1 --output=used / | tail -n 1)
sleep 3
used_after=$(df -B1 --output=used / | tail -n 1)
printf 'three-second used-byte delta: %s\n' "$((used_after - used_before))"

section pressure
free -h
swapon --show
for kind in cpu memory io; do
  printf '%s: ' "$kind"
  tr '\n' ' ' < "/proc/pressure/$kind"
  printf '\n'
done

section rootless-docker
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker system df
  docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
else
  printf 'rootless Docker is unavailable\n'
fi

section rootful-docker
if sudo -n true 2>/dev/null; then
  sudo -n docker system df 2>/dev/null || printf 'rootful Docker is unavailable\n'
  sudo -n docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || true
else
  printf 'sudo authentication required; run sudo docker system df -v separately\n'
fi

section regenerable-caches
bounded_size "$HOME/.cache/go-build"
bounded_size "$HOME/go/pkg/mod"
bounded_size "$HOME/.cache/uv"
bounded_size "$HOME/.cache/pnpm"

section other-known-areas
bounded_size /tmp
bounded_size "$HOME/.local/share/opencode"
bounded_size "$HOME/.local/share/odin-session-rescue"
if [[ -d $HOME/inngest-work ]]; then
  printf 'inngest-work top-level directories: '
  find "$HOME/inngest-work" -mindepth 1 -maxdepth 1 -type d -printf . 2>/dev/null | wc -c
fi

if $deep; then
  section deep-bounded-scans
  bounded_size "$HOME/personal/ball-knowledge"
  bounded_size "$HOME/inngest-work"
  bounded_size /nix/store
  printf 'root-only physical trees require: sudo du -xhd1 /var/lib/docker /var/lib/muninn\n'
fi

section journals
journalctl --disk-usage 2>/dev/null || true

section top-processes
ps -eo pid,user,stat,pcpu,pmem,rss,etime,comm --sort=-pcpu | head -n 16

if command -v lsof >/dev/null 2>&1; then
  section deleted-open-files-over-100mib
  lsof +L1 2>/dev/null | awk 'NR == 1 || $7 >= 104857600 { print }' | sort -k7,7nr | head -n 30
fi

