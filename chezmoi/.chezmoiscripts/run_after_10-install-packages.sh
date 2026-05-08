#!/bin/bash
# Installs packages from .chezmoidata/packages.yaml via scripts
# Only for packages not handled by mise or ansible

set -euo pipefail

# --- Detect OS ---
DISTRO=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO="$ID"
fi

# Read packages from chezmoi data
PACKAGES=$(chezmoi data | yq '.packages // {}')

if [ "$PACKAGES" = "{}" ] || [ -z "$PACKAGES" ]; then
    echo "No script-managed packages found in .chezmoidata/packages.yaml"
    exit 0
fi

# --- Install common packages ---
COMMON_PKGS=$(echo "$PACKAGES" | yq '.common // [] | .[] | .name')
for pkg in $COMMON_PKGS; do
    echo "Installing common package: $pkg"
    # Placeholder: add actual install commands per package
    case "$pkg" in
        *)
            echo "  Package '$pkg' not yet configured with install logic"
            ;;
    esac
done

# --- Install OS-specific packages ---
if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ] || [ "$DISTRO" = "pop" ]; then
    OS_PKGS=$(echo "$PACKAGES" | jq -r '.linux.debian.script // [] | .[] | .name')
    for pkg in $OS_PKGS; do
        echo "Installing Debian/Ubuntu package: $pkg"
        case "$pkg" in
            *)
                echo "  Package '$pkg' not yet configured with install logic"
                ;;
        esac
    done
elif [ "$DISTRO" = "fedora" ]; then
    OS_PKGS=$(echo "$PACKAGES" | jq -r '.linux.fedora.script // [] | .[] | .name')
    for pkg in $OS_PKGS; do
        echo "Installing Fedora package: $pkg"
        case "$pkg" in
            *)
                echo "  Package '$pkg' not yet configured with install logic"
                ;;
        esac
    done
fi

echo "=== Script-Managed Packages Complete ==="
