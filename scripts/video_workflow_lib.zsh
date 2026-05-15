#!/bin/zsh

# Shared helpers for the local-edit / NAS-archive video workflow.

CURRENT_TEMP_FILE=""
CURRENT_COPY_PID=""

log_error() {
    print -u2 -- "Error: $1"
}

expand_path() {
    local input_path="$1"
    case "$input_path" in
        "~") print -r -- "$HOME" ;;
        "~/"*) print -r -- "$HOME/${input_path#~/}" ;;
        *) print -r -- "$input_path" ;;
    esac
}

format_size() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        printf "%.1f GB" $(( bytes / 1073741824.0 ))
    elif (( bytes >= 1048576 )); then
        printf "%.1f MB" $(( bytes / 1048576.0 ))
    elif (( bytes >= 1024 )); then
        printf "%.1f KB" $(( bytes / 1024.0 ))
    else
        printf "%d bytes" $bytes
    fi
}

format_time() {
    local seconds=$1
    if (( seconds >= 3600 )); then
        printf "%dh %dm %ds" $((seconds / 3600)) $((seconds % 3600 / 60)) $((seconds % 60))
    elif (( seconds >= 60 )); then
        printf "%dm %ds" $((seconds / 60)) $((seconds % 60))
    else
        printf "%ds" $seconds
    fi
}

format_clock_time() {
    local seconds=$1
    (( seconds < 0 )) && seconds=0
    printf "%02d:%02d:%02d" $((seconds / 3600)) $((seconds % 3600 / 60)) $((seconds % 60))
}

cleanup_active_copy() {
    if [[ -n "$CURRENT_COPY_PID" ]]; then
        kill "$CURRENT_COPY_PID" 2>/dev/null
        wait "$CURRENT_COPY_PID" 2>/dev/null
        CURRENT_COPY_PID=""
    fi

    if [[ -n "$CURRENT_TEMP_FILE" && -f "$CURRENT_TEMP_FILE" ]]; then
        print -- ""
        print -- "Interrupted! Cleaning up partial file..."
        rm -f "$CURRENT_TEMP_FILE"
        print -- "Cleaned up: ${CURRENT_TEMP_FILE:t}"
        CURRENT_TEMP_FILE=""
    fi
}

file_size() {
    stat -f "%z" "$1" 2>/dev/null
}

file_matches_size() {
    local file_path="$1"
    local expected_size=$2

    [[ -f "$file_path" ]] || return 1
    [[ "$(file_size "$file_path")" == "$expected_size" ]]
}

get_recording_datetime() {
    local media_file="$1"
    local basename="${media_file:t:r}"
    local dir="${media_file:h}"
    local xml_file="$dir/${basename}M01.XML"
    local creation_date=""

    if [[ -f "$xml_file" ]]; then
        local xml_date=$(grep -o '<CreationDate value="[^"]*"' "$xml_file" 2>/dev/null | sed 's/<CreationDate value="//;s/"//')

        if [[ -n "$xml_date" ]]; then
            local date_part="${xml_date%%T*}"
            local time_full="${xml_date#*T}"
            local time_part="${time_full%%[-+]*}"
            time_part="${time_part//:/-}"
            creation_date="${date_part}_${time_part}"
        fi
    fi

    if [[ -z "$creation_date" ]]; then
        creation_date=$(stat -f "%Sm" -t "%Y-%m-%d_%H-%M-%S" "$media_file" 2>/dev/null)
    fi

    if [[ -z "$creation_date" ]]; then
        creation_date=$(date "+%Y-%m-%d_%H-%M-%S")
    fi

    print -r -- "$creation_date"
}

get_date_parts() {
    local datetime="$1"
    local date_part="${datetime%%_*}"
    local year="${date_part%%-*}"
    local rest="${date_part#*-}"
    local month="${rest%%-*}"
    local day="${rest#*-}"
    print -r -- "$year $month $day"
}

