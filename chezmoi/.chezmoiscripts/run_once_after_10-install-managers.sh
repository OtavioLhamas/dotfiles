#!/bin/bash
# run_once_after_10-install-managers.sh
# Installs mise and ansible on Linux/WSL
# This script runs once after dotfiles are in place

set -euo pipefail

echo "=== Installing Package Managers (Ansible + mise) ==="

# --- Detect OS ---
DISTRO=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO="$ID"
fi

# --- Install mise (user-space tool manager) ---
if ! command -v mise &>/dev/null; then
    echo "Installing mise..."
    curl https://mise.run | sh
    # Add to PATH for this session
    export PATH="$HOME/.local/bin:$PATH"
    echo "mise installed successfully"
else
    echo "mise already installed"
fi

# --- Install ansible ---
if ! command -v ansible-playbook &>/dev/null; then
    echo "Installing ansible..."
    
    case "$DISTRO" in
        ubuntu|debian|pop)
            sudo apt-get update
            sudo apt-get install -y python3 python3-pip python3-venv
            python3 -m pip install --user ansible
            ;;
        fedora|rhel|rocky|almalinux)
            sudo dnf install -y python3 python3-pip
            python3 -m pip install --user ansible
            ;;
        arch|manjaro)
            sudo pacman -S --noconfirm python python-pip
            python3 -m pip install --user ansible
            ;;
        *)
            echo "Warning: Unknown distro '$DISTRO'. Attempting pip install..."
            python3 -m pip install --user ansible
            ;;
    esac
    
    # Ensure local bin is in PATH
    export PATH="$HOME/.local/bin:$PATH"
    echo "ansible installed successfully"
else
    echo "ansible already installed"
fi

echo "=== Package Managers Ready ==="
