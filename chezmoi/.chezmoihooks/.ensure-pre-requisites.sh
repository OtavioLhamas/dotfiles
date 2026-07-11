#!/bin/bash
# Installs prerequisites needed before chezmoi can fully operate
# Runs during hooks.read-source-state.pre (NOT a template)

set -euo pipefail

# Determine source directory for reading declarative files
SOURCE_DIR="${CHEZMOI_SOURCE_DIR:-$(cd -P "$(dirname "$0")/.." && pwd -P)}"
REQUIREMENTS_FILE="$SOURCE_DIR/.chezmoidata/requirements.yaml"

# --- Install yq if missing ---
# yq is needed to parse requirements.yaml below, so install it first.
# The Debian/Ubuntu apt version is outdated, so we always pull from GitHub.
if ! command -v yq &>/dev/null; then
    echo "Installing yq binary..."
    sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
    sudo chmod +x /usr/local/bin/yq
fi

# --- Detect OS ---
DISTRO=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO="$ID"
fi

if [ -f "$REQUIREMENTS_FILE" ]; then
    # Read common packages for all Linux distros
    common_packages=$(yq '.linux.common[]' "$REQUIREMENTS_FILE" 2>/dev/null)

    # Read distro-specific packages
    distro_packages=$(yq ".linux.${DISTRO}[]" "$REQUIREMENTS_FILE" 2>/dev/null)

    toolchain_packages=()
    if [ -n "$common_packages" ] && [ "$common_packages" != "null" ]; then
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && toolchain_packages+=("$pkg")
        done <<< "$common_packages"
    fi
    if [ -n "$distro_packages" ] && [ "$distro_packages" != "null" ]; then
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && toolchain_packages+=("$pkg")
        done <<< "$distro_packages"
    fi

    toolchain_missing=()
    for package in "${toolchain_packages[@]}"; do
        if ! dpkg -l "$package" 2>/dev/null | grep -q '^ii' && ! rpm -q "$package" &>/dev/null 2>&1; then
            toolchain_missing+=("${package}")
        fi
    done

    # --- Install missing packages if any ---
    if [ ${#toolchain_missing[@]} -gt 0 ]; then
        case "$DISTRO" in
        ubuntu | debian | pop)
            sudo apt-get update -qq
            install_cmd="sudo DEBIAN_FRONTEND=noninteractive apt-get install -y"
            ;;
        fedora)
            install_cmd="sudo dnf install -y"
            ;;
        esac

        echo "Installing toolchain packages: ${toolchain_missing[*]}"
        $install_cmd "${toolchain_missing[@]}"
    fi
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
