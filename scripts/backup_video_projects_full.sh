#!/bin/zsh

# One-time safety backup for all dated video project folders, including footage.

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/video_workflow_lib.zsh"

VIDEOS_ROOT="$HOME/Documents/videos"
NAS_VOLUME_NAME="plusEvMediaBackup"
DEST_SUBPATH="FullProjectBackups/$(date +%Y-%m-%d)"
DRY_RUN=false

show_help() {
    cat <<EOF
Usage: ${0:t} [OPTIONS] [VIDEOS_ROOT]

Back up every top-level dated project folder, including footage/.
Only folders matching YYYY-MM-DD_* are included.

This is intended as a one-time safety backup. For future no-duplicate
project backups, use backupVideoProjects instead.

Options:
  -n, --dry-run       Preview backups without copying files
  --nas-volume NAME   Mounted NAS volume name (default: $NAS_VOLUME_NAME)
  --dest-subpath PATH Destination under NAS volume (default: $DEST_SUBPATH)
  -h, --help          Show this help message

Examples:
  ${0:t}
  ${0:t} --dry-run
  ${0:t} --dest-subpath FullProjectBackups/pre-cleanup
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            --nas-volume)
                [[ $# -ge 2 ]] || { log_error "--nas-volume requires a value"; exit 1; }
                NAS_VOLUME_NAME="$2"
                shift 2
                ;;
            --dest-subpath)
                [[ $# -ge 2 ]] || { log_error "--dest-subpath requires a value"; exit 1; }
                DEST_SUBPATH="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -* )
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                VIDEOS_ROOT="$1"
                shift
                ;;
        esac
    done
}

main() {
    parse_args "$@"
    VIDEOS_ROOT=$(expand_path "$VIDEOS_ROOT")

    if [[ ! -d "$VIDEOS_ROOT" ]]; then
        log_error "Videos root not found: $VIDEOS_ROOT"
        exit 1
    fi

    local nas_volume="/Volumes/$NAS_VOLUME_NAME"
    if [[ ! -d "$nas_volume" ]]; then
        log_error "NAS volume not mounted: $nas_volume"
        print -- "Mount it first, for example: open \"smb://10.0.0.134/$NAS_VOLUME_NAME\""
        exit 1
    fi

    local dest_root="$nas_volume/$DEST_SUBPATH"
    local -a projects
    projects=("$VIDEOS_ROOT"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*(N/))

    if (( ${#projects[@]} == 0 )); then
        print -- "No dated project folders found in: $VIDEOS_ROOT"
        exit 0
    fi

    print -- "============================================="
    if $DRY_RUN; then
        print -- "=== Full Dated Project Backup (DRY RUN) ==="
    else
        print -- "=== Full Dated Project Backup ==="
    fi
    print -- "============================================="
    print -- "Videos root: $VIDEOS_ROOT"
    print -- "Destination: $dest_root"
    print -- "Projects:    ${#projects[@]}"
    print -- "Mode:        full project folders, including footage/"
    print -- ""

    if ! $DRY_RUN; then
        mkdir -p "$dest_root" || exit 1
        cat > "$dest_root/backup-info.txt" <<EOF
Backup type: Full dated project safety backup
Source: $VIDEOS_ROOT
Destination: $dest_root
Created: $(date "+%Y-%m-%d %H:%M:%S")
Includes: top-level YYYY-MM-DD_* project folders, including footage/
Excludes: .DS_Store and AppleDouble ._* files
EOF
    fi

    local -a rsync_args
    rsync_args=(
        -ah
        --progress
        --partial
        --stats
        --exclude=.DS_Store
        --exclude='._*'
    )

    if $DRY_RUN; then
        rsync_args+=(--dry-run)
    fi

    local completed=0
    local failed=0
    local index=0

    for project in "${projects[@]}"; do
        ((index++))
        local dest_path="$dest_root/${project:t}"
        print -- "[$index/${#projects[@]}] ${project:t}"

        if rsync "${rsync_args[@]}" "$project/" "$dest_path/"; then
            ((completed++))
        else
            ((failed++))
        fi

        print -- ""
    done

    print -- "============================================="
    if $DRY_RUN; then
        print -- "=== Dry Run Complete ==="
    else
        print -- "=== Full Backup Complete ==="
    fi
    print -- "Completed: $completed"
    print -- "Failed:    $failed"
    print -- "Destination: $dest_root"
    print -- "============================================="

    (( failed == 0 ))
}

main "$@"
