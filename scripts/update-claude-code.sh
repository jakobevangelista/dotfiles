#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "${script_dir}" rev-parse --show-toplevel)"

export DOTFILES_REPO_ROOT="${repo_root}"
exec nix run "path:${repo_root}#update-claude-code" -- "$@"
