#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/update-codex.sh [latest|VERSION] [--force]

Updates pkgs/codex/default.nix to the official upstream Codex standalone Linux
x64 package. This uses the release asset SHA-256 from GitHub, converts it to a
Nix SRI hash, and verifies the resulting package builds.

Examples:
  scripts/update-codex.sh
  scripts/update-codex.sh latest
  scripts/update-codex.sh 0.136.0
  scripts/update-codex.sh rust-v0.136.0
EOF
}

requested_version="${1:-latest}"
force=false
asset_name="codex-package-x86_64-unknown-linux-musl.tar.gz"

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

for command in curl jq nix; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "${command} is required." >&2
    exit 1
  fi
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "${script_dir}" rev-parse --show-toplevel)"
package_file="${repo_root}/pkgs/codex/default.nix"
flake_attr="path:${repo_root}#nixosConfigurations.odin.pkgs.codex"

if [ ! -f "${package_file}" ]; then
  echo "Missing package file: ${package_file}" >&2
  exit 1
fi

if [ "${requested_version}" = "latest" ]; then
  release_url="https://api.github.com/repos/openai/codex/releases/latest"
else
  version="${requested_version#rust-v}"
  version="${version#v}"
  release_url="https://api.github.com/repos/openai/codex/releases/tags/rust-v${version}"
fi

release_json="$(curl -fsSL "${release_url}")"
version="$(printf '%s' "${release_json}" | jq -r '.tag_name | sub("^rust-v"; "")')"

if [ -z "${version}" ] || [ "${version}" = "null" ]; then
  echo "Could not determine Codex version." >&2
  exit 1
fi

if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid Codex version: ${version}" >&2
  exit 1
fi

digest="$(printf '%s' "${release_json}" \
  | jq -r --arg name "${asset_name}" '.assets[] | select(.name == $name) | .digest' \
  | head -n 1)"

if [[ ! "${digest}" =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
  echo "Could not find SHA-256 digest for ${asset_name} in rust-v${version}." >&2
  exit 1
fi

hash="$(nix hash convert --hash-algo sha256 --to sri "${digest#sha256:}")"
current_version="$(sed -n 's/^[[:space:]]*version = "\([^"]*\)";/\1/p' "${package_file}" | head -n 1)"
current_hash="$(sed -n 's/^[[:space:]]*hash = "\([^"]*\)";/\1/p' "${package_file}" | head -n 1)"

if [ "${current_version}" = "${version}" ] && [ "${current_hash}" = "${hash}" ] && [ "${force}" != true ]; then
  echo "Codex is already pinned to ${version}. Use --force to rebuild."
  exit 0
fi

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

escaped_hash="$(escape_sed_replacement "${hash}")"
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

sed -i -E "s/^(  version = \")([^\"]+)(\";)/\1${version}\3/" "${package_file}"
sed -i -E "s/^(    hash = \")sha256-[^\"]+(\";)/\1${escaped_hash}\2/" "${package_file}"

echo "Building Codex ${version}..."
out_path="$(nix build --no-link --print-out-paths "${flake_attr}")"
actual_version="$(${out_path}/bin/codex --version)"

if [[ "${actual_version}" != *"${version}"* ]]; then
  echo "Built Codex reported '${actual_version}', expected ${version}." >&2
  exit 1
fi

trap - EXIT
rm -f "${backup}"

echo "Updated ${package_file}"
echo "hash: ${hash}"
