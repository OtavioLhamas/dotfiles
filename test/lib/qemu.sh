#!/usr/bin/env bash
# qemu.sh — raw QEMU lifecycle for the VM lane (Phase C).
#
# Every run boots a copy-on-write overlay on a pristine golden plus a private
# OVMF vars copy: two sequential runs start from byte-identical state, so each
# test run is a fresh machine (floor, not ceiling — nothing is reconciled).
#
# Goldens live in $GOLDEN_DIR (gitignored; DOTFILES_TEST_GOLDEN_DIR overrides
# because multi-GB qcow2s often don't fit on / — see docs/vm-iso-workflow.md).
#
# Sourced by test/run.sh.

GOLDEN_DIR="${DOTFILES_TEST_GOLDEN_DIR:-$DOTFILES_TEST_RUNNER_DIR/images/golden}"

# First boot includes cloud-init + package installs; 300s default per plan.
VM_SSH_WAIT_TIMEOUT="${VM_SSH_WAIT_TIMEOUT:-300}"
# DE package downloads dominate a bake (~15-25 min); 40 min ceiling.
VM_BAKE_TIMEOUT="${VM_BAKE_TIMEOUT:-2400}"

# Run state (overlay + OVMF vars + seed). Defaults under the repo (where
# test/run/vm is typically a symlink to a big disk); DOTFILES_TEST_VM_DIR
# overrides with an explicit external directory.
vm_workdir() { printf '%s/%s' "${DOTFILES_TEST_VM_DIR:-$DOTFILES_TEST_RUNNER_DIR/run/vm}" "$1"; }

# qemu_golden_path <image-key>
qemu_golden_path() { printf '%s/%s.qcow2' "${GOLDEN_DIR%/}" "$1"; }

# qemu_ovmf_pair — print "<CODE>\t<VARS>" for the first resolvable firmware
# pair. Paths differ per distro layout; resolved here (doctor-host probes the
# same list), never hardcoded at call sites.
qemu_ovmf_pair() {
    local code vars
    for code in \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/qemu/OVMF_CODE.fd; do
        [ -f "$code" ] || continue
        vars="${code/CODE/VARS}"
        if [ -f "$vars" ]; then
            printf '%s\t%s\n' "$code" "$vars"
            return 0
        fi
    done
    return 1
}

# qemu_sizing <image-key> — print "<smp> <memory-MB> <disk>" from matrix.yaml
# (per-image decision, Phase C). Disk must be big enough for the Nix store +
# Home Manager on Linux VMs (~5-15 GiB); defaults 2 CPU / 4096 MB / 40G.
qemu_sizing() {
    local mf smp mem disk
    mf="$(matrix_file)"
    smp="$(yq -r ".images[\"$1\"].smp // 2" "$mf")"
    mem="$(yq -r ".images[\"$1\"].memory // 4096" "$mf")"
    disk="$(yq -r ".images[\"$1\"].disk // \"$VM_DISK_SIZE\"" "$mf")"
    printf '%s %s %s\n' "$smp" "$mem" "$disk"
}

# qemu_create_overlay <image-key> <overlay-path> [disk-size] — ~1s
# copy-on-write disk, resized to disk-size (default: the image's matrix disk)
# so cloud-init's growpart can expand the filesystem on first boot (stock
# cloud images ship with minimal 3-5 GiB partitions, too small for Nix +
# Home Manager).
VM_DISK_SIZE="${VM_DISK_SIZE:-40G}"

qemu_create_overlay() {
    local image="$1" overlay="$2" disk="${3:-}" golden fmt
    golden="$(qemu_golden_path "$image")"
    if [ ! -f "$golden" ]; then
        log_error "golden missing: $golden"
        log_error "fetch it first: ./test/run.sh images pull [--image <base>] (baked images: images bake <name>)"
        return 1
    fi
    golden="$(cd "$(dirname "$golden")" && pwd -P)/$(basename "$golden")"
    fmt="$(qemu-img info --output=json "$golden" | yq -r '.format // "qcow2"')"
    qemu-img create -f qcow2 -F "$fmt" -b "$golden" "$overlay" >/dev/null || return 1
    [ -n "$disk" ] || read -r _ _ disk <<<"$(qemu_sizing "$image")"
    if [ -n "$disk" ] && [ "$disk" != "0" ]; then
        qemu-img resize "$overlay" "$disk" >/dev/null || return 1
    fi
    return 0
}

