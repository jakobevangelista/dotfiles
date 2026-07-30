#!/bin/zsh

# Back up all dated video project folders without duplicating raw footage.

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/video_workflow_lib.zsh"

VIDEOS_ROOT="$HOME/Documents/videos"
NAS_VOLUME_NAME="plusEvMediaBackup"
DRY_RUN=false

show_help() {
    cat <<EOF
Usage: ${0:t} [OPTIONS] [VIDEOS_ROOT]

Back up every top-level dated project folder using backupProject.
Only folders matching YYYY-MM-DD_* are included.

Options:
  -n, --dry-run       Preview backups without copying files
  --nas-volume NAME   Mounted NAS volume name (default: $NAS_VOLUME_NAME)
  -h, --help          Show this help message

Examples:
  ${0:t}
  ${0:t} --dry-run
  ${0:t} ~/Documents/videos
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

    local -a projects
    projects=("$VIDEOS_ROOT"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*(N/))

    if (( ${#projects[@]} == 0 )); then
        print -- "No dated project folders found in: $VIDEOS_ROOT"
        exit 0
    fi

    print -- "============================================="
    if $DRY_RUN; then
        print -- "=== Dated Project Backups (DRY RUN) ==="
    else
        print -- "=== Dated Project Backups ==="
    fi
    print -- "============================================="
    print -- "Videos root: $VIDEOS_ROOT"
    print -- "NAS volume:  $nas_volume"
    print -- "Projects:    ${#projects[@]}"
    print -- "Mode:        project files only; footage/ excluded"
    print -- ""

    local completed=0
    local failed=0
    local index=0
    local -a backup_args

    backup_args=(--nas-volume "$NAS_VOLUME_NAME")
    $DRY_RUN && backup_args+=(--dry-run)

    for project in "${projects[@]}"; do
        ((index++))
        print -- "[$index/${#projects[@]}] ${project:t}"

        if "$SCRIPT_DIR/backup_project.sh" "${backup_args[@]}" "$project"; then
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
        print -- "=== Backup Complete ==="
    fi
    print -- "Completed: $completed"
    print -- "Failed:    $failed"
    print -- "============================================="

    (( failed == 0 ))
}

main "$@"
