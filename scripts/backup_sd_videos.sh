#!/bin/zsh

# =============================================================================
# SD Card Video Backup Script
# Backs up MP4 files from Sony camera SD card to network drive
# =============================================================================

# === CONFIGURATION ===
DEST_VOLUME_NAME="plusEvMediaBackup"    # Network drive volume name

# Source paths (Sony camera SD card structure)
SD_VOLUME_NAME="Untitled"
SD_CLIP_SUBPATH="Private/M4ROOT/CLIP"

# Destination subfolder structure
DEST_SUBPATH="CameraBackup"
CAMERA_FOLDER="zve1"

# === DERIVED PATHS (don't edit) ===
SD_VOLUME="/Volumes/$SD_VOLUME_NAME"
SD_CLIP_PATH="$SD_VOLUME/$SD_CLIP_SUBPATH"
DEST_VOLUME="/Volumes/$DEST_VOLUME_NAME"
DEST_ROOT="$DEST_VOLUME/$DEST_SUBPATH"

# === GLOBALS ===
SCRIPT_NAME="${0:t}"
DRY_RUN=false
CUSTOM_SOURCE_PATH=""
COPIED_COUNT=0
SKIPPED_COUNT=0
ERROR_COUNT=0
TOTAL_BYTES_COPIED=0
START_TIME=0
CURRENT_TEMP_FILE=""
declare -a DIRS_TO_CREATE

# =============================================================================
# Cleanup & Signal Handling
# =============================================================================

cleanup() {
    if [[ -n "$CURRENT_TEMP_FILE" && -f "$CURRENT_TEMP_FILE" ]]; then
        echo ""
        echo "Interrupted! Cleaning up partial file..."
        rm -f "$CURRENT_TEMP_FILE"
        echo "Cleaned up: ${CURRENT_TEMP_FILE:t}"
    fi
    echo ""
    echo "Backup cancelled."
    exit 130
}

trap cleanup SIGINT SIGTERM

# =============================================================================
# Functions
# =============================================================================

show_help() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] [SOURCE_PATH]

Back up MP4 video files to network drive.
Files are organized by recording date into YYYY/MM/DD/zve1/ folders.
Filenames are prefixed with the recording timestamp.

Arguments:
  SOURCE_PATH        Optional path to search for MP4 files (recursive)
                     If not provided, uses SD card at $SD_CLIP_PATH

Options:
  -n, --dry-run    Show what would be copied without making changes
  -h, --help       Show this help message

Examples:
  $SCRIPT_NAME                     # Backup from SD card
  $SCRIPT_NAME --dry-run           # Preview SD card backup
  $SCRIPT_NAME /path/to/videos     # Backup from custom path
  $SCRIPT_NAME -n /path/to/videos  # Preview custom path backup

Configuration (edit at top of script):
  DEST_VOLUME_NAME    Network drive volume name (current: $DEST_VOLUME_NAME)
  SD_VOLUME_NAME      SD card volume name (current: $SD_VOLUME_NAME)
  CAMERA_FOLDER       Camera subfolder name (current: $CAMERA_FOLDER)

Destination: $DEST_ROOT/<YYYY>/<MM>/<DD>/$CAMERA_FOLDER/
EOF
}

log_error() {
    echo "Error: $1" >&2
}

log_info() {
    echo "$1"
}

# Format bytes to human readable
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

# Format seconds to human readable time
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

# Extract creation date from XML sidecar file
# Returns date in format: YYYY-MM-DD_HH-MM-SS
# Falls back to file modification date if XML not found/parseable
get_creation_date() {
    local mp4_file="$1"
    local basename="${mp4_file:t:r}"  # Get filename without extension
    local dir="${mp4_file:h}"          # Get directory
    local xml_file="$dir/${basename}M01.XML"
    
    local creation_date=""
    
    # Try to extract from XML sidecar
    if [[ -f "$xml_file" ]]; then
        # Extract CreationDate value from XML
        # Format: <CreationDate value="2026-01-02T01:23:50-08:00"/>
        local xml_date=$(grep -o '<CreationDate value="[^"]*"' "$xml_file" 2>/dev/null | \
                         sed 's/<CreationDate value="//;s/"//')
        
        if [[ -n "$xml_date" ]]; then
            # Parse: 2026-01-02T01:23:50-08:00 -> 2026-01-02_01-23-50
            local date_part="${xml_date%%T*}"
            local time_full="${xml_date#*T}"
            local time_part="${time_full%%[-+]*}"
            # Replace : with - in time
            time_part="${time_part//:/-}"
            creation_date="${date_part}_${time_part}"
        fi
    fi
    
    # Fallback to file modification date
    if [[ -z "$creation_date" ]]; then
        creation_date=$(stat -f "%Sm" -t "%Y-%m-%d_%H-%M-%S" "$mp4_file" 2>/dev/null)
    fi
    
    echo "$creation_date"
}

