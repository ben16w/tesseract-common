#!/usr/bin/env bash

####  CONFIGURATION  ####

RSYNC_BACKUP_DESTINATION="."
RSYNC_BACKUP_MAX_BACKUPS="10"
RSYNC_BACKUP_PATHS=("$@")
DATE=$(date +"%Y%m%d")

function usage()
{
    echo "Usage: $0 [-h|--help] <BACKUP_PATH> [<BACKUP_PATH2> ...]"
    echo "Description: Performs a simple incremental backup solution using rsync"
    echo "and hard links the specified paths with a maximum number of backups."
    echo "Arguments:"
    echo "  <BACKUP_PATH>    The path(s) to be backed up. Multiple paths can be provided."
    echo "Options:"
    echo "  -h, --help       Display this help message and exit."
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

# Check that a path argument has been given.
if [ -z "$1" ]; then
    error_exit "No path arguments supplied."
fi

# Check backup destination
if [ ! -d "$RSYNC_BACKUP_DESTINATION" ]; then
    error_exit "No backup destination $RSYNC_BACKUP_DESTINATION."
fi

# Check if rsync is installed
if ! command -v rsync &> /dev/null; then
    error_exit "rsync could not be found on system."
fi

for backup_path in "${RSYNC_BACKUP_PATHS[@]}"; do

    info "Rsync backup of path $backup_path starting."

    backup_name=$(basename "$backup_path")

    # Check if another instance of script is running
    pidof -o %PPID -x "$0" >/dev/null && error_exit "Script $0 already running"

    # Check backup path exists.
    if [ ! -d "$backup_path" ]; then
        error_exit "No backup path $backup_path."
    fi

    # Check that backup path has files in it
    if [ ! "$(ls -A "$backup_path")" ]; then
        error_exit "Backup path $backup_path empty."
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

    cd "$RSYNC_BACKUP_DESTINATION/" || error_exit
    # latest backup directory with $backup_name-backup- prefix
    latest_backup_dir=$(ls -td -- "$backup_name-backup-"* | head -n 1)

    backup_dest_dir="$backup_name-backup-$DATE"

    # Check if backup directory already exists
    if [ -d "$backup_dest_dir" ]; then
        error_exit "Backup destination directory $backup_dest_dir already exists."
    fi

    if [[ docker_found -eq 1 ]]; then
        info "Stopping Docker containers."
        docker stop "${running_containers[@]}" &>> "$LOG_FILE"
        if [ $? -ne 0 ]; then
            error_exit "Docker stop command failed."
        fi
    fi

    # rsync command using hard links to create incremental backups
    info "Performing rsync backup of $backup_path to $backup_dest_dir"
    rsync -av --delete --link-dest="$latest_backup_dir" "$backup_path" "$backup_dest_dir" &>> "$LOG_FILE"
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

    # Delete old backups if number of backups exceeds RSYNC_BACKUP_MAX_BACKUPS
    cd "$RSYNC_BACKUP_DESTINATION/" || error_exit
    mapfile -t backup_dirs < <(
        shopt -s nullglob
        for dir in */; do
            [[ $dir =~ $backup_name-backup- ]] && echo "$dir"
        done
    )
    if [ ${#backup_dirs[@]} -gt "$RSYNC_BACKUP_MAX_BACKUPS" ]; then
        info "Number of backups exceeds $RSYNC_BACKUP_MAX_BACKUPS. Deleting old backups."
        for ((i=${#backup_dirs[@]}-1; i>=RSYNC_BACKUP_MAX_BACKUPS; i--)); do
            info "Deleting backup ${backup_dirs[i]}"
            rm -rf "${backup_dirs[i]}" &>> "$LOG_FILE"
            if [ $? -ne 0 ]; then
                error_exit "Failed to delete backup ${backup_dirs[i]}."
            fi
        done
    fi
    
    info "Rsync backup of path $backup_path completed"

done
