#!/usr/bin/env bash

####  CONFIGURATION  ####

HDD_BACKUP_TMP_DIR="" # temporary directory to mount filesystem
HDD_BACKUP_SOURCE_PATH=/media/storage/
HDD_BACKUP_HDD_UUID=$1
HDD_BACKUP_EXCLUDE_DIRS=(
    "snapraid.content"
    "lost+found"
    "Downloads"
    "Import"
    "Tvshows"
    "Audio"
    "Music"
    "Games"
)

function usage()
{
    echo "Usage: $(basename "$0") [-h|--help] [-y|--yes] <HDD_UUID>"
    echo
    echo "Options:"
    echo "  -h, --help         Show this help message and exit"
    echo "  -y, --yes          Answer yes to all prompts"
    echo
    echo "Arguments:"
    echo "  HDD_UUID           The UUID of the encrypted external hard drive"
    echo
    echo "Description:"
    echo "  This script backs up files from a source directory to an encrypted external hard drive."
    echo "  The HDD_UUID argument is required and should be the UUID of the external hard drive."
    echo
}


####  COMMON CODE  ####

LOG_FILE=""
EMAIL_USERNAME=""
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Function to exit the script with an error message.
function error_exit()
{
    echo "ERROR: ${1:-"Unknown Error"}"
    log "ERROR: ${1:-"Unknown Error"}"

    if [ "${EMAIL_USERNAME}" != "" ]; then

msmtp -t <<EOF
To: ${EMAIL_USERNAME}
From: ${EMAIL_USERNAME}
Subject: $(hostname): Script $0 has encountered an error - ${1:-"Unknown Error"}

Hostname: $(hostname)
Logs:
$(tail -n 10 "$LOG_FILE")
EOF

    else
        info "No email sent. EMAIL_USERNAME not set."
    fi
    exit 1
}

# Function to print an informational message.
function info()
{
    echo "INFO: ${1}"
    log "INFO: ${1}"
}

function log()
{
    if [ "${LOG_FILE}" != "" ]; then
        echo "$(date '+%F %T.%3N') ${1}" >> "$LOG_FILE"
    fi
}

# Source environment variables from the .env file if it exists
if [ -f "$SCRIPT_DIR"/.env ]; then
    source "$SCRIPT_DIR"/.env || exit 1
fi

# Check if script is running as root
if [[ $EUID -ne 0 ]]; then
    error_exit "Script $0 must be run as root"
fi

# Display usage information if -h or --help option is provided
if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    usage
    exit 0
fi


####  MAIN CODE  ####

# Function to clean up the temporary directory and device mapper
function cleanup()
{
    info "Cleaning up"

    # Ask user to press any key to continue
    if [ "$YES_OPTION" != "true" ]; then
        read -n 1 -s -r -p "Press any key to continue..."
    fi

    # Unmount the encrypted volume
    fuser -km "$HDD_BACKUP_TMP_DIR" # kill processes using the directory
    umount "$HDD_BACKUP_TMP_DIR" || true

    # Remove the temporary directory
    rm -rf "$HDD_BACKUP_TMP_DIR" || true

    # Close the encrypted volume with LUKS
    cryptsetup luksClose "luks-$HDD_BACKUP_HDD_UUID" || true
}

# Check if yes option is provided
if [ "$1" == "-y" ] || [ "$1" == "--yes" ]; then
    YES_OPTION=true
    shift
fi

# Build rsync exclude parameters string from array
EXCLUDE_PARAMS=()
for dir in "${HDD_BACKUP_EXCLUDE_DIRS[@]}"; do
    EXCLUDE_PARAMS+=(--exclude="$dir")
done

# Need to check that rsync is installed
if ! command -v rsync >/dev/null 2>&1; then
    error_exit "Required command rsync is not installed or not available in the PATH"
fi

# Need to check that cryptsetup is installed
if ! command -v cryptsetup >/dev/null 2>&1; then
    error_exit "Required command cryptsetup is not installed or not available in the PATH"
fi

# Check that a UUID argument has been given.
if [ $# -lt 1 ]; then
    usage
    error_exit "No UUID argument supplied."
fi

# Create a temporary directory.
if ! HDD_BACKUP_TMP_DIR=$(mktemp -d); then
    error_exit "Failed to create temporary directory"
fi

if [ -z "$HDD_BACKUP_HDD_UUID" ]; then
    error_exit "Destination HDD not found"
fi

# Check if HDD is already mounted
if grep -q "^/dev/mapper/luks-$HDD_BACKUP_HDD_UUID" /proc/mounts; then
    error_exit "Destination HDD is already mounted."
fi

# Check that storage directory exists.
if [ ! -d "$HDD_BACKUP_SOURCE_PATH" ]; then
    error_exit "Source path not found."
fi

# Check that storage directory has files in
if [ ! "$(ls -A "$HDD_BACKUP_SOURCE_PATH")" ]; then
    error_exit "Source path $HDD_BACKUP_SOURCE_PATH is empty. Nothing to backup."
fi

# Register the cleanup function to be called on exit
trap cleanup SIGINT SIGTERM SIGHUP EXIT

info "Unlocking HDD"

# Unlock the LUKS-encrypted hard drive
if ! cryptsetup luksOpen "/dev/disk/by-uuid/$HDD_BACKUP_HDD_UUID" "luks-$HDD_BACKUP_HDD_UUID"; then
    error_exit "Unlock error"
fi

# Mount the unlocked hard drive to the temporary directory
if ! mount "/dev/mapper/luks-$HDD_BACKUP_HDD_UUID" "$HDD_BACKUP_TMP_DIR"; then
    error_exit "Mount error"
fi

# Ask user if they're ready to continue
if [ "$YES_OPTION" != "true" ]; then
    read -rp "HDD is mounted at $HDD_BACKUP_TMP_DIR for backup. Ready to continue? (y/n): " answer
    if [[ $answer != "y" && $answer != "Y" ]]; then
        error_exit "Backup aborted."
    fi
fi

# Use rsync to copy files from the source directory to the temporary directory
# -a: Preserve file attributes (timestamps, permissions, etc.)
# -r: Recurse into subdirectories
# -t: Preserve modification times
# -v: Increase verbosity (show detailed output)
# -u: Update files (skip files that are newer on the destination)
# --del: Delete files from the destination that do not exist in the source
# --prune-empty-dirs: Remove empty directories from the destination
# --exclude: Exclude specific files or directories from the sync
# Source directory: $HDD_BACKUP_SOURCE_PATH
# Destination directory: $HDD_BACKUP_TMP_DIR
if ! rsync \
    -artvu \
    --del \
    --prune-empty-dirs \
    "${EXCLUDE_PARAMS[@]}" \
    "$HDD_BACKUP_SOURCE_PATH" \
    "$HDD_BACKUP_TMP_DIR"
then
    error_exit "Rsync command failed."
fi

info "Backup completed!"
