#!/bin/bash
# Dotfiles bootstrap script for Linux and WSL
# Minimal bootstrap: installs chezmoi only, everything else is handled by chezmoi scripts

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
    if [ -f "$chezmoi" ]; then
        export PATH="$chezmoi:$PATH"
        echo "$PATH"
    fi

    unset chezmoi_install_script bin_dir
else
    echo "chezmoi already installed"
fi

# POSIX way to get script's dir: https://stackoverflow.com/a/29834779/12156188
script_dir="$(cd -P -- "$(dirname -- "$(command -v -- "$0")")" && pwd -P)"

set -- init OtavioLhamas --apply --source="${script_dir}/chezmoi"

echo "Running 'chezmoi $*'" >&2
# exec: replace current process with chezmoi
exec "$chezmoi" "$@"