# qemu_launch <name> <image-key> <port> <seed-iso> <serial-log> [base-image-key]
# Prepares a fresh workdir (overlay + OVMF vars copy), then starts QEMU
# daemonized. port="" skips hostfwd (bake keeps NAT only, for downloads).
# base-image-key defaults to image-key; `images bake` passes the stock base so
# the bake overlay is created on it (sizing still comes from image-key).
qemu_launch() {
    local name="$1" image="$2" port="$3" seed="$4" serial="$5" base="${6:-$2}"
    local workdir ovmf code vars overlay smp mem disk rc
    workdir="$(vm_workdir "$name")"
    mkdir -p "$workdir" "$(dirname "$serial")"

    if ! ovmf="$(qemu_ovmf_pair)"; then
        log_error "no OVMF firmware found (install ovmf/edk2-ovmf; doctor-host probes paths)"
        return 1
    fi
    code="${ovmf%%$'\t'*}"
    vars="${ovmf#*$'\t'}"
    cp "$vars" "$workdir/vars.fd" || return 1

    read -r smp mem disk <<<"$(qemu_sizing "$image")"
    overlay="$workdir/disk.qcow2"
    qemu_create_overlay "$base" "$overlay" "$disk" || return 1

    local -a cmd=(
        qemu-system-x86_64
        -machine q35,accel=kvm
        -cpu host
        -smp "$smp" -m "$mem"
        -drive "file=$overlay,if=virtio,format=qcow2"
        -drive "file=$seed,if=virtio,media=cdrom,readonly=on"
    )
    if [ -n "$port" ]; then
        cmd+=(-netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$port-:22")
    else
        cmd+=(-netdev "user,id=n0")
    fi
    cmd+=(
        -device virtio-net-pci,netdev=n0
        -display none -serial "file:$serial" -monitor none
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=$code"
        -drive "if=pflash,format=raw,unit=1,file=$workdir/vars.fd"
        -pidfile "$workdir/qemu.pid"
        -daemonize
    )
    if ! "${cmd[@]}"; then
        log_error "qemu failed to start (is /dev/kvm usable? see doctor-host)"
        return 1
    fi
    return 0
}

# qemu_pid <name> — the live QEMU pid, or empty.
qemu_pid() {
    local pidfile="$(vm_workdir "$1")/qemu.pid" pid
    [ -f "$pidfile" ] || return 0
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        printf '%s' "$pid"
    fi
}

# qemu_wait_exit <name> [timeout] — wait for the guest poweroff to end the
# QEMU process (bake completion signal). Returns 1 on timeout.
qemu_wait_exit() {
    local name="$1" timeout="${2:-$VM_BAKE_TIMEOUT}" waited=0
    while [ "$waited" -lt "$timeout" ]; do
        if [ -z "$(qemu_pid "$name")" ]; then
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

# qemu_stop <name> [keep-workdir] — terminate QEMU via its pidfile; remove the
# overlay/vars/seed workdir unless keep-workdir=1 (boot failure / --keep
# debugging — the workdir is cheap to inspect and wiped on the next boot).
qemu_stop() {
    local name="$1" keep="${2:-0}" pid waited=0
    pid="$(qemu_pid "$name")"
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        while [ "$waited" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
            sleep 1
            waited=$((waited + 1))
        done
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$(vm_workdir "$name")/qemu.pid"
    if [ "$keep" -ne 1 ]; then
        rm -rf "$(vm_workdir "$name")"
    fi
    return 0
}
