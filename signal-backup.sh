#!/bin/bash
#
# signal-backup.sh - Safely back up and export Signal Desktop conversations.
#
# This script performs:
#   1. A raw database backup (config.json and db.sqlite) inside a compressed tarball.
#   2. An incremental sync of all attachments (via rsync to save space and time).
#   3. A decrypted export of all chats into HTML, Markdown, and JSON formats
#      using the 'sigexport' tool, supporting safe updates/merges.

set -e

# --- Default Paths and Variables ---
DEST_DIR="$HOME/backups/signal"
SOURCE_DIR=""
BACKUP_RAW=true
BACKUP_EXPORT=true
BACKUP_ATTACHMENTS=true
INTERACTIVE=true

# Disable interactive mode if stdin is not a terminal
if [ ! -t 0 ]; then
    INTERACTIVE=false
fi

# --- Helper Functions ---
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Safely back up and export Signal Desktop conversations and attachments.

Options:
  -d, --dest DIR         Destination folder for backups (default: ~/backups/signal)
  -s, --source DIR       Signal configuration folder (default: auto-detected)
  --no-raw               Skip raw SQLite database and config backup
  --no-export            Skip human-readable export (HTML/Markdown/JSON)
  --no-attachments       Skip copying and exporting attachments (saves significant space)
  -y, --yes              Non-interactive mode (automatically close Signal if running)
  -h, --help             Show this help message

Description:
  This script creates a raw backup of the Signal SQLite database and config
  into a compressed archive (raw/archives/) and syncs attachments incrementally
  (raw/attachments/). It also exports chats into human-readable HTML, Markdown,
  and JSON formats (export/) using 'sigexport'.
EOF
}

detect_signal_source() {
    local paths=(
        "$HOME/.config/Signal"
        "$HOME/.var/app/org.signal.Signal/config/Signal"
        "$HOME/snap/signal-desktop/current/.config/Signal"
        "$HOME/snap/signal-desktop/common/.config/Signal"
    )
    for p in "${paths[@]}"; do
        if [ -d "$p" ] && [ -f "$p/config.json" ] && [ -d "$p/sql" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

check_signal_running() {
    pgrep -x "signal-desktop" > /dev/null
}

close_signal() {
    echo "Sending termination signal to Signal Desktop..."
    pkill -x "signal-desktop" || true
    
    # Wait up to 10 seconds for Signal to exit cleanly
    for i in {1..10}; do
        if ! check_signal_running; then
            echo "Signal Desktop closed successfully."
            return 0
        fi
        sleep 1
    done
    
    echo "Warning: Signal Desktop did not close within 10 seconds."
    return 1
}

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dest)
            DEST_DIR="$2"
            shift 2
            ;;
        -s|--source)
            SOURCE_DIR="$2"
            shift 2
            ;;
        --no-raw)
            BACKUP_RAW=false
            shift
            ;;
        --no-export)
            BACKUP_EXPORT=false
            shift
            ;;
        --no-attachments)
            BACKUP_ATTACHMENTS=false
            shift
            ;;
        -y|--yes)
            INTERACTIVE=false
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown option '$1'"
            show_help
            exit 1
            ;;
    esac
done

# --- 1. Detect Source Directory ---
if [ -z "$SOURCE_DIR" ]; then
    if ! SOURCE_DIR=$(detect_signal_source); then
        echo "Error: Could not auto-detect Signal configuration directory."
        echo "Please specify it manually using -s/--source option."
        exit 1
    fi
fi

echo "Signal Source Directory: $SOURCE_DIR"
echo "Backup Destination:      $DEST_DIR"
echo "Raw DB Backup:           $BACKUP_RAW"
echo "Attachments Backup:      $BACKUP_ATTACHMENTS"
echo "Human-readable Export:   $BACKUP_EXPORT"
echo "------------------------------------------------"

# --- 2. Check Signal Running State ---
if check_signal_running; then
    if [ "$INTERACTIVE" = "true" ]; then
        echo "Signal Desktop is currently running."
        read -p "Would you like to close Signal Desktop to perform a safe backup? (y/N): " response
        case "$response" in
            [yY][eE][sS]|[yY])
                if ! close_signal; then
                    read -p "Signal failed to close cleanly. Force close it? (y/N): " force_response
                    case "$force_response" in
                        [yY][eE][sS]|[yY])
                            echo "Force closing Signal Desktop..."
                            pkill -9 -x "signal-desktop" || true
                            sleep 1
                            ;;
                        *)
                            echo "Aborting backup to prevent database corruption."
                            exit 1
                            ;;
                    esac
                fi
                ;;
            *)
                echo "Aborting backup. Please close Signal Desktop and try again."
                exit 1
                ;;
        esac
    else
        echo "Non-interactive mode: Attempting to close Signal Desktop..."
        if ! close_signal; then
            echo "Force closing Signal Desktop..."
            pkill -9 -x "signal-desktop" || true
            sleep 1
        fi
    fi
