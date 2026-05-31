#!/bin/bash
# Runs during hooks.read-source-state.pre
# Installs prerequisites needed before chezmoi can fully operate

set -euo pipefail

# Detect OS
DISTRO=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO="$ID"
fi

wanted_packages=(
    curl
    wget
    git
)

missing_packages=()
for package in "${wanted_packages[@]}"; do
    if ! command -v "${package}" &>/dev/null; then
        missing_packages+=("${package}")
    fi
done

# --- Install missing packages if any ---
if [ ! ${#missing_packages[@]} -eq 0 ]; then
    install_cmd=""
    case "$DISTRO" in
    ubuntu | debian | pop)
        sudo apt-get update -qq
        install_cmd="sudo DEBIAN_FRONTEND=noninteractive apt-get install -y"
        ;;
    fedora)
        install_cmd="sudo dnf install -y"
        ;;
    *)
        echo "Unknown/unsupported distro '$DISTRO'. Cannot install missing packages automatically."
        ;;
    esac

    echo "Installing missing packages: ${missing_packages[*]}"
    $install_cmd "${missing_packages[@]}"
fi

# --- Install yq if missing ---
# Debian registry version is outdated
if ! command -v yq &>/dev/null; then
    echo "Installing yq binary..."
    sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
    sudo chmod +x /usr/local/bin/yq
fi

# --- Install Bitwarden CLI if missing ---
if ! command -v bw &>/dev/null; then
    echo "Installing Bitwarden CLI (bw)..."

    # Fetch the latest CLI release number
    BW_VERSION=$(curl -s https://api.github.com/repos/bitwarden/clients/releases | grep -o '"tag_name": "cli-v[^"]*' | grep -o '[0-9.]*' | head -n 1)

    if [ -z "$BW_VERSION" ]; then
        BW_VERSION="2026.4.1" # fallback
    fi

    BW_URL="https://github.com/bitwarden/clients/releases/download/cli-v${BW_VERSION}/bw-linux-${BW_VERSION}.zip"

    TEMP_DIR=$(mktemp -d)
    curl -sL "$BW_URL" -o "$TEMP_DIR/bw.zip"
    unzip -q "$TEMP_DIR/bw.zip" -d "$TEMP_DIR"
    sudo mv "$TEMP_DIR/bw" /usr/local/bin/bw
    sudo chmod +x /usr/local/bin/bw
    rm -rf "$TEMP_DIR"
fi

# --- Prompt for Bitwarden login if needed ---
if command -v bw &>/dev/null; then
    BW_STATUS=$(bw status 2>/dev/null | yq '.status // "unauthenticated"')

    if [ "$BW_STATUS" = "unauthenticated" ]; then
        bw login
    fi
fi
