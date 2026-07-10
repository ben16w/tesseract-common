#!/usr/bin/env bash

# TODO
# Fix bug in the do_backup find commands

####  CONFIGURATION  ####

LOCAL_BACKUP_DESTINATION="."
LOCAL_BACKUP_KEEP_DAILY="3"
LOCAL_BACKUP_KEEP_WEEKLY="2"
LOCAL_BACKUP_KEEP_MONTHLY="1"

function usage()
{
    echo "Usage: $0 [-h|--help] <BACKUP_PATH> [<BACKUP_PATH2> ...]"
    echo "Description: Performs local backups of the specified paths."
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
if [ ! -d "$LOCAL_BACKUP_DESTINATION" ]; then
    error_exit "No backup destination $LOCAL_BACKUP_DESTINATION."
fi

for backup_path in "$@"; do

    info "Local backup of path $backup_path starting."

    backup_name=$(basename "$backup_path")

    # Check if another instance of script is running
    pidof -o %PPID -x "$0" >/dev/null && error_exit "Script $0 already running"

    # Check backup path exists.
    if [ ! -d "$backup_path" ]; then
        error_exit "No backup path $backup_path."
    fi

    # Check that local backup path has files in it
    if [ ! "$(ls -A "$backup_path")" ]; then
        error_exit "Local backup path $backup_path empty."
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

    MONTH=$(date +%d)
    DAYWEEK=$(date +%u)

    if [[ ${MONTH#0} -eq 1  ]];
            then
            FN='monthly'
    elif [[ ${DAYWEEK#0} -eq 7  ]];
            then
            FN='weekly'
    elif [[ ${DAYWEEK#0} -lt 7 ]];
            then
            FN='daily'
    fi

    DATE=$FN-$(date +"%Y%m%d")

    function do_backup
    {
        cd "$LOCAL_BACKUP_DESTINATION/" || error_exit
        filename="$backup_name-backup-$DATE.tar.gz"
        if [ -f "$filename" ]; then
            info "Backup $filename has already been made for today."
            return
        fi

        if [[ docker_found -eq 1 ]]; then
            info "Stopping Docker containers."
            docker stop "${running_containers[@]}" &>> "$LOG_FILE"
            if [ $? -ne 0 ]; then
                error_exit "Docker stop command failed."
            fi
        fi

        info "Creating archive from path."
        tar --warning=no-file-changed -p -zcf "$filename" "$backup_path" &>> "$LOG_FILE"
        if [ $? -ne 0 ]; then
            error_exit "Tar command failed."
        fi

        if [[ docker_found -eq 1 ]]; then
            info "Starting Docker containers."
            docker start "${running_containers[@]}" &>> "$LOG_FILE"
            if [ $? -ne 0 ]; then
                error_exit "Docker start command failed."
            fi
        fi

        find ./ -type f -name "$backup_name-backup-daily*.tar.gz" -printf '%T@ %p\n' | sort -k1 -nr | sed 's/.* //g' \
            | sed -e 1,"$LOCAL_BACKUP_KEEP_DAILY"d | xargs -d '\n' rm -R > /dev/null 2>&1
        find ./ -type f -name "$backup_name-backup-weekly*.tar.gz" -printf '%T@ %p\n' | sort -k1 -nr | sed 's/.* //g' \
            | sed -e 1,"$LOCAL_BACKUP_KEEP_WEEKLY"d | xargs -d '\n' rm -R > /dev/null 2>&1
        find ./ -type f -name "$backup_name-backup-monthly*.tar.gz" -printf '%T@ %p\n' | sort -k1 -nr | sed 's/.* //g' \
            | sed -e 1,"$LOCAL_BACKUP_KEEP_MONTHLY"d | xargs -d '\n' rm -R > /dev/null 2>&1

    }

    if [[ ( -n "$LOCAL_BACKUP_KEEP_DAILY" ) && ( $LOCAL_BACKUP_KEEP_DAILY -ne 0 ) && ( $FN == daily ) ]]; then
        do_backup
    fi
    if [[ ( -n "$LOCAL_BACKUP_KEEP_WEEKLY" ) && ( $LOCAL_BACKUP_KEEP_WEEKLY -ne 0 ) && ( $FN == weekly ) ]]; then
        do_backup
    fi
    if [[ ( -n "$LOCAL_BACKUP_KEEP_MONTHLY" ) && ( $LOCAL_BACKUP_KEEP_MONTHLY -ne 0 ) && ( $FN == monthly ) ]]; then
        do_backup
    fi

    info "Local backup of path $backup_path completed"

done