# Extract just the date portion for folder structure
# Input: 2026-01-02_01-23-50
# Output: 2026 01 02 (space separated for easy parsing)
get_date_parts() {
    local datetime="$1"
    local date_part="${datetime%%_*}"
    local year="${date_part%%-*}"
    local rest="${date_part#*-}"
    local month="${rest%%-*}"
    local day="${rest#*-}"
    echo "$year $month $day"
}

# Generate unique filename if destination already exists
get_unique_dest_path() {
    local dest_path="$1"
    
    if [[ ! -e "$dest_path" ]]; then
        echo "$dest_path"
        return
    fi
    
    local dir="${dest_path:h}"
    local filename="${dest_path:t:r}"
    local ext="${dest_path:t:e}"
    
    local counter=1
    local new_path
    while true; do
        new_path="$dir/${filename}_${counter}.${ext}"
        if [[ ! -e "$new_path" ]]; then
            echo "$new_path"
            return
        fi
        ((counter++))
        
        # Safety limit
        if (( counter > 1000 )); then
            log_error "Could not find unique filename after 1000 attempts: $dest_path"
            echo ""
            return
        fi
    done
}

# Check if source and destination files are identical (by size)
files_are_identical() {
    local src="$1"
    local dest="$2"
    
    [[ -f "$dest" ]] || return 1
    
    local src_size=$(stat -f "%z" "$src" 2>/dev/null)
    local dest_size=$(stat -f "%z" "$dest" 2>/dev/null)
    
    [[ "$src_size" == "$dest_size" ]]
}

# =============================================================================
# Validation
# =============================================================================

validate_environment() {
    # If custom source path provided, just check it exists
    if [[ -n "$CUSTOM_SOURCE_PATH" ]]; then
        if [[ ! -d "$CUSTOM_SOURCE_PATH" ]]; then
            log_error "Source path not found: $CUSTOM_SOURCE_PATH"
            return 1
        fi
    else
        # Check SD card volume
        if [[ ! -d "$SD_VOLUME" ]]; then
            log_error "SD card not found at $SD_VOLUME"
            echo "Please insert the SD card and try again."
            return 1
        fi
        
        # Check SD card has expected Sony structure
        if [[ ! -d "$SD_CLIP_PATH" ]]; then
            log_error "SD card structure not found."
            echo "Expected: $SD_CLIP_PATH"
            echo "Is this a Sony camera SD card?"
            return 1
        fi
    fi
    
    # Check network drive
    if [[ ! -d "$DEST_VOLUME" ]]; then
        log_error "Network drive not found at $DEST_VOLUME"
        echo "Please mount the network drive and try again."
        return 1
    fi
    
    return 0
}

# =============================================================================
# Main backup logic
# =============================================================================

