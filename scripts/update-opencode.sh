#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/update-opencode.sh [latest|VERSION] [--force]

Updates pkgs/opencode/default.nix to an upstream OpenCode release and lets Nix
calculate the source and node_modules hashes.

Examples:
  scripts/update-opencode.sh
  scripts/update-opencode.sh latest
  scripts/update-opencode.sh 1.15.13
  scripts/update-opencode.sh v1.15.13
EOF
}

requested_version="${1:-latest}"
force=false

if [ "${requested_version}" = "-h" ] || [ "${requested_version}" = "--help" ]; then
  usage
  exit 0
fi

if [ "${2:-}" = "--force" ]; then
  force=true
elif [ -n "${2:-}" ]; then
  usage >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "${script_dir}" rev-parse --show-toplevel)"
package_file="${repo_root}/pkgs/opencode/default.nix"
flake_attr="path:${repo_root}#nixosConfigurations.odin.pkgs.opencode"
fake_hash="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

if [ ! -f "${package_file}" ]; then
  echo "Missing package file: ${package_file}" >&2
  exit 1
fi

if [ "${requested_version}" = "latest" ]; then
  version="$(curl -fsSL https://api.github.com/repos/anomalyco/opencode/releases/latest \
    | sed -n 's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' \
    | head -n 1)"
else
  version="${requested_version#v}"
fi

if [ -z "${version}" ]; then
  echo "Could not determine OpenCode version." >&2
  exit 1
fi

if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid OpenCode version: ${version}" >&2
  exit 1
fi

current_version="$(sed -n 's/^[[:space:]]*version = "\([^"]*\)";/\1/p' "${package_file}" | head -n 1)"

if [ "${current_version}" = "${version}" ] && [ "${force}" != true ]; then
  echo "OpenCode is already pinned to ${version}. Use --force to refresh hashes."
  exit 0
fi

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

replace_version() {
  sed -i -E "s/^(  version = \")([^\"]+)(\";)/\1${version}\3/" "${package_file}"
}

replace_source_hash() {
  local escaped_hash
  escaped_hash="$(escape_sed_replacement "$1")"
  sed -i -E "0,/^(    hash = \")sha256-[^\"]+(\";)/s//\1${escaped_hash}\2/" "${package_file}"
}

replace_node_modules_hash() {
  local escaped_hash
  escaped_hash="$(escape_sed_replacement "$1")"
  sed -i -E "s/^(    outputHash = \")sha256-[^\"]+(\";)/\1${escaped_hash}\2/" "${package_file}"
}

hash_from_failed_build() {
  local output status hash

  set +e
  output="$(nix build --no-link "${flake_attr}" 2>&1)"
  status=$?
  set -e

  printf '%s\n' "${output}" >&2

  if [ "${status}" -eq 0 ]; then
    echo "Expected a Nix hash mismatch, but the build succeeded." >&2
    return 1
  fi

  hash="$(printf '%s\n' "${output}" \
    | sed -n 's/^[[:space:]]*got:[[:space:]]*\(sha256-[A-Za-z0-9+\/=]*\)$/\1/p' \
    | tail -n 1)"

  if [ -z "${hash}" ]; then
    echo "Could not find a Nix hash mismatch in the build output." >&2
    return 1
  fi

  printf '%s\n' "${hash}"
}

backup="$(mktemp)"
cp "${package_file}" "${backup}"

restore_on_error() {
  local status=$?
  if [ "${status}" -ne 0 ]; then
    cp "${backup}" "${package_file}"
    echo "Restored ${package_file} after failed update." >&2
  fi
  rm -f "${backup}"
  exit "${status}"
}
trap restore_on_error EXIT

echo "Updating OpenCode to ${version}"
replace_version

echo "Calculating source hash..."
replace_source_hash "${fake_hash}"
source_hash="$(hash_from_failed_build)"
replace_source_hash "${source_hash}"

echo "Calculating node_modules hash..."
replace_node_modules_hash "${fake_hash}"
node_modules_hash="$(hash_from_failed_build)"
replace_node_modules_hash "${node_modules_hash}"

echo "Building OpenCode ${version}..."
out_path="$(nix build --no-link --print-out-paths "${flake_attr}")"
actual_version="$(${out_path}/bin/opencode --version)"

if [ "${actual_version}" != "${version}" ]; then
  echo "Built OpenCode ${actual_version}, expected ${version}." >&2
  exit 1
fi

trap - EXIT
rm -f "${backup}"

echo "Updated ${package_file}"
echo "source hash: ${source_hash}"
echo "node_modules hash: ${node_modules_hash}"
