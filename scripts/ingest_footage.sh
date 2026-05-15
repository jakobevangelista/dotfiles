#!/bin/zsh

# Ingest video media into a local editing project and the NAS archive.

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/video_workflow_lib.zsh"

NAS_VOLUME_NAME="plusEvMediaBackup"
CAMERA_BACKUP_SUBPATH="CameraBackup"
CAMERA_NAME="zve1"
DRY_RUN=false

SOURCE_PATH=""
PROJECT_PATH=""
START_TIME=0
MEDIA_COUNT=0
LOCAL_COPY_COUNT=0
ARCHIVE_COPY_COUNT=0
SKIPPED_COUNT=0
ERROR_COUNT=0
declare -a MEDIA_FILES

trap 'cleanup_active_copy; print -- ""; print -- "Ingest cancelled."; exit 130' SIGINT SIGTERM

show_help() {
    cat <<EOF
Usage: ${0:t} [OPTIONS] SOURCE_PATH PROJECT_PATH

Ingest video files into a local project and archive them to the NAS.

Arguments:
  SOURCE_PATH     SD card, T7 folder, or any folder containing media
  PROJECT_PATH    Existing local project folder created by mkproj

Options:
  -n, --dry-run       Preview actions without copying files
  --camera NAME       Camera folder name under footage/date paths (default: $CAMERA_NAME)
  --nas-volume NAME   Mounted NAS volume name (default: $NAS_VOLUME_NAME)
  -h, --help          Show this help message

Examples:
  ${0:t} /Volumes/Untitled ~/Documents/videos/2026-04-26_first_short
  ${0:t} "/Volumes/T7 Shield/japan1" ~/Documents/videos/2026-04-26_first_short
  ${0:t} --camera a6100 /Volumes/Untitled ~/Documents/videos/2026-04-26_first_short
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            --camera)
                [[ $# -ge 2 ]] || { log_error "--camera requires a value"; exit 1; }
                CAMERA_NAME="$2"
                shift 2
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
                if [[ -z "$SOURCE_PATH" ]]; then
                    SOURCE_PATH="$1"
                elif [[ -z "$PROJECT_PATH" ]]; then
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

ensure_manifest() {
    local manifest="$1"

    if [[ ! -f "$manifest" ]]; then
        print -r -- $'recording_datetime\tsize_bytes\tcamera\toriginal_name\tlocal_relative_path\tarchive_relative_path\tsource_path' > "$manifest"
    fi
}

manifest_has_entry() {
    local manifest="$1"
    local local_rel="$2"
    local archive_rel="$3"

    [[ -f "$manifest" ]] || return 1
    awk -F '\t' -v local_rel="$local_rel" -v archive_rel="$archive_rel" \
        'NR > 1 && $5 == local_rel && $6 == archive_rel { found = 1 } END { exit(found ? 0 : 1) }' "$manifest"
}

append_manifest_entry() {
    local manifest="$1"
    local recording_datetime="$2"
    local size_bytes="$3"
    local original_name="$4"
    local local_rel="$5"
    local archive_rel="$6"
    local source_path="$7"

    ensure_manifest "$manifest"

    if manifest_has_entry "$manifest" "$local_rel" "$archive_rel"; then
        return 0
    fi

    print -r -- "${recording_datetime}	${size_bytes}	${CAMERA_NAME}	${original_name}	${local_rel}	${archive_rel}	${source_path}" >> "$manifest"
}

path_available_for_size() {
    local candidate_path="$1"
    local size_bytes=$2

    [[ ! -e "$candidate_path" ]] || file_matches_size "$candidate_path" $size_bytes
}

resolve_unique_paths() {
    local project_root="$1"
    local archive_root="$2"
    local year="$3"
    local month="$4"
    local day="$5"
    local filename="$6"
    local size_bytes=$7

    local stem="${filename:r}"
    local ext="${filename:e}"
    local counter=0
    local candidate local_rel archive_rel local_path archive_path

    while (( counter <= 1000 )); do
        if (( counter == 0 )); then
            candidate="$filename"
        elif [[ -n "$ext" ]]; then
            candidate="${stem}_${counter}.${ext}"
        else
            candidate="${stem}_${counter}"
        fi

        local_rel="footage/$year/$month/$day/$CAMERA_NAME/$candidate"
        archive_rel="$year/$month/$day/$CAMERA_NAME/$candidate"
        local_path="$project_root/$local_rel"
        archive_path="$archive_root/$archive_rel"

        if path_available_for_size "$local_path" $size_bytes && path_available_for_size "$archive_path" $size_bytes; then
            print -r -- "$local_rel	$archive_rel	$local_path	$archive_path"
            return 0
        fi

        ((counter++))
    done

    return 1
}

collect_media_files() {
    local source_path="$1"
    MEDIA_FILES=()

    if [[ -f "$source_path" ]]; then
        case "${source_path:l}" in
            *.mp4|*.mov) MEDIA_FILES+=("$source_path") ;;
        esac
    else
        while IFS= read -r -d '' file; do
            [[ "${file:t}" == ._* ]] && continue
            MEDIA_FILES+=("$file")
        done < <(find "$source_path" \
            \( -name .Trashes -o -name .Trash -o -name .Spotlight-V100 -o -name .fseventsd -o -name .TemporaryItems \) -prune -o \
            -type f \( -iname "*.mp4" -o -iname "*.mov" \) \
            ! -name ".DS_Store" ! -name "._*" -print0 2>/dev/null)
    fi
}

main() {
    parse_args "$@"

    if [[ -z "$SOURCE_PATH" || -z "$PROJECT_PATH" ]]; then
        show_help
        exit 1
    fi

    SOURCE_PATH=$(expand_path "$SOURCE_PATH")
    PROJECT_PATH=$(expand_path "$PROJECT_PATH")

    local nas_volume="/Volumes/$NAS_VOLUME_NAME"
    local archive_root="$nas_volume/$CAMERA_BACKUP_SUBPATH"
    local manifest="$PROJECT_PATH/media-manifest.tsv"

    if [[ ! -e "$SOURCE_PATH" ]]; then
        log_error "Source path not found: $SOURCE_PATH"
        exit 1
    fi

    if [[ ! -d "$PROJECT_PATH" ]]; then
        log_error "Project path not found: $PROJECT_PATH"
        print -- "Create it first with mkproj."
        exit 1
    fi

    if [[ ! -d "$nas_volume" ]]; then
        log_error "NAS volume not mounted: $nas_volume"
        exit 1
    fi

    START_TIME=$SECONDS

    print -- "============================================="
    if $DRY_RUN; then
        print -- "=== Footage Ingest (DRY RUN) ==="
    else
        print -- "=== Footage Ingest ==="
    fi
    print -- "============================================="
    print -- "Source:        $SOURCE_PATH"
    print -- "Project:       $PROJECT_PATH"
    print -- "Local footage: $PROJECT_PATH/footage"
    print -- "NAS archive:   $archive_root"
    print -- "Camera:        $CAMERA_NAME"
    print -- ""

    collect_media_files "$SOURCE_PATH"
    MEDIA_COUNT=${#MEDIA_FILES[@]}

    if (( MEDIA_COUNT == 0 )); then
        print -- "No MP4/MOV files found."
        exit 0
    fi

    print -- "Found $MEDIA_COUNT media file(s)."
    print -- ""

    if ! $DRY_RUN; then
        mkdir -p "$PROJECT_PATH/footage" "$archive_root" || exit 1
        ensure_manifest "$manifest"
    fi

    local index=0
    for src_file in "${MEDIA_FILES[@]}"; do
        ((index++))

        local size_bytes=$(file_size "$src_file")
        if [[ -z "$size_bytes" ]]; then
            log_error "Cannot read file size: $src_file"
            ((ERROR_COUNT++))
            continue
        fi

        local size_human=$(format_size $size_bytes)
        local recording_datetime=$(get_recording_datetime "$src_file")
        local date_parts=($(get_date_parts "$recording_datetime"))
        local year="${date_parts[1]}"
        local month="${date_parts[2]}"
        local day="${date_parts[3]}"
        local original_name="${src_file:t}"
        local final_name=$(timestamped_filename "$recording_datetime" "$original_name")

        local resolved=$(resolve_unique_paths "$PROJECT_PATH" "$archive_root" "$year" "$month" "$day" "$final_name" $size_bytes)
        if [[ -z "$resolved" ]]; then
            log_error "Could not find available destination name for $src_file"
            ((ERROR_COUNT++))
            continue
        fi

        local fields=(${(ps:\t:)resolved})
        local local_rel="${fields[1]}"
        local archive_rel="${fields[2]}"
        local local_path="${fields[3]}"
        local archive_path="${fields[4]}"

        print -- "[$index/$MEDIA_COUNT] $original_name ($size_human)"
        print -- "      Recording: ${recording_datetime/_/ }"
        print -- "      Local:     .../$local_rel"
        print -- "      Archive:   .../$archive_rel"

        if $DRY_RUN; then
            local local_exists=false
            local archive_exists=false

            if file_matches_size "$local_path" $size_bytes; then
                print -- "      Local:   would skip existing"
                local_exists=true
            else
                print -- "      Local:   would copy"
            fi

            if file_matches_size "$archive_path" $size_bytes; then
                print -- "      Archive: would skip existing"
                archive_exists=true
            else
                print -- "      Archive: would copy"
            fi

            if $local_exists && $archive_exists; then
                ((SKIPPED_COUNT++))
            else
                $local_exists || ((LOCAL_COPY_COUNT++))
                $archive_exists || ((ARCHIVE_COPY_COUNT++))
            fi

            print -- ""
            continue
        fi

        if ! file_matches_size "$local_path" $size_bytes; then
            print -- "      Copying to local project..."
            if copy_file_safely "$src_file" "$local_path" "$local_rel"; then
                ((LOCAL_COPY_COUNT++))
            else
                ((ERROR_COUNT++))
                print -- ""
                continue
            fi
        else
            print -- "      Local already exists."
            ((SKIPPED_COUNT++))
        fi

        if ! file_matches_size "$archive_path" $size_bytes; then
            print -- "      Copying to NAS archive..."
            if copy_file_safely "$local_path" "$archive_path" "$archive_rel"; then
                ((ARCHIVE_COPY_COUNT++))
            else
                ((ERROR_COUNT++))
                print -- ""
                continue
            fi
        else
            print -- "      Archive already exists."
            ((SKIPPED_COUNT++))
        fi

        append_manifest_entry "$manifest" "$recording_datetime" "$size_bytes" "$original_name" "$local_rel" "$archive_rel" "$src_file"
        print -- ""
    done

    local elapsed=$((SECONDS - START_TIME))
    print -- "============================================="
    if $DRY_RUN; then
        print -- "=== Dry Run Complete ==="
    else
        print -- "=== Ingest Complete ==="
    fi
    print -- "Files scanned:      $MEDIA_COUNT"
    print -- "Local copies:       $LOCAL_COPY_COUNT"
    print -- "Archive copies:     $ARCHIVE_COPY_COUNT"
    print -- "Existing/skipped:   $SKIPPED_COUNT"
    print -- "Errors:             $ERROR_COUNT"
    print -- "Total time:         $(format_time $elapsed)"
    print -- "Manifest:           $manifest"
    print -- "============================================="

    (( ERROR_COUNT == 0 ))
}

main "$@"
