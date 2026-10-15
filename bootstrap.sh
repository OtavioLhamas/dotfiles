#!/usr/bin/env bash
# Dotfiles bootstrap script for Linux and WSL
# Minimal bootstrap: installs chezmoi, then runs `chezmoi init --apply`.
# Everything else is intentionally NOT supported here: use --skip-init to
# install chezmoi only, then run any `chezmoi` command yourself.
#
# Usage:
#   bootstrap.sh [--skip-init] [--bin-dir DIR] [--source DIR] [-h|--help]
#
# Options (flag wins over env):
#   --skip-init      Install chezmoi but do not run `chezmoi init`
#   --bin-dir DIR    Install chezmoi to DIR (env: DOTFILES_BINDIR,
#                    default: $HOME/.local/bin)
#   --source DIR|URL Local source dir or remote repo URL (env: DOTFILES_SOURCE,
#                    default: <script_dir>/chezmoi when run from a checkout,
#                    else DOTFILES_REPO_URL or the default remote below)
#   -h, --help       Show this help and exit
#
# Any other argument is ignored with a warning.

set -euo pipefail

DEFAULT_REPO_URL="https://github.com/OtavioLhamas/dotfiles.git"

usage() {
    cat <<'EOF'
Usage: bootstrap.sh [--skip-init] [--bin-dir DIR] [--source DIR|URL] [-h|--help]

  --skip-init      Install chezmoi but do not run `chezmoi init`
  --bin-dir DIR    Install chezmoi to DIR (env: DOTFILES_BINDIR)
  --source DIR|URL Local source dir or remote repo (env: DOTFILES_SOURCE)
  -h, --help       Show this help and exit

Any other argument is ignored. To customize the init command, use
--skip-init and run `chezmoi init` yourself.
EOF
}

skip_init=0
bin_dir="${DOTFILES_BINDIR:-${HOME}/.local/bin}"
source_arg="${DOTFILES_SOURCE:-}"
ignored=()
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-init) skip_init=1; shift ;;
        --bin-dir) bin_dir="${2:?--bin-dir needs a value}"; shift 2 ;;
        --bin-dir=*) bin_dir="${1#*=}"; shift ;;
        --source) source_arg="${2:---source needs a value}"; shift 2 ;;
        --source=*) source_arg="${1#*=}"; shift ;;
        -h | --help | help) usage; exit 0 ;;
        --) shift ;; # separator, not forwarded anywhere; just skip it
        *) ignored+=("$1"); shift ;;
    esac
done
if [ "${#ignored[@]}" -gt 0 ]; then
    echo "warning: ignoring unknown argument(s): ${ignored[*]}" >&2
fi

# --- install chezmoi (latest from get.chezmoi.io, no version pin) ---
chezmoi=""
if command -v chezmoi >/dev/null 2>&1; then
    chezmoi="$(command -v chezmoi)"
    echo "chezmoi already installed: ${chezmoi}" >&2
else
    chezmoi="${bin_dir}/chezmoi"
    if [ -x "$chezmoi" ]; then
        echo "chezmoi already installed: ${chezmoi}" >&2
    else
        echo "Installing chezmoi to '${chezmoi}'" >&2
        mkdir -p "$bin_dir"
        if command -v curl >/dev/null 2>&1; then
            chezmoi_install_script="$(curl -fsLS https://get.chezmoi.io)"
        elif command -v wget >/dev/null 2>&1; then
            chezmoi_install_script="$(wget -qO- https://get.chezmoi.io)"
        else
            echo "error: you must have curl or wget to install chezmoi" >&2
            exit 1
        fi
        sh -c "${chezmoi_install_script}" -- -b "${bin_dir}"
        unset chezmoi_install_script
        if [ ! -x "$chezmoi" ]; then
            echo "error: chezmoi installation failed (no executable at '${chezmoi}')" >&2
            exit 1
        fi
    fi
fi
export PATH="${bin_dir}:${PATH}"

if [ "$skip_init" -eq 1 ]; then
    echo "Skipping init (--skip-init)." >&2
    exit 0
fi

# --- resolve source: flag > env > local checkout > remote ---
if [ -z "$source_arg" ]; then
    script_dir=""
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" != "bash" ] && [ "${BASH_SOURCE[0]}" != "sh" ]; then
        script_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    fi
    if [ -n "$script_dir" ] && [ -d "${script_dir}/chezmoi" ]; then
        source_arg="${script_dir}/chezmoi"
    else
        source_arg="${DOTFILES_REPO_URL:-$DEFAULT_REPO_URL}"
    fi
fi

# A URL is a repo positional; anything else is a local --source dir.
set -- init --apply
case "$source_arg" in
    *://*)
        set -- "$@" "$source_arg"
        ;;
    *)
        if [ ! -d "$source_arg" ]; then
            echo "error: source '${source_arg}' is not a directory" >&2
            exit 1
        fi
        set -- "$@" "--source=${source_arg}"
        ;;
esac

echo "Running 'chezmoi $*'" >&2
# exec: replace current process with chezmoi
exec "$chezmoi" "$@"
