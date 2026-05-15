#!/bin/zsh

# Restore archived project media from NAS CameraBackup back into local footage/.

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/video_workflow_lib.zsh"

NAS_VOLUME_NAME="plusEvMediaBackup"
CAMERA_BACKUP_SUBPATH="CameraBackup"
DRY_RUN=false

PROJECT_PATH=""
RESTORE_COUNT=0
SKIPPED_COUNT=0
ERROR_COUNT=0

trap 'cleanup_active_copy; print -- ""; print -- "Restore cancelled."; exit 130' SIGINT SIGTERM

show_help() {
    cat <<EOF
Usage: ${0:t} [OPTIONS] PROJECT_PATH

Restore local project footage from the NAS archive using media-manifest.tsv.

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

    local manifest="$PROJECT_PATH/media-manifest.tsv"
    if [[ ! -f "$manifest" ]]; then
        log_error "No media manifest found: $manifest"
        exit 1
    fi

    local nas_volume="/Volumes/$NAS_VOLUME_NAME"
    local archive_root="$nas_volume/$CAMERA_BACKUP_SUBPATH"
    if [[ ! -d "$archive_root" ]]; then
        log_error "NAS archive not mounted: $archive_root"
        exit 1
    fi

    print -- "============================================="
    if $DRY_RUN; then
        print -- "=== Project Media Restore (DRY RUN) ==="
    else
        print -- "=== Project Media Restore ==="
    fi
    print -- "============================================="
    print -- "Project:   $PROJECT_PATH"
    print -- "Manifest:  $manifest"
    print -- "Archive:   $archive_root"
    print -- ""

    local line_no=0
    while IFS=$'\t' read -r recording_datetime size_bytes camera original_name local_rel archive_rel source_path; do
        ((line_no++))
        (( line_no == 1 )) && continue
        [[ -z "$local_rel" || -z "$archive_rel" ]] && continue

        local local_path="$PROJECT_PATH/$local_rel"
        local archive_path="$archive_root/$archive_rel"

        print -- "[$((line_no - 1))] $original_name"
        print -- "      Local:   .../$local_rel"
        print -- "      Archive: .../$archive_rel"

        if file_matches_size "$local_path" $size_bytes; then
            print -- "      Skipped existing local file."
            ((SKIPPED_COUNT++))
            print -- ""
            continue
        fi

        if [[ -e "$local_path" ]]; then
            log_error "Local file exists with a different size: $local_path"
            ((ERROR_COUNT++))
            print -- ""
            continue
        fi

        if ! file_matches_size "$archive_path" $size_bytes; then
            log_error "Archive file missing or wrong size: $archive_path"
            ((ERROR_COUNT++))
            print -- ""
            continue
        fi

        if $DRY_RUN; then
            print -- "      Would restore."
            print -- ""
            continue
        fi

        if copy_file_safely "$archive_path" "$local_path" "$local_rel"; then
            ((RESTORE_COUNT++))
        else
            ((ERROR_COUNT++))
        fi

        print -- ""
    done < "$manifest"

    print -- "============================================="
    if $DRY_RUN; then
        print -- "=== Dry Run Complete ==="
    else
        print -- "=== Restore Complete ==="
    fi
    print -- "Restored: $RESTORE_COUNT"
    print -- "Skipped:  $SKIPPED_COUNT"
    print -- "Errors:   $ERROR_COUNT"
    print -- "============================================="

    (( ERROR_COUNT == 0 ))
}

main "$@"
