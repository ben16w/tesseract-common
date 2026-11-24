#!/usr/bin/env bash


####  CONFIGURATION  ####

KOPIA_BACKUP_LOG_DIR="/var/log/kopia/"
KOPIA_BACKUP_LOG_LEVEL="debug"
KOPIA_BACKUP_VERIFY_PERCENT="0.3"
KOPIA_BACKUP_VERIFY_ENABLED="true"
KOPIA_BACKUP_PARALLELISM="10"
KOPIA_BACKUP_MAINTENANCE_RETRIES="3"
KOPIA_BACKUP_MAINTENANCE_RETRY_DELAY="60"

function usage()
{
    echo "Kopia to BackBlaze backup for specified path."
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

# Run full maintenance with retries. Snapshot success is independent of this.
function run_maintenance()
{
    local attempt=1
    local max_attempts="${KOPIA_BACKUP_MAINTENANCE_RETRIES}"
    local delay="${KOPIA_BACKUP_MAINTENANCE_RETRY_DELAY}"

    while [ "${attempt}" -le "${max_attempts}" ]; do
        info "Running Kopia full maintenance (attempt ${attempt}/${max_attempts})"
        if kopia maintenance run --full \
            --file-log-level="$KOPIA_BACKUP_LOG_LEVEL" \
            --log-dir="$KOPIA_BACKUP_LOG_DIR"; then
            info "Kopia maintenance finished"
            return 0
        fi
        if [ "${attempt}" -lt "${max_attempts}" ]; then
            info "Kopia maintenance failed; retrying in ${delay}s"
            sleep "${delay}"
        fi
        attempt=$((attempt + 1))
    done

    info "Kopia maintenance failed after ${max_attempts} attempts; snapshot data is intact"
    return 0
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

# Need to check that kopia is installed
if ! command -v kopia >/dev/null 2>&1; then
    error_exit "Required command kopia is not installed or not available in the PATH"
fi

for backup_dir in "$@"; do

    info "Cloud backup of path $backup_dir starting"

    # Check if another instance of kopia is running
    pidof -o %PPID -x kopia >/dev/null && error_exit "Kopia is already running"

    # Check that path has files in it
    if [ ! "$(ls -A "$backup_dir")" ]; then
        error_exit "Path $backup_dir empty."
    fi

    # Snapshot without auto-maintenance so transient B2 flakiness during GC
    # does not fail a successful backup. Maintenance runs separately below.
    kopia snapshot create \
        "$backup_dir" \
        --no-auto-maintenance \
        --file-log-level="$KOPIA_BACKUP_LOG_LEVEL" \
        --log-dir="$KOPIA_BACKUP_LOG_DIR" \
        --parallel="$KOPIA_BACKUP_PARALLELISM"
    response=$?
    if [ $response -ne 0 ]; then
        error_exit "Kopia command failed."
    fi

done

run_maintenance

if [ "$KOPIA_BACKUP_VERIFY_ENABLED" = "true" ]; then
    info "Starting verification of kopia repository"

    kopia snapshot verify \
        --no-auto-maintenance \
        --verify-files-percent="$KOPIA_BACKUP_VERIFY_PERCENT" \
        --parallel="$KOPIA_BACKUP_PARALLELISM" \
        --file-parallelism="$KOPIA_BACKUP_PARALLELISM"
    response=$?
    if [ $response -ne 0 ]; then
        error_exit "Kopia verify command failed."
    fi
else
    info "Kopia verification is disabled"
fi

info "Cloud backup of path $backup_dir finished!"
