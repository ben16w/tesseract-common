#!/bin/sh
# Bootstrap script for Tesseract repositories.
# Installs dependencies, the just command runner, and downloads the shared
# Justfile.

{
set -e

BASE_URL="https://raw.githubusercontent.com/ben16w/tesseract-common/main"

# --- Self-update ---
if [ "${SETUP_UPDATED:-0}" != "1" ]; then
    echo "Updating setup.sh..."
    if curl -fsSL "$BASE_URL/setup.sh" -o setup.sh.tmp; then
        if ! cmp -s setup.sh setup.sh.tmp; then
            mv setup.sh.tmp setup.sh
            chmod +x setup.sh
            SETUP_UPDATED=1 exec ./setup.sh "$@"
        fi
        rm -f setup.sh.tmp
    else
        echo "Warning: Could not update setup.sh, skipping."
        rm -f setup.sh.tmp
    fi
fi

# --- Privilege handling ---
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# --- System dependencies ---
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
        # shellcheck disable=SC2086
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
        # shellcheck disable=SC2086
        apk add --no-cache $missing
    fi
fi

# --- Just command runner ---
if ! command -v just >/dev/null 2>&1; then
    echo "Installing just..."
    tmpfile=$(mktemp)
    curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh -o "$tmpfile"
    $SUDO bash "$tmpfile" --to /usr/local/bin
    rm -f "$tmpfile"
fi

# --- Shared Justfile ---
echo "Downloading Justfile..."
curl -fsSL "$BASE_URL/Justfile" -o Justfile || echo "Warning: Could not download Justfile, skipping."

echo "Done. Run 'just install-venv' to set up the virtual environment."
exit
}
