#!/usr/bin/env bash
# Standalone Windows golden bake entrypoint. Normally called by test/run.sh.
set -uo pipefail

SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RUNNER_DIR="$(cd -P -- "$SCRIPT_DIR/../.." && pwd -P)"
REPO_ROOT="$(cd -P -- "$RUNNER_DIR/.." && pwd -P)"
export DOTFILES_TEST_REPO_ROOT="${DOTFILES_TEST_REPO_ROOT:-$REPO_ROOT}"
export DOTFILES_TEST_RUNNER_DIR="${DOTFILES_TEST_RUNNER_DIR:-$RUNNER_DIR}"

source "$RUNNER_DIR/lib/log.sh"
source "$RUNNER_DIR/lib/matrix.sh"
source "$RUNNER_DIR/lib/ports.sh"
source "$RUNNER_DIR/lib/ssh.sh"
source "$RUNNER_DIR/lib/qemu.sh"
source "$RUNNER_DIR/lib/windows.sh"

image="${1:-windows-11}"
iso="${2:-${DOTFILES_TEST_WINDOWS_ISO:-}}"
bake_id="${3:-$(date +%Y%m%d-%H%M%S)-$$}"
if [ -z "${DOTFILES_TEST_WINDOWS_BAKE_LOG:-}" ]; then
    mkdir -p "$DOTFILES_TEST_RUNNER_DIR/logs/bake-$image-$bake_id"
    DOTFILES_TEST_WINDOWS_BAKE_LOG="$DOTFILES_TEST_RUNNER_DIR/logs/bake-$image-$bake_id/bake.log"
fi
if ! windows_port="$(ports_windows_alloc)"; then
    exit 1
fi
build_dir="$DOTFILES_TEST_REPO_ROOT/test/images/windows/build/$bake_id"
# The build dir holds the rendered autounattend.xml (test password) and the USB
# image; remove it on every exit, including signals.
trap 'ports_release "$windows_port"; rm -rf -- "$build_dir"' EXIT
trap 'windows_qemu_stop "bake-$image-$bake_id" 1 2>/dev/null || true; exit 130' INT TERM
windows_images_bake_impl "$image" "$iso" "$bake_id" "$windows_port"
