#!/bin/zsh

# Stage remaining Disney backups to Unraid NVMe over LAN SSH, then archive
# from NVMe to the HDD array locally on Unraid.

set -u

REMOTE_HOST="${REMOTE_HOST:-10.0.0.134}"
REMOTE="root@$REMOTE_HOST"
KNOWN_HOSTS="${KNOWN_HOSTS:-$HOME/.ssh/known_hosts_unraid_lan}"

DEST_ROOT="/mnt/disk1/plusEvMediaBackup/FullProjectBackups/2026-07-03/disney"
STAGE_ROOT="/mnt/nvme_cache/backup-staging/disney-2026-07-03"

T7_SRC="/Volumes/t7Shield"
DISNEY6_SRC="$HOME/Documents/videos/disney6"
DISNEY7_CLIP_SRC="/Volumes/Untitled/PRIVATE/M4ROOT/CLIP"

DELETE_PARTIAL_T7=false
SKIP_T7=false
SKIP_DISNEY67=false

SSH_OPTS=(
    -o BatchMode=yes
    -o UserKnownHostsFile="$KNOWN_HOSTS"
    -o StrictHostKeyChecking=accept-new
)

RSYNC_SSH="ssh -c aes128-gcm@openssh.com -o Compression=no -o BatchMode=yes -o UserKnownHostsFile=$KNOWN_HOSTS -o StrictHostKeyChecking=accept-new"

RSYNC_ARGS=(
    -ah
    --progress
    --partial
    --stats
    --no-owner
    --no-group
    --exclude=.DS_Store
    --exclude='._*'
    --exclude='.fseventsd/'
    --exclude='.Spotlight-V100/'
    --exclude='.Trashes/'
)

log() {
    print -- "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    print -u2 -- "Error: $*"
    exit 1
}

usage() {
    cat <<EOF
Usage: ${0:t} [OPTIONS]

Options:
  --delete-partial-t7   Delete existing partial final t7Shield backup first
  --skip-t7             Skip T7 Shield batch
  --skip-disney67       Skip disney6 + disney7 batch
  -h, --help            Show this help

Environment overrides:
  REMOTE_HOST=$REMOTE_HOST
  KNOWN_HOSTS=$KNOWN_HOSTS
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --delete-partial-t7)
                DELETE_PARTIAL_T7=true
                shift
                ;;
            --skip-t7)
                SKIP_T7=true
                shift
                ;;
            --skip-disney67)
                SKIP_DISNEY67=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done
}

remote() {
    ssh "${SSH_OPTS[@]}" "$REMOTE" "$@"
}

safe_remote_rm_rf() {
    local target="$1"

    if [[ "$target" == /mnt/nvme_cache/backup-staging/* || "$target" == "$DEST_ROOT/t7Shield" ]]; then
        log "Deleting remote path: $target"
        remote "rm -rf -- '$target'"
    else
        die "Refusing unsafe remote delete: $target"
    fi
}

validate_source() {
    local source_path="$1"
    local label="$2"

    [[ -d "$source_path" ]] || die "$label source not mounted/found: $source_path"
}

prepare_remote() {
    mkdir -p "${KNOWN_HOSTS:h}" || die "Could not create known_hosts directory"

    log "Testing direct LAN SSH to $REMOTE"
    remote "echo SSH_CONNECTION=\$SSH_CONNECTION; hostname; df -h /mnt/nvme_cache /mnt/disk1" || die "Cannot SSH to $REMOTE"

    log "Preparing remote staging and destination roots"
    remote "mkdir -p '$STAGE_ROOT' '$DEST_ROOT'"
}

write_info_file() {
    local dest="$1"
    local title="$2"
    local source_text="$3"

    remote "mkdir -p '$dest' && printf '%s\n' 'Backup type: $title' 'Source: $source_text' 'Destination: $dest' 'Created: $(date '+%Y-%m-%d %H:%M:%S')' 'Staging: $STAGE_ROOT' > '$dest/backup-info.txt'"
}

stage_source() {
    local label="$1"
    local source_path="$2"
    local stage_path="$3"

    validate_source "$source_path" "$label"
    safe_remote_rm_rf "$stage_path"
    remote "mkdir -p '$stage_path'"

    log "Staging $label to NVMe"
    log "Source:      $source_path/"
    log "Destination: $REMOTE:$stage_path/"

    rsync "${RSYNC_ARGS[@]}" -e "$RSYNC_SSH" "$source_path/" "$REMOTE:$stage_path/" || die "$label stage failed"
}

archive_stage() {
    local label="$1"
    local stage_path="$2"
    local dest_path="$3"
    local source_text="$4"

    log "Archiving $label from NVMe to HDD array"
    log "Source:      $stage_path/"
    log "Destination: $dest_path/"

    write_info_file "$dest_path" "$label NVMe-staged backup" "$source_text"

    remote "rsync -ah --progress --partial --stats --no-owner --no-group '$stage_path/' '$dest_path/' && chown -R nobody:users '$dest_path' && chmod -R u+rwX,go+rX '$dest_path' && rm -rf -- '$stage_path'" || die "$label archive failed"
}

run_t7_batch() {
    local stage_path="$STAGE_ROOT/t7Shield"
    local dest_path="$DEST_ROOT/t7Shield"

    if $DELETE_PARTIAL_T7; then
        safe_remote_rm_rf "$dest_path"
    fi

    stage_source "t7Shield" "$T7_SRC" "$stage_path"
    archive_stage "t7Shield" "$stage_path" "$dest_path" "$T7_SRC"
}

run_disney67_batch() {
    local disney6_stage="$STAGE_ROOT/disney6"
    local disney7_stage="$STAGE_ROOT/disney7"
    local disney6_dest="$DEST_ROOT/disney6"
    local disney7_dest="$DEST_ROOT/disney7"

    stage_source "disney6" "$DISNEY6_SRC" "$disney6_stage"
    stage_source "disney7 CLIP" "$DISNEY7_CLIP_SRC" "$disney7_stage/CLIP"

    archive_stage "disney6" "$disney6_stage" "$disney6_dest" "$DISNEY6_SRC"
    archive_stage "disney7" "$disney7_stage" "$disney7_dest" "$DISNEY7_CLIP_SRC"
}

main() {
    parse_args "$@"

    log "Disney NVMe batch backup starting"
    log "Remote:      $REMOTE"
    log "Stage root:  $STAGE_ROOT"
    log "Final root:  $DEST_ROOT"

    prepare_remote

    if ! $SKIP_T7; then
        run_t7_batch
    fi

    if ! $SKIP_DISNEY67; then
        run_disney67_batch
    fi

    log "Disney NVMe batch backup complete"
    remote "df -h /mnt/nvme_cache /mnt/disk1"
}

main "$@"
