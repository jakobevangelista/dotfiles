---
name: managing-odin-storage
description: "Diagnose and safely reclaim disk space on Odin across Nix, rootless and rootful Docker, worktrees, caches, /tmp, and Muninn. Use when Odin is low on space, storage grows unexpectedly, or the user asks what can be cleared; do not use for generic CPU or RAM diagnosis unless disk pressure is involved."
---

# Manage Odin Storage

Keep Odin usable while identifying physical disk consumers and reclaiming only
data the user has authorized. Start read-only. Treat diagnosis, recommendation,
and deletion as separate phases.

## Non-negotiable boundaries

- Confirm `hostname` is `odin` before relying on this storage map.
- Do not mutate anything when the user requested inspection or diagnosis only.
- Obtain explicit authorization for the exact cleanup class immediately before
  deleting it. Approval for Nix GC does not authorize Docker or worktree cleanup.
- Distinguish Jakob's rootless Docker daemon (`docker`) from the rootful daemon
  (`sudo docker`). Inventory and clean them independently.
- Never delete Docker volumes merely because Docker calls them unused. Inspect
  their name, labels, size, and former project first; detached database volumes
  may contain the only copy of useful state.
- Preserve active and created containers unless the user explicitly names their
  project for removal. Never touch unrelated projects such as `music-sync` or
  `runsync` as collateral cleanup.
- `/var/lib/muninn` is the persistent Muninn workstation disk, normally about
  80 GiB. Do not delete, truncate, recreate, or sparsify it during ordinary
  storage cleanup.
- `/home/jakob/personal/ball-knowledge` is expected to be large. Do not move or
  delete its source tree; distinguish it from disposable build products and old
  Docker image variants.
- Inspect `/tmp` but leave it alone unless the user separately authorizes exact
  targets. Never blanket-delete `/tmp` on a live development host.
- Never manually remove files from `/nix/store`, Docker data roots, or a VM raw
  disk. Use the owning tool.

## Start with the bounded audit

Run the bundled read-only audit first:

```sh
/home/jakob/dotfiles/.config/agents/skills/managing-odin-storage/scripts/odin-storage-audit.sh
```

Use `--deep` only when the fast audit does not explain usage and there is enough
headroom for bounded directory walks. Do not start several full-tree `du` scans
in parallel. Stop any diagnostic process you started if it outlives the tool
call or no longer helps.

Establish these facts before recommending deletion:

1. Free blocks and inodes on `/`.
2. Whether usage is actively rising or another process is already reclaiming it.
3. Rootless and rootful Docker images, containers, volumes, and build cache.
4. Active Compose projects and the working directory/config behind suspicious
   containers (`com.docker.compose.project.*` labels).
5. Expected large trees versus genuinely disposable caches or stale artifacts.
6. Deleted-but-open files when `lsof` is available.

Docker's reported image sizes are logical and share layers. Do not add image,
cache, and volume numbers as though all were independent physical bytes. Measure
`df` before and after cleanup for the real result.

## Choose the least disruptive cleanup

Read [references/cleanup-map.md](references/cleanup-map.md) before performing a
cleanup. Prefer, in order:

1. Clearly regenerable language/tool caches.
2. Dead Nix store paths through `nix store gc`.
3. Docker build cache that is not serving an active build.
4. Specifically identified obsolete Docker images.
5. A named disposable Compose project, including its volumes only when the user
   explicitly wants that project and its data gone.
6. Stale worktrees only after checking VCS state and local-only commits.

Avoid `docker image prune -a` as a routine first response. Odin's Simcity E2Es
reuse large ClickHouse, Kafka, Scylla, FoundationDB, Postgres, and runtime
images. Removing all unreferenced images can make the next E2E download/unpack
tens of gigabytes, create OverlayFS and database initialization pressure, and
make SSH feel laggy. Prefer targeted removal of obsolete Ball Knowledge or E2E
variants and retain common infrastructure images when another test is likely.

Memory limits do not prevent I/O contention. Before blaming SSH or hardware,
check whether a cold Compose stack is pulling images or starting databases and
inspect `/proc/pressure/io`, `vmstat`, Docker events, and container ages.

## Emergency behavior

When less than 10 GiB is available, keep the investigation light so the agent
remains usable. Do not build software, download packages, generate giant command
outputs, or run exhaustive scans. Report the fast audit, identify one low-risk
high-yield action, and execute only after authorization. If another GC or prune
is already running, monitor it rather than starting a competing cleanup.

## Verify and report

After every mutation:

- Check `df -h /` and report actual space recovered.
- Confirm intended containers still exist and active projects remain healthy.
- Confirm the exact deleted project/volume/image is gone.
- State rebuild, re-download, cold-start, or data-loss consequences.
- List deliberately preserved areas, especially volumes, `/tmp`, Muninn, active
  projects, and worktrees with unreviewed VCS state.

