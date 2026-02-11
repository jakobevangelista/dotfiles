# Scripts Directory

This directory contains utility scripts for various tasks.

## backup_sd_videos.sh

A robust backup script for copying MP4 video files from Sony camera SD cards or any custom directory to a network drive, organizing them by recording date.

### Features

- **Automatic Date Organization**: Files are organized into `YYYY/MM/DD/zve1/` folder structure based on recording date
- **Timestamp Extraction**: Extracts accurate recording timestamps from Sony XML sidecar files
- **Unique Filenames**: Prefixes each file with its recording timestamp (e.g., `2025-12-18_00-48-30_C0293.MP4`)
- **Smart Duplicate Detection**: Skips files that already exist at the destination (compares by size)
- **Recursive Search**: Can search subdirectories when given a custom path
- **Dry Run Mode**: Preview what would be copied without making any changes
- **Progress Tracking**: Shows real-time copy progress and elapsed time for each file
- **Interrupt Safety**: Safely handles Ctrl+C by cleaning up partial temp files
- **Conflict Resolution**: Appends `_1`, `_2`, etc. if different files have the same name

### Quick Start

```bash
# Backup from SD card (default)
backupSdCard

# Preview what would happen
backupSdCard --dry-run

# Backup from a custom directory (recursive search)
backupSdCard /path/to/videos

# Preview custom directory backup
backupSdCard -n /path/to/videos
```

### Usage

```
backup_sd_videos.sh [OPTIONS] [SOURCE_PATH]
```

**Arguments:**
- `SOURCE_PATH` - Optional path to search for MP4 files recursively. If not provided, uses SD card at `/Volumes/Untitled/Private/M4ROOT/CLIP`

**Options:**
- `-n, --dry-run` - Show what would be copied without making changes
- `-h, --help` - Show help message

### Configuration

Edit these variables at the top of the script:

```zsh
DEST_VOLUME_NAME="plusEvMediaBackup"    # Network drive volume name
SD_VOLUME_NAME="Untitled"               # SD card volume name
SD_CLIP_SUBPATH="Private/M4ROOT/CLIP"   # Sony camera clip path
CAMERA_FOLDER="zve1"                    # Camera subfolder name
```

### How It Works

#### 1. Source Detection
- **SD Card Mode** (default): Validates that `/Volumes/Untitled/Private/M4ROOT/CLIP` exists
- **Custom Path Mode**: Validates that the provided path exists, then recursively searches for all `.MP4` files

#### 2. Metadata Extraction
For each MP4 file, the script:
1. Looks for a matching XML sidecar file (e.g., `C0299.MP4` → `C0299M01.XML`)
2. Extracts the `<CreationDate>` timestamp from the XML (actual recording start time from camera)
3. Falls back to file modification date if XML is missing or unparseable

Example XML extraction:
```xml
<CreationDate value="2026-01-02T01:23:50-08:00"/>
```
Becomes: `2026-01-02_01-23-50`

#### 3. Destination Path Building
Files are organized by recording date:
```
/Volumes/plusEvMediaBackup/CameraBackup/
  └── 2026/
      └── 01/
          └── 02/
              └── zve1/
                  └── 2026-01-02_01-23-50_C0299.MP4
```

#### 4. Safe Copying
- Uses temporary `.tmp` files during transfer to prevent partial files if interrupted
- After successful copy, renames `.tmp` to final filename
- If interrupted (Ctrl+C), automatically cleans up any partial `.tmp` files
- Skips files that already exist with identical size

#### 5. Duplicate Handling
If a file with the same name but different size exists:
- Appends `_1`, `_2`, etc. to make filename unique
- Example: `2026-01-02_01-23-50_C0299_1.MP4`

### Examples

#### Example 1: Regular SD Card Backup
```bash
$ backupSdCard
=============================================
=== Video Backup ===
=============================================
Source:      /Volumes/Untitled/Private/M4ROOT/CLIP
Destination: /Volumes/plusEvMediaBackup/CameraBackup

Found 8 MP4 file(s) to process...

[1/8] C0293.MP4 (5.6 GB)
      Recording: 2025-12-18 00:48:30
      → .../2025/12/18/zve1/2025-12-18_00-48-30_C0293.MP4
      Copying (5.6 GB)...
      Done in 1m 23s

...

=============================================
=== Backup Complete ===
Copied: 7 file(s) (89.2 GB)
Skipped: 1 file(s) (already exist)
Total time: 15m 23s
=============================================
```

#### Example 2: Dry Run with Custom Path
```bash
$ backupSdCard --dry-run /Volumes/backup/unstructured_videos
=============================================
=== Video Backup (DRY RUN) ===
=============================================
Source:      /Volumes/backup/unstructured_videos (recursive)
Destination: /Volumes/plusEvMediaBackup/CameraBackup

Found 609 MP4 file(s) to process...

[1/609] C0001.MP4 (168.0 MB)
      Recording: 2025-01-11 08:13:24
      → .../2025/01/11/zve1/2025-01-11_08-13-24_C0001.MP4
      Status: Would copy (new file)

...

=============================================
=== DRY RUN Summary ===
Would copy: 609 file(s)
Would skip: 0 file(s) (already exist)

Directories to create:
  - .../2025/01/11/zve1
  - .../2025/01/13/zve1
  - .../2025/01/14/zve1
  ...

Run without --dry-run to execute backup.
=============================================
```

#### Example 3: Interrupted Backup
```bash
$ backupSdCard
[Copying file 3/8...]
^C
Interrupted! Cleaning up partial file...
Cleaned up: 2026-01-02_01-23-50_C0295.MP4.tmp

Backup cancelled.
```

### File Naming Format

Files are renamed with this format:
```
<YYYY-MM-DD>_<HH-MM-SS>_<original_name>.MP4
```

Example transformations:
- `C0299.MP4` → `2026-01-02_01-23-50_C0299.MP4`
- `C0300.MP4` → `2026-01-03_00-27-36_C0300.MP4`

This ensures:
1. Files sort chronologically by recording date
2. Original clip number is preserved for reference
3. Each file has a globally unique name

### Troubleshooting

**Problem**: `Error: SD card not found`
- **Solution**: Insert the SD card and ensure it mounts at `/Volumes/Untitled`

**Problem**: `Error: SD card structure not found`
- **Solution**: Make sure this is a Sony camera SD card with the expected folder structure, or use a custom source path

**Problem**: `Error: Network drive not found`
- **Solution**: Mount your network drive. Update `DEST_VOLUME_NAME` at the top of the script if your volume has a different name

**Problem**: Files copied but with wrong dates
- **Solution**: The XML sidecar files may be missing. The script falls back to file modification dates. Check if `*M01.XML` files exist alongside your MP4 files

**Problem**: Script fails with old rsync
- **Solution**: The script uses `rsync --progress` which works with macOS's built-in rsync (v2.6.9)

### Alias Setup

The script is aliased in `.zshrc` as:
```zsh
alias backupSdCard="~/dotfiles/scripts/backup_sd_videos.sh"
```

After modifying `.zshrc`, reload with:
```bash
source ~/.zshrc
```

### Technical Details

- **Language**: Zsh shell script
- **Dependencies**: rsync (built-in on macOS), standard Unix utilities
- **Exit Codes**:
  - `0` - Success
  - `1` - Validation or copy error
  - `130` - Interrupted (SIGINT/SIGTERM)
- **File Detection**: Uses `find` with `-print0` for null-separated paths (handles spaces/special characters)
- **Metadata Parsing**: Uses `grep` and `sed` to extract XML values
- **Progress**: Uses rsync's `--progress` flag for per-file transfer status