process_files() {
    local source_path
    local mp4_files=()
    
    if [[ -n "$CUSTOM_SOURCE_PATH" ]]; then
        source_path="$CUSTOM_SOURCE_PATH"
        # Recursive search for MP4 files in custom path
        while IFS= read -r -d '' f; do
            # Skip macOS resource fork files
            [[ "${f:t}" == ._* ]] && continue
            mp4_files+=("$f")
        done < <(find "$source_path" -type f \( -iname "*.mp4" -o -iname "*.MP4" \) -print0 2>/dev/null)
    else
        source_path="$SD_CLIP_PATH"
        # Non-recursive search in SD card clip folder
        for f in "$SD_CLIP_PATH"/*.MP4(N) "$SD_CLIP_PATH"/*.mp4(N); do
            [[ -f "$f" ]] || continue
            # Skip macOS resource fork files
            [[ "${f:t}" == ._* ]] && continue
            mp4_files+=("$f")
        done
    fi
    
    local total=${#mp4_files[@]}
    
    if (( total == 0 )); then
        log_info "No MP4 files found in $source_path"
        log_info "Nothing to back up."
        return 0
    fi
    
    log_info "Found $total MP4 file(s) to process..."
    echo ""
    
    local index=0
    for src_file in "${mp4_files[@]}"; do
        ((index++))
        
        local filename="${src_file:t}"
        local filesize=$(stat -f "%z" "$src_file" 2>/dev/null)
        local filesize_human=$(format_size $filesize)
        
        # Get creation date from XML or fallback
        local creation_datetime=$(get_creation_date "$src_file")
        local date_parts=($(get_date_parts "$creation_datetime"))
        local year="${date_parts[1]}"
        local month="${date_parts[2]}"
        local day="${date_parts[3]}"
        
        # Format display datetime (replace _ with space, - with : in time)
        local display_date="${creation_datetime%%_*}"
        local display_time="${creation_datetime#*_}"
        display_time="${display_time//-/:}"
        
        # Build destination path
        local dest_dir="$DEST_ROOT/$year/$month/$day/$CAMERA_FOLDER"
        local new_filename="${creation_datetime}_${filename:r}.${filename:e}"
        local dest_file="$dest_dir/$new_filename"
        
        # Display file info
        log_info "[$index/$total] $filename ($filesize_human)"
        log_info "      Recording: $display_date $display_time"
        log_info "      → .../$year/$month/$day/$CAMERA_FOLDER/$new_filename"
        
        # Check if destination exists and is identical
        if files_are_identical "$src_file" "$dest_file"; then
            if $DRY_RUN; then
                log_info "      Status: Would skip (already exists)"
            else
                log_info "      Skipped (already exists)"
            fi
            ((SKIPPED_COUNT++))
            echo ""
            continue
        fi
        
        # If file exists but is different, get unique name
        if [[ -e "$dest_file" ]]; then
            dest_file=$(get_unique_dest_path "$dest_file")
            if [[ -z "$dest_file" ]]; then
                ((ERROR_COUNT++))
                echo ""
                continue
            fi
            local new_name="${dest_file:t}"
            log_info "      (renamed to $new_name - file with same name exists)"
        fi
        
        # Track directories to create
        if [[ ! -d "$dest_dir" ]]; then
            if [[ ! " ${DIRS_TO_CREATE[*]} " =~ " $dest_dir " ]]; then
                DIRS_TO_CREATE+=("$dest_dir")
            fi
        fi
        
        if $DRY_RUN; then
            log_info "      Status: Would copy (new file)"
            ((COPIED_COUNT++))
        else
            # Create destination directory
            if [[ ! -d "$dest_dir" ]]; then
                if ! mkdir -p "$dest_dir"; then
                    log_error "Failed to create directory: $dest_dir"
                    ((ERROR_COUNT++))
                    echo ""
                    continue
                fi
            fi
            
            # Copy file with rsync (showing progress)
            # Use temp file to avoid partial files if cancelled
            local temp_file="${dest_file}.tmp"
            CURRENT_TEMP_FILE="$temp_file"
            
            log_info "      Copying ($filesize_human)..."
            local copy_start=$SECONDS
            if rsync -ah --progress "$src_file" "$temp_file"; then
                # Rename temp file to final destination
                if mv "$temp_file" "$dest_file"; then
                    CURRENT_TEMP_FILE=""
                    local elapsed=$((SECONDS - copy_start))
                    local elapsed_fmt=$(format_time $elapsed)
                    log_info "      Done in $elapsed_fmt"
                    ((COPIED_COUNT++))
                    ((TOTAL_BYTES_COPIED += filesize))
                else
                    echo "      FAILED (couldn't rename temp file)"
                    rm -f "$temp_file" 2>/dev/null
                    CURRENT_TEMP_FILE=""
                    ((ERROR_COUNT++))
                fi
            else
                echo "      FAILED"
                log_error "Failed to copy $filename"
                # Clean up partial temp file
                rm -f "$temp_file" 2>/dev/null
                CURRENT_TEMP_FILE=""
                ((ERROR_COUNT++))
            fi
        fi
        
        echo ""
    done
}

print_summary() {
    echo "============================================="
    
    if $DRY_RUN; then
        echo "=== DRY RUN Summary ==="
        echo "Would copy: $COPIED_COUNT file(s)"
        echo "Would skip: $SKIPPED_COUNT file(s) (already exist)"
        
        if (( ${#DIRS_TO_CREATE[@]} > 0 )); then
            echo ""
            echo "Directories to create:"
            for dir in "${DIRS_TO_CREATE[@]}"; do
                echo "  - .../${dir#$DEST_ROOT/}"
            done
        fi
        
        echo ""
        echo "Run without --dry-run to execute backup."
    else
        local total_time=$((SECONDS - START_TIME))
        local total_time_fmt=$(format_time $total_time)
        local total_size_fmt=$(format_size $TOTAL_BYTES_COPIED)
        
        echo "=== Backup Complete ==="
        echo "Copied: $COPIED_COUNT file(s) ($total_size_fmt)"
        echo "Skipped: $SKIPPED_COUNT file(s) (already exist)"
        echo "Total time: $total_time_fmt"
        
        if (( ERROR_COUNT > 0 )); then
            echo "Errors: $ERROR_COUNT file(s)"
        fi
    fi
    
    echo "============================================="
}

# =============================================================================
# Main
# =============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                echo "Use --help for usage information."
                exit 1
                ;;
            *)
                # Treat as source path
                CUSTOM_SOURCE_PATH="$1"
                shift
                ;;
        esac
    done
    
    # Start timer
    START_TIME=$SECONDS
    
    # Determine source path for display
    local display_source
    if [[ -n "$CUSTOM_SOURCE_PATH" ]]; then
        display_source="$CUSTOM_SOURCE_PATH (recursive)"
    else
        display_source="$SD_CLIP_PATH"
    fi
    
    # Print header
    echo "============================================="
    if $DRY_RUN; then
        echo "=== Video Backup (DRY RUN) ==="
    else
        echo "=== Video Backup ==="
    fi
    echo "============================================="
    echo "Source:      $display_source"
    echo "Destination: $DEST_ROOT"
    echo ""
    
    # Validate environment
    if ! validate_environment; then
        exit 1
    fi
    
    # Process files
    process_files
    
    # Print summary
    print_summary
    
    # Exit with error if any copies failed
    if (( ERROR_COUNT > 0 )); then
        exit 1
    fi
    
    exit 0
}

main "$@"