fi

# Ensure Signal is indeed closed before proceeding
if check_signal_running; then
    echo "Error: Signal Desktop is still running. Aborting backup."
    exit 1
fi

# --- 3. Run Raw Backup ---
if [ "$BACKUP_RAW" = "true" ]; then
    echo -e "\n=== Running Raw Backup ==="
    
    # Create target directories
    mkdir -p "$DEST_DIR/raw/archives"
    
    # Back up config.json and db.sqlite in a compressed tarball
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    DB_ARCHIVE="$DEST_DIR/raw/archives/signal-db-backup-${TIMESTAMP}.tar.gz"
    
    echo "Archiving Database and Config..."
    tar -czf "$DB_ARCHIVE" -C "$SOURCE_DIR" config.json sql/db.sqlite
    echo "Raw DB backup saved to: $DB_ARCHIVE"
    
    # Sync attachments if enabled
    if [ "$BACKUP_ATTACHMENTS" = "true" ]; then
        if [ -d "$SOURCE_DIR/attachments.noindex" ]; then
            echo "Syncing attachments incrementally..."
            mkdir -p "$DEST_DIR/raw/attachments"
            rsync -a --info=progress2 "$SOURCE_DIR/attachments.noindex/" "$DEST_DIR/raw/attachments/"
            echo "Attachments successfully synced."
        else
            echo "Warning: attachments.noindex directory not found in source."
        fi
    fi
fi

# --- 4. Run Human-Readable Export ---
if [ "$BACKUP_EXPORT" = "true" ]; then
    echo -e "\n=== Running Decrypted Chat Export ==="
    
    # Check if sigexport is installed
    if ! command -v sigexport > /dev/null; then
        # Try local path
        if [ -x "$HOME/.local/bin/sigexport" ]; then
            export PATH="$HOME/.local/bin:$PATH"
        else
            echo "Error: 'sigexport' command not found. Installing via pipx..."
            if command -v pipx > /dev/null; then
                pipx install signal-export
                export PATH="$HOME/.local/bin:$PATH"
            else
                echo "Error: pipx is not installed. Please install 'signal-export' manually."
                exit 1
            fi
        fi
    fi

    # Set up export arguments
    SIGEXPORT_ARGS=(--source "$SOURCE_DIR")
    if [ "$BACKUP_ATTACHMENTS" = "false" ]; then
        SIGEXPORT_ARGS+=(--no-attachments)
    else
        SIGEXPORT_ARGS+=(--attachments)
    fi

    EXPORT_DIR="$DEST_DIR/export"
    EXPORT_NEW_DIR="$DEST_DIR/export-new"
    
    mkdir -p "$DEST_DIR"
    
    if [ -d "$EXPORT_DIR" ]; then
        echo "Existing export found. Merging chats with previous export..."
        SIGEXPORT_ARGS+=(--old "$EXPORT_DIR")
        
        if sigexport "${SIGEXPORT_ARGS[@]}" "$EXPORT_NEW_DIR"; then
            echo "Export merge completed successfully."
            # Swap new export in place of old export
            rm -rf "$EXPORT_DIR.old"
            mv "$EXPORT_DIR" "$EXPORT_DIR.old"
            mv "$EXPORT_NEW_DIR" "$EXPORT_DIR"
            rm -rf "$EXPORT_DIR.old"
        else
            echo "Error: Chat export merge failed. Old export left unmodified."
            rm -rf "$EXPORT_NEW_DIR"
            exit 1
        fi
    else
        echo "No previous export found. Generating new chat export..."
        if sigexport "${SIGEXPORT_ARGS[@]}" "$EXPORT_DIR"; then
            echo "Export completed successfully."
        else
            echo "Error: Chat export failed."
            exit 1
        fi
    fi
    echo "Human-readable chats saved to: $EXPORT_DIR"
fi

echo -e "\n================================================"
echo "Backup and Export process completed successfully!"
echo "================================================"
