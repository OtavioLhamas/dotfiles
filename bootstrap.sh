#!/bin/bash
# Dotfiles bootstrap script for Linux and WSL
# Minimal bootstrap: installs chezmoi only, everything else is handled by chezmoi scripts

set -euo pipefail

if ! chezmoi="$(command -v chezmoi)"; then
    # Install chezmoi
    bin_dir="${HOME}/.local/bin"
    chezmoi="${bin_dir}/chezmoi"

    echo "Installing chezmoi to '${chezmoi}'" >&2

    if command -v curl >/dev/null; then
        chezmoi_install_script="$(curl -fsLS https://get.chezmoi.io)"
    elif command -v wget >/dev/null; then
        chezmoi_install_script="$(wget -qO- https://get.chezmoi.io)"
    else
        echo "You must have curl or wget to install chezmoi"
    fi

    sh -c "${chezmoi_install_script}" -- -b "${bin_dir}"

    # Move to PATH if installed to local bin
    if [ -f "$HOME/bin/chezmoi" ]; then
        export PATH="$HOME/bin:$PATH"
    fi

    unset chezmoi_install_script bin_dir
else
    echo "chezmoi already installed"
fi

# Verify chezmoi is available
if ! command -v chezmoi &>/dev/null; then
    echo "Error: chezmoi installation failed or not in PATH"
    exit 1
fi

# POSIX way to get script's dir: https://stackoverflow.com/a/29834779/12156188
script_dir="$(cd -P -- "$(dirname -- "$(command -v -- "$0")")" && pwd -P)"

set -- init --apply --source="${script_dir}"

echo "Running 'chezmoi $*'" >&2
# exec: replace current process with chezmoi
exec "$chezmoi" "$@"
