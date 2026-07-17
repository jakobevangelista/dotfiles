{
  coreutils,
  curl,
  git,
  gnused,
  jq,
  nix,
  writeShellApplication,
}:

let
  runtimeInputs = [
    coreutils
    curl
    git
    gnused
    jq
    nix
  ];

  repoRootSnippet = ''
    repo_root="''${DOTFILES_REPO_ROOT:-}"
    if [ -z "''${repo_root}" ]; then
      repo_root="$(git -C "$PWD" rev-parse --show-toplevel)"
    else
      repo_root="$(git -C "''${repo_root}" rev-parse --show-toplevel)"
    fi
  '';

  nixCommand = "nix --extra-experimental-features 'nix-command flakes'";

  updateClaudeCode = writeShellApplication {
    name = "update-claude-code";
    inherit runtimeInputs;
    text = ''
      usage() {
        cat <<'EOF'
      Usage: update-claude-code [latest|VERSION] [--force]

      Updates pkgs/claude-code/manifest.json to an upstream Claude Code release
      and verifies that the resulting Nix package builds.

      Examples:
        nix run .#update-claude-code
        nix run .#update-claude-code -- latest
        nix run .#update-claude-code -- 2.1.201
      EOF
      }

      requested_version="''${1:-latest}"
      force=false
      base_url="https://downloads.claude.ai/claude-code-releases"

      if [ "''${requested_version}" = "-h" ] || [ "''${requested_version}" = "--help" ]; then
        usage
        exit 0
      fi

      if [ "''${2:-}" = "--force" ]; then
        force=true
      elif [ -n "''${2:-}" ]; then
        usage >&2
        exit 1
      fi

      ${repoRootSnippet}

      manifest_file="''${repo_root}/pkgs/claude-code/manifest.json"
      flake_attr="path:''${repo_root}#nixosConfigurations.odin.pkgs.claude-code"

      if [ ! -f "''${manifest_file}" ]; then
        echo "Missing manifest file: ''${manifest_file}" >&2
        exit 1
      fi

      if [ "''${requested_version}" = "latest" ]; then
        version="$(curl -fsSL "''${base_url}/latest")"
      else
        version="''${requested_version#v}"
      fi

      if [ -z "''${version}" ]; then
        echo "Could not determine Claude Code version." >&2
        exit 1
      fi

      if [[ ! "''${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$ ]]; then
        echo "Invalid Claude Code version: ''${version}" >&2
        exit 1
      fi

      manifest_json="$(curl -fsSL "''${base_url}/''${version}/manifest.json")"
      manifest_version="$(printf '%s' "''${manifest_json}" | jq -r '.version')"
      linux_x64_checksum="$(printf '%s' "''${manifest_json}" | jq -r '.platforms["linux-x64"].checksum')"

      if [ "''${manifest_version}" != "''${version}" ]; then
        echo "Manifest version ''${manifest_version} did not match requested ''${version}." >&2
        exit 1
      fi

      if [[ ! "''${linux_x64_checksum}" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "Manifest for ''${version} is missing a linux-x64 checksum." >&2
        exit 1
      fi

      current_version="$(jq -r '.version' "''${manifest_file}")"

      if [ "''${current_version}" = "''${version}" ] && [ "''${force}" != true ]; then
        echo "Claude Code is already pinned to ''${version}. Use --force to rebuild."
        exit 0
      fi

      backup="$(mktemp)"
      cp "''${manifest_file}" "''${backup}"

      restore_on_error() {
        local status=$?
        if [ "''${status}" -ne 0 ]; then
          cp "''${backup}" "''${manifest_file}"
          echo "Restored ''${manifest_file} after failed update." >&2
        fi
        rm -f "''${backup}"
        exit "''${status}"
      }
      trap restore_on_error EXIT

      run_claude_version() {
        local out_path tmp_home status
        out_path="$1"
        tmp_home="$(mktemp -d)"

        set +e
        HOME="''${tmp_home}" "''${out_path}/bin/claude" --version
        status=$?
        set -e

        rm -rf "''${tmp_home}"
        return "''${status}"
      }

      printf '%s\n' "''${manifest_json}" | jq . > "''${manifest_file}"

      echo "Building Claude Code ''${version}..."
      out_path="$(${nixCommand} build --no-link --print-out-paths "''${flake_attr}")"
      actual_version="$(run_claude_version "''${out_path}")"

      if [[ "''${actual_version}" != *"''${version}"* ]]; then
        echo "Built Claude Code reported ''${actual_version}, expected ''${version}." >&2
        exit 1
      fi

      trap - EXIT
      rm -f "''${backup}"

      echo "Updated ''${manifest_file}"
      echo "linux-x64 checksum: ''${linux_x64_checksum}"
    '';
  };

  updateCodex = writeShellApplication {
    name = "update-codex";
    inherit runtimeInputs;
    text = ''
      usage() {
        cat <<'EOF'
      Usage: update-codex [latest|VERSION] [--force]

      Updates pkgs/codex/default.nix to the official upstream Codex standalone
      Linux x64 package, then verifies that the resulting Nix package builds.

      Examples:
        nix run .#update-codex
        nix run .#update-codex -- latest
        nix run .#update-codex -- 0.136.0
        nix run .#update-codex -- rust-v0.136.0
      EOF
      }

      requested_version="''${1:-latest}"
      force=false
      asset_name="codex-package-x86_64-unknown-linux-musl.tar.gz"

      if [ "''${requested_version}" = "-h" ] || [ "''${requested_version}" = "--help" ]; then
        usage
        exit 0
      fi

      if [ "''${2:-}" = "--force" ]; then
        force=true
      elif [ -n "''${2:-}" ]; then
        usage >&2
        exit 1
      fi

      ${repoRootSnippet}

      package_file="''${repo_root}/pkgs/codex/default.nix"
      flake_attr="path:''${repo_root}#nixosConfigurations.odin.pkgs.codex"

      if [ ! -f "''${package_file}" ]; then
        echo "Missing package file: ''${package_file}" >&2
        exit 1
      fi

      if [ "''${requested_version}" = "latest" ]; then
        release_url="https://api.github.com/repos/openai/codex/releases/latest"
      else
        version="''${requested_version#rust-v}"
        version="''${version#v}"
        release_url="https://api.github.com/repos/openai/codex/releases/tags/rust-v''${version}"
      fi

      release_json="$(curl -fsSL "''${release_url}")"
      version="$(printf '%s' "''${release_json}" | jq -r '.tag_name | sub("^rust-v"; "")')"

      if [ -z "''${version}" ] || [ "''${version}" = "null" ]; then
        echo "Could not determine Codex version." >&2
        exit 1
      fi

      if [[ ! "''${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$ ]]; then
        echo "Invalid Codex version: ''${version}" >&2
        exit 1
      fi

      digest="$(printf '%s' "''${release_json}" \
        | jq -r --arg name "''${asset_name}" '.assets[] | select(.name == $name) | .digest' \
        | head -n 1)"

      if [[ ! "''${digest}" =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
        echo "Could not find SHA-256 digest for ''${asset_name} in rust-v''${version}." >&2
        exit 1
      fi

      hash="$(${nixCommand} hash convert --hash-algo sha256 --to sri "''${digest#sha256:}")"
      current_version="$(sed -n 's/^[[:space:]]*version = "\([^"]*\)";/\1/p' "''${package_file}" | head -n 1)"
      current_hash="$(sed -n 's/^[[:space:]]*hash = "\([^"]*\)";/\1/p' "''${package_file}" | head -n 1)"

      if [ "''${current_version}" = "''${version}" ] && [ "''${current_hash}" = "''${hash}" ] && [ "''${force}" != true ]; then
        echo "Codex is already pinned to ''${version}. Use --force to rebuild."
        exit 0
      fi

      escape_sed_replacement() {
        printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
      }

      escaped_hash="$(escape_sed_replacement "''${hash}")"
      backup="$(mktemp)"
      cp "''${package_file}" "''${backup}"

      restore_on_error() {
        local status=$?
        if [ "''${status}" -ne 0 ]; then
          cp "''${backup}" "''${package_file}"
          echo "Restored ''${package_file} after failed update." >&2
        fi
        rm -f "''${backup}"
        exit "''${status}"
      }
      trap restore_on_error EXIT

      sed -i -E 's/^(  version = ")([^"]+)(";)/\1'"''${version}"'\3/' "''${package_file}"
      sed -i -E 's/^(    hash = ")sha256-[^"]+(";)/\1'"''${escaped_hash}"'\2/' "''${package_file}"

      echo "Building Codex ''${version}..."
      out_path="$(${nixCommand} build --no-link --print-out-paths "''${flake_attr}")"
      actual_version="$("''${out_path}/bin/codex" --version)"

      if [[ "''${actual_version}" != *"''${version}"* ]]; then
        echo "Built Codex reported ''${actual_version}, expected ''${version}." >&2
        exit 1
      fi

      trap - EXIT
      rm -f "''${backup}"

      echo "Updated ''${package_file}"
      echo "hash: ''${hash}"
    '';
  };

  updateOpencode = writeShellApplication {
    name = "update-opencode";
    inherit runtimeInputs;
    text = ''
      usage() {
        cat <<'EOF'
      Usage: update-opencode [latest|VERSION] [--force]

      Updates pkgs/opencode/default.nix to an upstream OpenCode release and lets
      Nix calculate the source and node_modules hashes.

      Examples:
        nix run .#update-opencode
        nix run .#update-opencode -- latest
        nix run .#update-opencode -- 1.15.13
        nix run .#update-opencode -- v1.15.13
      EOF
      }

      requested_version="''${1:-latest}"
      force=false
      fake_hash="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

      if [ "''${requested_version}" = "-h" ] || [ "''${requested_version}" = "--help" ]; then
        usage
        exit 0
      fi

      if [ "''${2:-}" = "--force" ]; then
        force=true
      elif [ -n "''${2:-}" ]; then
        usage >&2
        exit 1
      fi

      ${repoRootSnippet}

      package_file="''${repo_root}/pkgs/opencode/default.nix"
      flake_attr="path:''${repo_root}#nixosConfigurations.odin.pkgs.opencode"

      if [ ! -f "''${package_file}" ]; then
        echo "Missing package file: ''${package_file}" >&2
        exit 1
      fi

      if [ "''${requested_version}" = "latest" ]; then
        version="$(curl -fsSL https://api.github.com/repos/anomalyco/opencode/releases/latest \
          | jq -r '.tag_name | sub("^v"; "")')"
      else
        version="''${requested_version#v}"
      fi

      if [ -z "''${version}" ] || [ "''${version}" = "null" ]; then
        echo "Could not determine OpenCode version." >&2
        exit 1
      fi

      if [[ ! "''${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$ ]]; then
        echo "Invalid OpenCode version: ''${version}" >&2
        exit 1
      fi

      current_version="$(sed -n 's/^[[:space:]]*version = "\([^"]*\)";/\1/p' "''${package_file}" | head -n 1)"

      if [ "''${current_version}" = "''${version}" ] && [ "''${force}" != true ]; then
        echo "OpenCode is already pinned to ''${version}. Use --force to refresh hashes."
        exit 0
      fi

      escape_sed_replacement() {
        printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
      }

      replace_version() {
        sed -i -E 's/^(  version = ")([^"]+)(";)/\1'"''${version}"'\3/' "''${package_file}"
      }

      replace_source_hash() {
        local escaped_hash
        escaped_hash="$(escape_sed_replacement "$1")"
        sed -i -E '0,/^(    hash = ")sha256-[^"]+(";)/s//\1'"''${escaped_hash}"'\2/' "''${package_file}"
      }

      replace_node_modules_hash() {
        local escaped_hash
        escaped_hash="$(escape_sed_replacement "$1")"
        sed -i -E 's/^(    outputHash = ")sha256-[^"]+(";)/\1'"''${escaped_hash}"'\2/' "''${package_file}"
      }

      hash_from_failed_build() {
        local output status hash

        set +e
        output="$(${nixCommand} build --no-link "''${flake_attr}" 2>&1)"
        status=$?
        set -e

        printf '%s\n' "''${output}" >&2

        if [ "''${status}" -eq 0 ]; then
          echo "Expected a Nix hash mismatch, but the build succeeded." >&2
          return 1
        fi

        hash="$(printf '%s\n' "''${output}" \
          | sed -n 's/^[[:space:]]*got:[[:space:]]*\(sha256-[A-Za-z0-9+\/=]*\)$/\1/p' \
          | tail -n 1)"

        if [ -z "''${hash}" ]; then
          echo "Could not find a Nix hash mismatch in the build output." >&2
          return 1
        fi

        printf '%s\n' "''${hash}"
      }

      backup="$(mktemp)"
      cp "''${package_file}" "''${backup}"

      restore_on_error() {
        local status=$?
        if [ "''${status}" -ne 0 ]; then
          cp "''${backup}" "''${package_file}"
          echo "Restored ''${package_file} after failed update." >&2
        fi
        rm -f "''${backup}"
        exit "''${status}"
      }
      trap restore_on_error EXIT

      echo "Updating OpenCode to ''${version}"
      replace_version

      echo "Calculating source hash..."
      replace_source_hash "''${fake_hash}"
      source_hash="$(hash_from_failed_build)"
      replace_source_hash "''${source_hash}"

      echo "Calculating node_modules hash..."
      replace_node_modules_hash "''${fake_hash}"
      node_modules_hash="$(hash_from_failed_build)"
      replace_node_modules_hash "''${node_modules_hash}"

      echo "Building OpenCode ''${version}..."
      out_path="$(${nixCommand} build --no-link --print-out-paths "''${flake_attr}")"
      actual_version="$("''${out_path}/bin/opencode" --version)"

      if [ "''${actual_version}" != "''${version}" ]; then
        echo "Built OpenCode ''${actual_version}, expected ''${version}." >&2
        exit 1
      fi

      trap - EXIT
      rm -f "''${backup}"

      echo "Updated ''${package_file}"
      echo "source hash: ''${source_hash}"
      echo "node_modules hash: ''${node_modules_hash}"
    '';
  };

  updateGrokCli = writeShellApplication {
    name = "update-grok-cli";
    inherit runtimeInputs;
    text = ''
      usage() {
        cat <<'EOF'
      Usage: update-grok-cli [latest|VERSION] [--force]

      Updates pkgs/grok-cli/default.nix to the latest upstream Grok CLI Linux
      x64 release binary and verifies that the resulting package builds.

      Examples:
        nix run .#update-grok-cli
        nix run .#update-grok-cli -- latest
        nix run .#update-grok-cli -- 1.1.7
        nix run .#update-grok-cli -- grok-dev@1.1.7
      EOF
      }

      requested_version="''${1:-latest}"
      force=false
      asset_name="grok-linux-x64"

      if [ "''${requested_version}" = "-h" ] || [ "''${requested_version}" = "--help" ]; then
        usage
        exit 0
      fi

      if [ "''${2:-}" = "--force" ]; then
        force=true
      elif [ -n "''${2:-}" ]; then
        usage >&2
        exit 1
      fi

      ${repoRootSnippet}

      package_file="''${repo_root}/pkgs/grok-cli/default.nix"
      flake_attr="path:''${repo_root}#nixosConfigurations.odin.pkgs.grok-cli"

      if [ ! -f "''${package_file}" ]; then
        echo "Missing package file: ''${package_file}" >&2
        exit 1
      fi

      if [ "''${requested_version}" = "latest" ]; then
        release_url="https://api.github.com/repos/superagent-ai/grok-cli/releases/latest"
      else
        version="''${requested_version#grok-dev@}"
        version="''${version#v}"
        release_url="https://api.github.com/repos/superagent-ai/grok-cli/releases/tags/grok-dev@''${version}"
      fi

      release_json="$(curl -fsSL "''${release_url}")"
      version="$(printf '%s' "''${release_json}" | jq -r '.tag_name | sub("^grok-dev@"; "")')"

      if [ -z "''${version}" ] || [ "''${version}" = "null" ]; then
        echo "Could not determine Grok CLI version." >&2
        exit 1
      fi

      if [[ ! "''${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$ ]]; then
        echo "Invalid Grok CLI version: ''${version}" >&2
        exit 1
      fi

      digest="$(printf '%s' "''${release_json}" \
        | jq -r --arg name "''${asset_name}" '.assets[] | select(.name == $name) | .digest' \
        | head -n 1)"

      if [[ ! "''${digest}" =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
        echo "Could not find SHA-256 digest for ''${asset_name} in grok-dev@''${version}." >&2
        exit 1
      fi

      hash="$(${nixCommand} hash convert --hash-algo sha256 --to sri "''${digest#sha256:}")"
      current_version="$(sed -n 's/^[[:space:]]*version = "\([^"]*\)";/\1/p' "''${package_file}" | head -n 1)"
      current_hash="$(sed -n 's/^[[:space:]]*hash = "\([^"]*\)";/\1/p' "''${package_file}" | head -n 1)"

      if [ "''${current_version}" = "''${version}" ] && [ "''${current_hash}" = "''${hash}" ] && [ "''${force}" != true ]; then
        echo "Grok CLI is already pinned to ''${version}. Use --force to rebuild."
        exit 0
      fi

      escape_sed_replacement() {
        printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
      }

      escaped_hash="$(escape_sed_replacement "''${hash}")"
      backup="$(mktemp)"
      cp "''${package_file}" "''${backup}"

      restore_on_error() {
        local status=$?
        if [ "''${status}" -ne 0 ]; then
          cp "''${backup}" "''${package_file}"
          echo "Restored ''${package_file} after failed update." >&2
        fi
        rm -f "''${backup}"
        exit "''${status}"
      }
      trap restore_on_error EXIT

      sed -i -E 's/^(  version = ")([^"]+)(";)/\1'"''${version}"'\3/' "''${package_file}"
      sed -i -E '0,/^(      hash = ")sha256-[^"]+(";)/s//\1'"''${escaped_hash}"'\2/' "''${package_file}"

      echo "Building Grok CLI ''${version}..."
      out_path="$(${nixCommand} build --no-link --print-out-paths "''${flake_attr}")"
      actual_version="$("''${out_path}/bin/grok" --version)"

      if [ "''${actual_version}" != "''${version}" ]; then
        echo "Built Grok CLI reported ''${actual_version}, expected ''${version}." >&2
        exit 1
      fi

      trap - EXIT
      rm -f "''${backup}"

      echo "Updated ''${package_file}"
      echo "hash: ''${hash}"
    '';
  };

  updateAiTools = writeShellApplication {
    name = "update-ai-tools";
    runtimeInputs = [ coreutils ];
    text = ''
      usage() {
        cat <<'EOF'
      Usage: update-ai-tools [--force]

      Updates the locally pinned Odin AI CLI packages to their latest upstream
      releases and verifies each changed package builds.

      Packages:
        - Claude Code
        - Codex
        - Grok CLI
        - OpenCode
      EOF
      }

      force_arg=()

      if [ "''${1:-}" = "-h" ] || [ "''${1:-}" = "--help" ]; then
        usage
        exit 0
      elif [ "''${1:-}" = "--force" ]; then
        force_arg=(--force)
      elif [ -n "''${1:-}" ]; then
        usage >&2
        exit 1
      fi

      echo "==> update-claude-code"
      "${updateClaudeCode}/bin/update-claude-code" latest "''${force_arg[@]}"

      echo "==> update-codex"
      "${updateCodex}/bin/update-codex" latest "''${force_arg[@]}"

      echo "==> update-grok-cli"
      "${updateGrokCli}/bin/update-grok-cli" latest "''${force_arg[@]}"

      echo "==> update-opencode"
      "${updateOpencode}/bin/update-opencode" latest "''${force_arg[@]}"
    '';
  };
in
{
  "update-ai-tools" = updateAiTools;
  "update-claude-code" = updateClaudeCode;
  "update-codex" = updateCodex;
  "update-grok-cli" = updateGrokCli;
  "update-opencode" = updateOpencode;
}
