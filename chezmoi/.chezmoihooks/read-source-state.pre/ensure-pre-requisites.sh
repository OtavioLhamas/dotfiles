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

# Helper install function
install_pkg() {
    local pkg="$1"
    case "$DISTRO" in
    ubuntu | debian | pop)
        sudo apt-get update -qq
        sudo apt-get install -y "${pkg[@]}"
        ;;
    fedora)
        sudo dnf install -y "${pkg[@]}"
        ;;
    *)
        echo "Unknown/unsupported distro '$DISTRO'. Cannot install '${missing_packages[*]}' automatically."
        ;;
    esac
}

echo "Installing missing packages: ${missing_packages[*]}"
install_pkg missing_packages

if ! command -v yq &>/dev/null; then
    # --- Install yq if missing ---
    echo "Installing yq binary..."
    sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
    sudo chmod +x /usr/local/bin/yq
fi

if ! command -v bw &>/dev/null; then
    # --- Install Bitwarden CLI if missing ---
    echo "Installing Bitwarden CLI (bw)..."
    case "$DISTRO" in
    ubuntu | debian | pop)
        sudo apt-get install -y libsecret-1-0
        ;;
    fedora | rhel | rocky | almalinux)
        sudo dnf install -y libsecret
        ;;
    esac

    # Install bw via npm/npx or download binary
    BW_VERSION=$(curl -s https://api.github.com/repos/bitwarden/clients/releases | grep -o '"tag_name": "cli-v[^"]*' | grep -o 'v[0-9.]*' | head -n 1)

    if [ -z "$BW_VERSION" ]; then
        BW_VERSION="v2026.4.1" # fallback
    fi

    BW_URL="https://github.com/bitwarden/clients/releases/download/cli-${BW_VERSION}/bw-linux-${BW_VERSION}.zip"
    TEMP_DIR=$(mktemp -d)
    curl -sL "$BW_URL" -o "$TEMP_DIR/bw.zip"
    unzip -q "$TEMP_DIR/bw.zip" -d "$TEMP_DIR"
    sudo mv "$TEMP_DIR/bw" /usr/local/bin/bw
    sudo chmod +x /usr/local/bin/bw
    rm -rf "$TEMP_DIR"
    echo "Bitwarden CLI installed"
else
    echo "Bitwarden CLI already installed"
fi

if command -v bw &>/dev/null; then
    # --- Prompt for Bitwarden login if needed ---
    BW_STATUS=$(bw status 2>/dev/null | yq '.status // "unauthenticated"')
    if [ "$BW_STATUS" != "unlocked" ]; then
        echo ""
        echo "Bitwarden CLI requires login. Please run the following before chezmoi apply if you need secrets:"
        echo "  bw login"
        echo "  export BW_SESSION=\$(bw unlock --raw)"
        echo ""
    fi
fi