timestamped_filename() {
    local datetime="$1"
    local filename="$2"

    if [[ "$filename" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}_' ]]; then
        print -r -- "$filename"
    else
        print -r -- "${datetime}_${filename}"
    fi
}

print_copy_progress() {
    local temp_file="$1"
    local total_bytes=$2
    local copy_start=$3
    local finish_line="$4"
    local copied_bytes=0

    if [[ -f "$temp_file" ]]; then
        copied_bytes=$(file_size "$temp_file")
        [[ -z "$copied_bytes" ]] && copied_bytes=0
    fi

    (( copied_bytes > total_bytes )) && copied_bytes=$total_bytes

    local elapsed=$((SECONDS - copy_start))
    local speed_elapsed=$elapsed
    (( speed_elapsed <= 0 )) && speed_elapsed=1

    local percent=100
    if (( total_bytes > 0 )); then
        percent=$((copied_bytes * 100 / total_bytes))
    fi

    local speed_mbps=$((copied_bytes / speed_elapsed / 1000000.0))
    local eta=0
    if (( copied_bytes > 0 && copied_bytes < total_bytes )); then
        eta=$(((total_bytes - copied_bytes) * speed_elapsed / copied_bytes))
    fi

    local eta_fmt=$(format_clock_time $eta)
    local elapsed_fmt=$(format_clock_time $elapsed)

    printf "\r%14d %3d%% %8.2fMB/s ETA %s elapsed %s" \
        $copied_bytes $percent $speed_mbps $eta_fmt $elapsed_fmt

    if [[ "$finish_line" == "true" ]]; then
        printf "\n"
    fi
}

copy_file_with_progress() {
    local src_file="$1"
    local temp_file="$2"
    local total_bytes=$3
    local label="${4:-${src_file:t}}"
    local copy_start=$SECONDS

    print -- "$label"

    dd if="$src_file" of="$temp_file" bs=16m status=none &
    local copy_pid=$!
    CURRENT_COPY_PID="$copy_pid"

    while kill -0 "$copy_pid" 2>/dev/null; do
        print_copy_progress "$temp_file" $total_bytes $copy_start false
        sleep 1
    done

    wait "$copy_pid"
    local copy_status=$?
    CURRENT_COPY_PID=""

    print_copy_progress "$temp_file" $total_bytes $copy_start true

    if (( copy_status != 0 )); then
        return 1
    fi

    local copied_size=$(file_size "$temp_file")
    if [[ "$copied_size" != "$total_bytes" ]]; then
        log_error "Copied size mismatch for $label: expected $total_bytes bytes, got ${copied_size:-0} bytes"
        return 1
    fi

    touch -r "$src_file" "$temp_file" 2>/dev/null || true
    return 0
}

copy_file_safely() {
    local src_file="$1"
    local dest_file="$2"
    local label="${3:-${dest_file:t}}"
    local total_bytes=$(file_size "$src_file")

    if [[ -z "$total_bytes" ]]; then
        log_error "Cannot read source size: $src_file"
        return 1
    fi

    if file_matches_size "$dest_file" $total_bytes; then
        print -- "      Skipped existing: $label"
        return 0
    fi

    if [[ -e "$dest_file" ]]; then
        log_error "Destination exists with a different size: $dest_file"
        return 1
    fi

    mkdir -p "${dest_file:h}" || return 1

    local temp_file="${dest_file}.tmp"
    CURRENT_TEMP_FILE="$temp_file"
    rm -f "$temp_file"

    if copy_file_with_progress "$src_file" "$temp_file" $total_bytes "$label"; then
        if ! mv "$temp_file" "$dest_file"; then
            rm -f "$temp_file" 2>/dev/null
            CURRENT_TEMP_FILE=""
            return 1
        fi
        CURRENT_TEMP_FILE=""
        return 0
    fi

    rm -f "$temp_file" 2>/dev/null
    CURRENT_TEMP_FILE=""
    return 1
}
