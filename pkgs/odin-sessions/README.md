# CLI session recovery and Odin-to-Muninn handoff

`odin-sessions` is installed on Odin and Muninn through Home Manager. It uses
Nix's Python, tmux, SSH, and Neovim. Home Manager installs `~/bin/odin-sessions`.
An older Odin-only launcher under `~/.local/bin` can take precedence, depending
on PATH. Check `command -v odin-sessions` after installation and update a
shadowing launcher to the same package; preserve its backup and private snapshots.

Code lives in the Nix store. Private snapshots stay under
`${XDG_DATA_HOME:-~/.local/share}/odin-session-rescue`, retaining the old default
location. `ODIN_SESSION_RESCUE_DIR` can select another private state directory.
Snapshots and transcripts must not be committed to dotfiles or the Nix store.

## Move the CLI workspace to Muninn

First ensure the updated configuration is installed on both machines and
Muninn is running. This tool does not start, restart, or reconfigure the VM.
The migration uses Odin's private SSH route to `jakob@10.88.0.10` and requires
its existing trusted host key. It does not depend on either tailnet.

1. Finish pending agent work and take a fresh snapshot **on Odin**:

   ```sh
   odin-sessions snapshot
   odin-sessions verify
   ```

2. Close the source Codex and Amp CLI sessions/server cleanly. Keep a plain
   shell for the transfer. Stop editing after the snapshot; it contains the
   editor buffers from that moment. The tool never kills source processes.

3. Transfer the snapshot **from Odin**:

   ```sh
   odin-sessions send muninn
   ```

   Send refuses while source Codex/Amp CLI processes are running. The
   destination receives into a private staging directory, checks hashes and
   backup integrity, then publishes the snapshot and `latest`. Existing
   snapshots are never overwritten; a failed transfer keeps the previous
   `latest`. No agents or tmux panes are started by the transfer.

4. Inspect and restore **inside Muninn**:

   ```sh
   odin-sessions restore --dry-run
   odin-sessions restore --handoff
   tmux attach
   ```

   `--handoff` confirms that the source CLI sessions are closed. It is needed
   when the snapshot comes from another host. Keep them closed on Odin after
   transfer: the script cannot prevent you from manually reopening a source
   conversation later. Existing destination tmux sessions are skipped.

For a layout rehearsal inside Muninn without starting agents:

```sh
odin-sessions restore --socket session-preview --shells-only
tmux -L session-preview attach
```

When finished with that rehearsal only:

```sh
tmux -L session-preview kill-server
```

Use `--snapshot PATH` with `verify`, `restore`, or `send` to select an older
snapshot explicitly. The latest snapshot may be stale until refreshed.

## What moves

- tmux sessions, window/pane layout, names, working directories, and selection.
- Codex CLI conversations by saved ID, preserving the existing restore flags.
- Identified Amp conversations and its no-TUI server.
- Neovim sessions and captured unsaved buffers, restored into memory.
- Ordinary shells in their saved directories.

Restore checks required directories, executables, Codex transcript presence,
and active destination agents before creating panes. Muninn's shared worktree
paths already match Odin's. Portable Codex rollouts are shared, while SQLite
databases stay private to each host. A fresh guest without the expected Codex
SQLite index can discover IDs from transcript metadata. Do not share live
SQLite databases or overwrite guest databases with the backup.

The script restores tmux workspace state, not running computations, pending
tool calls, SSH connections, or unsent terminal input. Unsupported programs
reopen as shells and are listed in the snapshot notes. Current supported
agent adapters are Codex and Amp. Terminal captures are saved as recovery
files, never replayed as shell input.

## Recover locally after a reboot

The original workflow still works:

```sh
odin-sessions snapshot
odin-sessions verify
# After the reboot:
odin-sessions restore
```

The same-boot agent-restore guard remains in place. A shells-only rehearsal
can run without a reboot. The tool preserves existing tmux sessions.

Restored applications run as commands inside interactive shells. Quitting an
application, interrupting it with Ctrl+C, or a startup failure returns to that
shell instead of closing the pane or its window. Restore temporarily disables
window renumbering while placing saved indexes, then inherits the configured
policy again. Automatic window naming also follows the user's tmux settings.

Older restores replaced their pane's shell with the application. Updating the
tool does not change those already-running processes. They can be protected
without restarting applications using pane-local `remain-on-exit` and a
one-time `pane-died` hook that respawns a shell (without `-k`), then removes the
hook and restores the original exit setting. Scope such repairs to identified
restored panes; do not restart the session or replay old application commands.

## Build and validation

```sh
cd ~/dotfiles
nix build --no-link --no-update-lock-file "path:$PWD#odin-sessions"
nix flake check --no-build --no-update-lock-file "path:$PWD"
```

The package tests recovery compatibility, transcript-based discovery,
cross-host guards, transfer verification, overwrite refusal, and unsafe
archive rejection. Isolated tmux tests verify shell survival after Ctrl+C,
normal exits, and application failures, plus inherited window settings.
Real session handoff still requires source agents to be
closed and Muninn to be running with the new package installed.
