#!/bin/zsh

# Back up a Premiere project folder without duplicating raw footage.

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/video_workflow_lib.zsh"

NAS_VOLUME_NAME="plusEvMediaBackup"
PROJECT_BACKUP_SUBPATH="ProjectBackups"
DRY_RUN=false

PROJECT_PATH=""

show_help() {
    cat <<EOF
Usage: ${0:t} [OPTIONS] PROJECT_PATH

Back up a local video project to the NAS, excluding raw footage.

Options:
  -n, --dry-run       Preview actions without copying files
  --nas-volume NAME   Mounted NAS volume name (default: $NAS_VOLUME_NAME)
  -h, --help          Show this help message

Example:
  ${0:t} ~/Documents/videos/2026-04-26_first_short
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
                if [[ -z "$PROJECT_PATH" ]]; then
                    PROJECT_PATH="$1"
                else
                    log_error "Unexpected argument: $1"
                    show_help
                    exit 1
                fi
                shift
                ;;
        esac
    done
}

main() {
    parse_args "$@"

    if [[ -z "$PROJECT_PATH" ]]; then
        show_help
        exit 1
    fi

    PROJECT_PATH=$(expand_path "$PROJECT_PATH")

    if [[ ! -d "$PROJECT_PATH" ]]; then
        log_error "Project path not found: $PROJECT_PATH"
        exit 1
    fi

    local nas_volume="/Volumes/$NAS_VOLUME_NAME"
    if [[ ! -d "$nas_volume" ]]; then
        log_error "NAS volume not mounted: $nas_volume"
        exit 1
    fi

    local project_name="${PROJECT_PATH:t}"
    local dest_root="$nas_volume/$PROJECT_BACKUP_SUBPATH"
    local dest_path="$dest_root/$project_name"

    print -- "============================================="
    if $DRY_RUN; then
        print -- "=== Project Backup (DRY RUN) ==="
    else
        print -- "=== Project Backup ==="
    fi
    print -- "============================================="
    print -- "Project:     $PROJECT_PATH"
    print -- "Destination: $dest_path"
    print -- "Excluding:   footage/ and cache files"
    print -- ""

    if ! $DRY_RUN; then
        mkdir -p "$dest_path" || exit 1
        cat > "$dest_path/backup-info.txt" <<EOF
Project: $project_name
Source: $PROJECT_PATH
Backed up: $(date "+%Y-%m-%d %H:%M:%S")
Raw footage: excluded; restore with restoreProjectMedia using media-manifest.tsv
EOF
    fi

    local -a rsync_args
    rsync_args=(
        -ah
        --progress
        --stats
        --exclude=footage/
        --exclude=.DS_Store
        --exclude='._*'
        --exclude='*.tmp'
        --exclude='*.pek'
        --exclude='*.cfa'
        --exclude='*.ims'
        --exclude='Adobe Premiere Pro Audio Previews/'
        --exclude='Adobe Premiere Pro Video Previews/'
        --exclude='Media Cache/'
        --exclude='Media Cache Files/'
        --exclude='Peak Files/'
    )

    if $DRY_RUN; then
        rsync_args+=(--dry-run)
    fi

    rsync "${rsync_args[@]}" "$PROJECT_PATH/" "$dest_path/"
    local rsync_status=$?

    if (( rsync_status == 0 )); then
        print -- ""
        if $DRY_RUN; then
            print -- "Project backup dry run complete: $dest_path"
        else
            print -- "Project backup complete: $dest_path"
        fi
    fi

    return $rsync_status
}

main "$@"
