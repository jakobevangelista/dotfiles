# Odin storage cleanup map

Use this reference after the read-only audit identifies a likely target. Commands
shown under **Clean** are destructive or cache-invalidating and require explicit
authorization for that target.

## Nix store

Inspect:

```sh
df -h /
nix-store --gc --print-dead
```

Clean dead paths only:

```sh
sudo nix store gc
```

This preserves live GC roots. Do not manually edit `/nix/store`. Do not use
generation-deleting variants such as `nix-collect-garbage -d` unless the user
also authorizes deleting old user/system generations. Nix enumeration can be
slow; do not combine it with per-path `du` during an emergency.

## Regenerable user caches

Inspect:

```sh
du -xsh ~/.cache/go-build ~/go/pkg/mod ~/.cache/uv ~/.cache/pnpm 2>/dev/null
```

Clean only the authorized cache:

```sh
go clean -cache
go clean -modcache
uv cache clean
pnpm store prune
```

The Go build cache is usually the safest large target. Module/package cache
cleanup forces downloads later and may be undesirable before offline work.

## Rootless Docker

Inspect:

```sh
docker system df -v
docker compose ls
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
docker image ls --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}'
```

Use Compose labels to attribute a container before touching it:

```sh
docker inspect --format '{{json .Config.Labels}}' CONTAINER | jq
```

Build cache cleanup:

```sh
docker builder prune -af
```

Remove exact obsolete images rather than the whole cache when future E2Es are
likely:

```sh
docker image rm IMAGE_OR_TAG...
```

`docker image prune -a -f` preserves images referenced by existing containers,
but removes warm images needed only by future tests. Use it only when the user
accepts the next cold-start cost. Do not run `docker system prune --volumes` as
a general cleanup command.

For an explicitly disposable Compose project, recover its config path and use
that project's own Compose teardown:

```sh
docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}} {{index .Config.Labels "com.docker.compose.project.config_files"}}' CONTAINER
docker compose -p PROJECT -f CONFIG_FILE down -v --remove-orphans
```

The `-v` flag destroys project data. Omit it unless the user asked for the
project's stored data to disappear too.

## Rootful Docker

Rootful Docker is separate and usually requires Jakob to enter a sudo password:

```sh
sudo docker system df -v
sudo docker compose ls
sudo du -xhd1 /var/lib/docker
```

Apply the same project-scoping and volume rules as rootless Docker. A stopped
container can keep a large volume linked; remove the exact container/project
before its exact volume. Never use a broad rootful prune while `runsync` or
another retained project depends on the daemon.

## Worktrees and build products

`~/inngest-work` contains many jj workspaces. Directory age or size alone is not
proof that a workspace is disposable. Before removal, identify its repository,
run `jj status`, inspect bookmarks and local-only commits, and confirm whether a
PR shipped. Use jj workspace operations when applicable; do not blindly `rm -rf`
a registered workspace.

Large `target`, `node_modules`, coverage, generated image, or test-output trees
inside a retained workspace may be individually regenerable. Attribute them to
the owning project and confirm no active build/test uses them first.

## `/tmp`, deleted files, and journals

Inspect without deleting:

```sh
du -xhd1 /tmp | sort -h
find /tmp -xdev -mindepth 1 -maxdepth 1 -printf '%TY-%Tm-%Td %TT %u %p\n' | sort
journalctl --disk-usage
lsof +L1
```

Delete only named, attributed, inactive temporary trees. For deleted-but-open
files, stopping/restarting the owning process releases space; deleting the path
again does nothing. Journal vacuuming needs separate authorization and should
retain enough history for crash/OOM diagnosis.

## Muninn and expected large data

- `/var/lib/muninn/muninn-state.raw` is persistent workstation state. Preserve
  it during normal cleanup.
- `/home/jakob/personal/ball-knowledge` is expected source/data. Preserve it;
  target obsolete Docker variants or regenerable outputs instead.
- Detached database volumes, agent histories, and session-rescue data are not
  caches merely because they are old or currently inactive.

