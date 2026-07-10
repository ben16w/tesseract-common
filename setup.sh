#!/bin/sh
set -e

main() {
    BASE_URL="https://raw.githubusercontent.com/ben16w/tesseract-common/main"

    if [ "$(id -u)" -eq 0 ]; then
        SUDO=""
    else
        SUDO="sudo"
    fi

    # Install system dependencies
    if command -v apt-get >/dev/null 2>&1; then
        missing=""
        for pkg in curl python3 python3-pip python3-venv sshpass; do
            if ! dpkg -s "$pkg" >/dev/null 2>&1; then
                missing="$missing $pkg"
            fi
        done
        if [ -n "$missing" ]; then
            echo "Installing$missing..."
            $SUDO apt-get update -qq
            $SUDO apt-get install -y -qq $missing
        fi
    elif command -v apk >/dev/null 2>&1; then
        missing=""
        for pkg in bash curl python3 py3-pip; do
            if ! apk info -e "$pkg" >/dev/null 2>&1; then
                missing="$missing $pkg"
            fi
        done
        if [ -n "$missing" ]; then
            echo "Installing$missing..."
            apk add --no-cache $missing
        fi
    fi

    # Install just
    if ! command -v just >/dev/null 2>&1; then
        echo "Installing just..."
        curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin
    fi

    # Self-update
    echo "Updating setup.sh..."
    curl -fsSL "$BASE_URL/setup.sh" -o setup.sh || echo "Warning: Could not update setup.sh, skipping."

    # Download Justfile
    echo "Downloading Justfile..."
    curl -fsSL "$BASE_URL/Justfile" -o Justfile || echo "Warning: Could not download Justfile, skipping."

    echo "Done. Run 'just install-venv' to set up the virtual environment."
}

main "$@"
