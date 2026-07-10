#!/usr/bin/env bash

####  CONFIGURATION  ####

MIRROR_BACKUP_DESTINATION="."
MIRROR_BACKUP_SOURCE="$1"

function usage()
{
    echo "Usage: $0 [-h|--help] <BACKUP_PATH> [-d|--no-docker]"
    echo "Description: Performs a simple backup generating a mirror using rsync"
    echo "Arguments:"
    echo "  <BACKUP_PATH>    The path to be backed up. Only single path can be provided."
    echo "Options:"
    echo "  -h, --help      Display this help message and exit."
    echo "  -d, --no-docker    Don't stop Docker containers before backup."
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
    echo "Sourcing environment variables from $SCRIPT_DIR/.env"
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

# Check that a path argument has been given.
if [ -z "$1" ]; then
    error_exit "No path argument supplied."
fi

# Check backup destination
if [ ! -d "$MIRROR_BACKUP_DESTINATION" ]; then
    error_exit "No backup destination $MIRROR_BACKUP_DESTINATION."
fi

# Check if rsync is installed
if ! command -v rsync &> /dev/null; then
    error_exit "rsync could not be found on system."
fi

# Check if another instance of script is running
pidof -o %PPID -x "$0" >/dev/null && error_exit "Script $0 already running"

info "Mirror backup of path $MIRROR_BACKUP_SOURCE starting."

# if MIRROR_BACKUP_SOURCE does not end with a slash, add it
if [[ ! "$MIRROR_BACKUP_SOURCE" =~ /$ ]]; then
    MIRROR_BACKUP_SOURCE="$MIRROR_BACKUP_SOURCE/"
fi

backup_dest_dir_name="$(basename "$MIRROR_BACKUP_SOURCE")-backup"
backup_dest_dir="$MIRROR_BACKUP_DESTINATION/$backup_dest_dir_name"

# Check backup path exists.
if [ ! -d "$MIRROR_BACKUP_SOURCE" ]; then
    error_exit "No backup path $MIRROR_BACKUP_SOURCE."
fi

# Check that backup path has files in it
if [ ! "$(ls -A "$MIRROR_BACKUP_SOURCE")" ]; then
    error_exit "Backup path $MIRROR_BACKUP_SOURCE empty."
fi

# Check if Docker exists and get list of running containers
docker_found=0
if command -v docker &> /dev/null; then
    info "Docker found of system. Getting list of running containers"
    mapfile -t running_containers < <(docker ps -q)
    if [ ${#running_containers[@]} -ne 0 ]; then
        docker_found=1
    else
        info "No containers running"
        docker_found=0
    fi
else
    info "Docker not found on system."
fi
if [ "$2" == "-d" ] || [ "$2" == "--no-docker" ]; then
    info "Docker containers will not be stopped."
    docker_found=0
fi

mkdir -p "$backup_dest_dir" || error_exit

if [[ docker_found -eq 1 ]]; then
    info "Stopping Docker containers."
    docker stop "${running_containers[@]}" &>> "$LOG_FILE"
    if [ $? -ne 0 ]; then
        error_exit "Docker stop command failed."
    fi
fi

# Run rsync backup
info "Performing mirror backup of $MIRROR_BACKUP_SOURCE to $backup_dest_dir"
rsync -av --delete "$MIRROR_BACKUP_SOURCE" "$backup_dest_dir" &>> "$LOG_FILE"
if [ $? -ne 0 ]; then
    error_exit "rsync command failed."
fi

if [[ docker_found -eq 1 ]]; then
    info "Starting Docker containers."
    docker start "${running_containers[@]}" &>> "$LOG_FILE"
    if [ $? -ne 0 ]; then
        error_exit "Docker start command failed."
    fi
fi

info "Mirror backup of path $MIRROR_BACKUP_SOURCE completed"
