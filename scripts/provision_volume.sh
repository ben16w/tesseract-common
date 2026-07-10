#!/usr/bin/env bash

####  CONFIGURATION  ####

PROVISION_TMP_DIR="" # temporary directory to mount filesystem
PROVISION_TMP_VOLUME=/dev/mapper/temp_provision_disk # the path for the temporary encrypted volume
PROVISION_FILE=./volume # the file path for the encrypted volume
PROVISION_SIZE=4G # default size of the volume
PROVISION_PASSWORD=password # default password for the volume
PROVISION_ADD_DATA=false # whether to add sample data to the volume or not
PROVISION_SAMPLE_FILES_NUM=10
PROVISION_SAMPLE_DIRS=(
    "Tvshows"
    "Audio"
    "Music"
    "Nextcloud"
    "Downloads"
    "Ebooks"
)

# Function to print the script usage message.
function usage()
{
    echo "Usage: $(basename "$0") [-s <SIZE>] [-p <PASSWORD>] [-d] <VOLUME_FILE>"
    echo "Create an encrypted volume with specified size and password, and add sample data if specified."
    echo ""
    echo "  -s size        Set the size of the volume, default is 4G."
    echo "  -p password    Set the password of the volume, default is 'password'."
    echo "  -d             Add sample data to the volume, default is false."
    echo "  VOLUME_FILE    The file path of the volume to create."
    echo
    exit 0
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
fi


####  MAIN CODE  ####

# Function to clean up the temporary directory and device mapper.
function cleanup()
{
    info "Cleaning up"

    # Unmount the encrypted volume.
    umount "$PROVISION_TMP_DIR" || true

    # Close the encrypted volume with LUKS.
    cryptsetup luksClose "$PROVISION_TMP_VOLUME" || true

    # Remove the temporary directory.
    rm -rf "$PROVISION_TMP_DIR" || true
}

# Register the cleanup function to be called on exit.
trap cleanup SIGINT SIGTERM SIGHUP EXIT

# Check that cryptsetup is installed
if ! command -v cryptsetup &> /dev/null; then
    error_exit "cryptsetup could not be found."
fi

# Check that a path argument has been given.
if [ $# -lt 1 ]; then
    error_exit "No path argument supplied."
fi

# Parse any command line options using getopts.
while getopts "s:p:d" flag; do
    case "${flag}" in
        s) PROVISION_SIZE=${OPTARG};;
        p) PROVISION_PASSWORD=${OPTARG};;
        d) PROVISION_ADD_DATA=true;;
        ?) usage;;
    esac
done

# Get the volume file path from the remaining command line arguments.
PROVISION_FILE=${*: $OPTIND:1}

# Check if the volume file already exists
if [ -f "$PROVISION_FILE" ]; then
    error_exit "File already exists."
fi

# Check if the parent directory of the volume file exists.
DIRECTORY=$(dirname "$PROVISION_FILE")
if [ ! -d "$DIRECTORY" ]; then
    error_exit "$DIRECTORY does not exist."
fi

# Check that the filename is at least 2 characters long.
FILENAME=$(basename "$PROVISION_FILE")
if [ ${#FILENAME} -lt 2 ]; then
    error_exit "Filename '$FILENAME' is too short."
fi

# Create a temporary directory.
if ! PROVISION_TMP_DIR=$(mktemp -d); then
    error_exit "Failed to create temporary directory"
fi

# Check that the temporary directory is empty.
if [ "$(ls -A "$PROVISION_TMP_DIR")" ]; then
    error_exit "Temp directory $PROVISION_TMP_DIR not empty."
fi

# Allocate disk space for the encrypted volume.
if ! fallocate -l "$PROVISION_SIZE" "$PROVISION_FILE"; then
    error_exit "Failed to allocate disk space for encrypted volume."
fi

# Format the volume with LUKS encryption. The -q and -y options avoid interactive prompts.
if ! echo -n "$PROVISION_PASSWORD" | cryptsetup -q -y luksFormat "$PROVISION_FILE"; then
    error_exit "Failed to format volume with LUKS encryption."
fi

# Open the encrypted volume with LUKS.
if ! echo -n "$PROVISION_PASSWORD" | cryptsetup luksOpen "$PROVISION_FILE" "$(basename $PROVISION_TMP_VOLUME)"; then
    error_exit "Failed to open encrypted volume with LUKS."
fi

# Format the volume with the ext4 file system.
if ! mkfs.ext4 "$PROVISION_TMP_VOLUME"; then
    error_exit "Failed to format volume with ext4 file system."
fi

# If the user has selected to add data to the volume
# then create sample files with random content, set permissions and ownership.
if [ "$PROVISION_ADD_DATA" != "false" ]; then

    info "Adding sample data."

    # Mount the encrypted volume.
    mount "$PROVISION_TMP_VOLUME" "$PROVISION_TMP_DIR"

    # Loop through each directory in PROVISION_SAMPLE_DIRS and create sample files in each directory.
    for dir in "${PROVISION_SAMPLE_DIRS[@]}"; do
        mkdir "$PROVISION_TMP_DIR/$dir"
        for (( i=1; i<=PROVISION_SAMPLE_FILES_NUM; i++ )); do
        # Create a sample file filled with random data
        dd if=/dev/urandom bs=1M count=8 of="$PROVISION_TMP_DIR/$dir/samplefile-$i"
        
        # Set file permissions to allow read, write, and execute for all users
        chmod 777 "$PROVISION_TMP_DIR/$dir/samplefile-$i"
        
        # Set file ownership to user ID 1000 and group ID 1000
        chown 1000:1000 "$PROVISION_TMP_DIR/$dir/samplefile-$i"
        done
    done

    mkdir "$PROVISION_TMP_DIR/Movies"
    wget -q "https://samples.tdarr.io/api/v1/samples/sample__1080__libx264__alac__30s__video.mkv" \
        -O "$PROVISION_TMP_DIR/Movies/Big Buck Bunny (2008).mkv"

    mkdir "$PROVISION_TMP_DIR/Photos"
    for i in {1..25}; do
        wget -q "https://picsum.photos/800" \
        -O "$PROVISION_TMP_DIR/Photos/photo$i.jpg"
    done

fi

info "Finished!"
