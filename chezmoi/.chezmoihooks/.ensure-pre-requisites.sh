#!/bin/bash
# Installs prerequisites needed before chezmoi can fully operate
# Runs during hooks.read-source-state.pre (CAN'T be a template)

set -euo pipefail

# Determine source directory for reading declarative files
SOURCE_DIR="${CHEZMOI_SOURCE_DIR:-$(cd -P "$(dirname "$0")/.." && pwd -P)}"
REQUIREMENTS_FILE="$SOURCE_DIR/.chezmoidata/requirements.yaml"

# Non-interactive when running under the test harness, prompting otherwise.
if [[ "${DOTFILES_TEST:-}" == "1" ]]; then
    apt_yes="-y"
    dnf_yes="-y"
    pacman_yes="--noconfirm"
    export DEBIAN_FRONTEND=noninteractive
else
    apt_yes=""
    dnf_yes=""
    pacman_yes=""
fi

# --- Bootstrap substrate ---
# Cloud test images vary in which downloader is preinstalled. The hook needs one
# before it can read requirements.yaml, so resolve curl or wget here
# (requirements.yaml declares the rest for machines provisioned outside an test image).
ensure_cmd() {
    local cmd="$1" pkg="${2:-$1}"
    command -v "$cmd" &>/dev/null && return 0
    echo "Installing $pkg (needed to bootstrap)..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install $apt_yes "$pkg"
    elif command -v dnf &>/dev/null; then
        sudo dnf install $dnf_yes "$pkg"
    elif command -v pacman &>/dev/null; then
        sudo pacman -Syu --needed $pacman_yes "$pkg"
    else
        echo "cannot install $pkg: no known package manager" >&2
        return 1
    fi
}

download() { # download <url> <dest>
    local url="$1" dest="$2"
    if command -v curl &>/dev/null; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget &>/dev/null; then
        wget -qO "$dest" "$url"
    else
        ensure_cmd curl
        curl -fsSL "$url" -o "$dest"
    fi
}

# --- Resolve yq for bootstrap parsing ---
# If it is not available yet, download and use a temporary
# yq binary and remove it on every exit.
# mise installs the persistent yq after this pre-source hook. 
if command -v yq &>/dev/null; then
    YQ_BIN="$(command -v yq)"
else
    YQ_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chezmoi-yq.XXXXXX")"
    trap 'rm -rf -- "$YQ_TMP_DIR"' EXIT
    YQ_BIN="$YQ_TMP_DIR/yq"
    echo "Downloading temporary yq binary for bootstrap parsing..."
    yq_arch=""
    case "$(uname -m)" in
        x86_64 | amd64) yq_arch="amd64" ;;
        aarch64 | arm64) yq_arch="arm64" ;;
        armv7* | armv6* | armv8l) yq_arch="arm" ;;
        i386 | i686) yq_arch="386" ;;
        *)
            echo "unsupported architecture '$(uname -m)' for temporary yq download" >&2
            exit 1
            ;;
    esac
    download "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}" "$YQ_BIN"
    chmod 0755 "$YQ_BIN"
fi

# --- Detect OS ---
DISTRO=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO="$ID"
fi

if [ -f "$REQUIREMENTS_FILE" ]; then
    # Use process substitution to run yq in the background and
    # feed the output line by line into mapfile 
    mapfile -t toolchain_packages < <(
        DISTRO="$DISTRO" "$YQ_BIN" -r \
            '((.linux.common // []) + (.linux[strenv(DISTRO)] // [])) | .[] | select(. != "")' \
            "$REQUIREMENTS_FILE" 2>/dev/null
    )

    # List the installed packages
    case "$DISTRO" in
        arch | cachyos)
            installed=$(pacman -Qq 2>/dev/null)
            ;;
        ubuntu | debian | pop)
            # Status-Abbrev is "ii " for installed packages; awk compares the second field.
            installed=$(dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' 2>/dev/null \
                | awk '$2 == "ii" { print $1 }')
            ;;
        fedora)
            installed=$(rpm -qa --qf '%{NAME}\n' 2>/dev/null)
            ;;
        *)
            echo "Unsupported distro: $DISTRO" >&2
            installed=""
            ;;
    esac

    toolchain_missing=()
    for package in "${toolchain_packages[@]}"; do
        grep -qx -- "$package" <<< "$installed" || toolchain_missing+=("$package")
    done

    # --- Install missing packages if any ---
    if [ ${#toolchain_missing[@]} -gt 0 ]; then
        echo "Installing toolchain packages: ${toolchain_missing[*]}"

        case "$DISTRO" in
        ubuntu | debian | pop)
            sudo apt-get update -qq || { echo "apt-get update failed" >&2; return 1; }
            sudo DEBIAN_FRONTEND=noninteractive apt-get install $apt_yes "${toolchain_missing[@]}" \
                || { echo "apt-get install failed" >&2; return 1; }
            ;;
        fedora)
            sudo dnf install $dnf_yes "${toolchain_missing[@]}" \
                || { echo "dnf install failed" >&2; return 1; }
            ;;
        arch | cachyos)
            sudo pacman -Syu --needed $pacman_yes "${toolchain_missing[@]}" \
                || { echo "pacman install failed" >&2; return 1; }
            ;;
        *)
            echo "Unknown/unsupported distro '$DISTRO'. Cannot install toolchain packages." >&2
            return 1
            ;;
        esac
    fi
fi
