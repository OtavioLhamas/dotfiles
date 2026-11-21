#!/usr/bin/env bash
# targets.sh — lane-agnostic target lifecycle (containers + QEMU VMs).
#
# A target is "a reachable SSH endpoint" (sudo on Linux, elevated token on
# Windows). The stages in
# stage_target.sh only speak SSH; this module owns boot/teardown/sync.
# Lane plug-in surface: a `case` arm each in target_up/target_down/
# target_sync — a lane provides target_<lane>_up + target_<lane> sync.
#
# Sourced by test/run.sh.

# Where a target keeps the repo. The config's read-source-state hook path is
# hardcoded as `.local/share/chezmoi/chezmoi/...`, so the repo must live at
# chezmoi's canonical source location, not an arbitrary directory.
TARGET_REPO="${TARGET_REPO:-/home/provision/.local/share/chezmoi}"
TARGET_HOME="${TARGET_HOME:-/home/provision}"

# target_image_tag <lane> <image-key>
target_image_tag() {
    local lane="$1" image="$2" mf
    mf="$(matrix_file)"
    case "$lane" in
        container) yq -r ".images[\"$image\"].tag" "$mf" ;;
        *) yq -r ".images[\"$image\"].tag // \"\"" "$mf" ;;
    esac
}

# target_up <lane> <image-key> <name> <port>
target_up() {
    local lane="$1"
    shift
    case "$lane" in
        container) target_container_up "$@" ;;
        vm) target_vm_up "$@" ;;
        windows) target_windows_up "$@" ;;
        *) log_error "target_up: unsupported lane: $lane"; return 1 ;;
    esac
}

# target_down <lane> <name> — terminate and discard run state. Never called
# for kept targets (--keep / --reuse leave the target running).
target_down() {
    local lane="$1" name="$2"
    case "$lane" in
        container) docker rm -f "$name" >/dev/null 2>&1 || true ;;
        vm) qemu_stop "$name" ;;
        windows) target_windows_down "$name" ;;
        *) log_error "target_down: unsupported lane: $lane"; return 1 ;;
    esac
}

# target_container_up <image-key> <name> <port>
target_container_up() {
    local image="$1" name="$2" port="$3"
    local tag
    tag="$(target_image_tag container "$image")"
    [ -n "$tag" ] && [ "$tag" != "null" ] || { log_error "no docker tag for image: $image"; return 1; }

    docker rm -f "$name" >/dev/null 2>&1 || true
    log_info "starting container $name from $tag (port $port)"
    docker run -d --privileged --cgroupns=host \
        --name "$name" -p "127.0.0.1:$port:22" "$tag" >/dev/null || return 1

    # Inject the harness public key (rotatable; never baked into the image).
    local pub waited=0
    pub="$(ssh_public_key)"
    while [ "$waited" -lt 60 ]; do
        if docker exec "$name" bash -c "
            mkdir -p /home/provision/.ssh &&
            printf '%s\n' '$pub' > /home/provision/.ssh/authorized_keys &&
            chown -R provision:provision /home/provision/.ssh &&
            chmod 700 /home/provision/.ssh &&
            chmod 600 /home/provision/.ssh/authorized_keys" 2>/dev/null; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    if ! ssh_wait "$port" 60; then
        log_error "SSH did not come up on port $port"
        docker logs "$name" 2>&1 | tail -20 >&2 || true
        return 1
    fi
    return 0
}

# target_sync <lane> <port> <src-dir> <dest-dir>
# Working tree transfer (submodules + .git included so `chezmoi init` takes
# its no-clone path). Containers tar-pipe; VMs prefer rsync (faster diffs,
# plan spec) and fall back to the identical tar-pipe when rsync is missing
# on either side.
target_sync() {
    local lane="$1" port="$2" src="$3" dest="$4"
    case "$lane" in
        vm) target_vm_sync "$port" "$src" "$dest" ;;
        windows) windows_target_sync "$port" "$src" ;;
        *) target_sync_tar "$port" "$src" "$dest" ;;
    esac
}

# target_sync_tar <port> <src-dir> <dest-dir>
target_sync_tar() {
    local port="$1" src="$2" dest="$3"
    tar -C "$src" -cf - \
        --exclude=test/logs \
        --exclude=test/run \
        --exclude=test/images/golden \
        --exclude=test/images/windows/build \
        --exclude='test/images/*.iso' \
        --exclude='test/images/windows/*.iso' \
        --exclude=key.txt \
        --exclude='*.age' \
        --exclude=.env \
        --exclude=.env.local \
        --exclude='.env.*.local' \
        --exclude='vault-password*' \
        --exclude='*.vault' . \
        | target_ssh_cmd_stdin "$port" "rm -rf '$dest' && mkdir -p '$dest' && tar -C '$dest' -xf -"
}

# target_vm_sync <port> <src-dir> <dest-dir> — rsync with tar-pipe fallback.
target_vm_sync() {
    local port="$1" src="$2" dest="$3"
    if command -v rsync >/dev/null 2>&1; then
        local opts e o
        ssh_opts opts
        e="ssh -p $port"
        for o in "${opts[@]}"; do
            e+=" $(printf '%q' "$o")"
        done
        # Ensure the destination parent exists (cloud-init creates
        # /home/provision but not the nested .local/share/chezmoi).
        target_ssh_cmd "$port" "mkdir -p '$dest'" || true
        if rsync -a --delete \
            --exclude test/logs \
            --exclude test/run \
            --exclude test/images/golden \
            --exclude test/images/windows/build \
            --exclude 'test/images/*.iso' \
            --exclude 'test/images/windows/*.iso' \
            --exclude key.txt \
            --exclude '*.age' \
            --exclude .env \
            --exclude .env.local \
            --exclude '.env.*.local' \
            --exclude 'vault-password*' \
            --exclude '*.vault' \
            -e "$e" "$src/" "$SSH_TARGET_USER@127.0.0.1:$dest/"; then
            return 0
        fi
        log_warn "rsync sync failed; falling back to tar-pipe"
    fi
    target_sync_tar "$port" "$src" "$dest"
}

# target_vm_up <image-key> <name> <port> — fresh overlay + NoCloud seed,
# daemonized QEMU, then wait for a real SSH handshake (hostfwd opens the port
# immediately, so a TCP probe would false-positive).
target_vm_up() {
    local image="$1" name="$2" port="$3"
    local workdir serial seed timeout
    workdir="$(vm_workdir "$name")"
    seed="$workdir/seed.iso"
    serial="$(log_result_dir "$name")/serial.log"
    timeout="${VM_SSH_WAIT_TIMEOUT:-300}"

    # Wipe any stale workdir from a previous run (overlay + vars + seed are
    # all per-run). Then create the seed before qemu_launch touches the dir.
    rm -rf "$workdir"
    cloudinit_seed_iso "$workdir" user-data.yaml.tmpl "SSH_PUBKEY=$(ssh_public_key)" || return 1

    log_info "booting vm $name from $(qemu_golden_path "$image") (port $port, smp/mem per matrix.yaml)"
    if ! qemu_launch "$name" "$image" "$port" "$seed" "$serial"; then
        qemu_stop "$name" 1
        return 1
    fi

    if ! ssh_wait "$port" "$timeout"; then
        log_error "SSH did not come up on port $port within ${timeout}s"
        log_error "serial log: $serial"
        tail -30 "$serial" >&2 2>/dev/null || true
        # Kill QEMU (so the port frees) but keep overlay/vars for inspection.
        qemu_stop "$name" 1
        return 1
    fi
    return 0
}
