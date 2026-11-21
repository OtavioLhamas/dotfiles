#!/usr/bin/env bash
# windows.sh — Windows 11 QEMU lane lifecycle, SSH transport, and bake.
# Sourced by test/run.sh and test/images/windows/build.sh.

WINDOWS_PORT=2333
WINDOWS_TARGET_USER="${WINDOWS_TARGET_USER:-provision}"
WINDOWS_BAKE_TIMEOUT="${WINDOWS_BAKE_TIMEOUT:-5400}"
WINDOWS_SSH_WAIT_TIMEOUT="${WINDOWS_SSH_WAIT_TIMEOUT:-600}"

windows_workdir() { vm_workdir "$1"; }
windows_golden_path() { qemu_golden_path "$1"; }

# windows_port_free <port> — whether that SSH port can be bound. QEMU's own
# "Could not set up host forwarding rule" is otherwise easy to confuse with a
# KVM/firmware failure. Defaults to the pinned WINDOWS_PORT.
windows_port_free() {
    local port="${1:-$WINDOWS_PORT}"
    if command -v ss >/dev/null 2>&1; then
        ! ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .
    else
        python3 - "$port" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    raise SystemExit(1)
finally:
    s.close()
PY
    fi
}

windows_ssh_cmd() {
    local port="$1"
    shift
    local opts
    ssh_opts opts
    ssh -p "$port" "${opts[@]}" "$WINDOWS_TARGET_USER@127.0.0.1" "$@"
}

# Run PowerShell over the default cmd.exe SSH shell without another shell-quote
# layer. powershell.exe -EncodedCommand consumes UTF-16LE base64.
windows_ssh_ps() {
    local port="$1" script="$2" encoded
    local opts
    ssh_opts opts
    # Progress records are serialized as CLIXML over a redirected SSH session;
    # keep them out of the stage logs.
    script="\$ProgressPreference='SilentlyContinue';$script"
    encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)" || return 1
    ssh -p "$port" "${opts[@]}" "$WINDOWS_TARGET_USER@127.0.0.1" \
        "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
}

# windows_wait_for <timeout-seconds> <probe...> — poll a probe against the wall
# clock. Counting sleeps alone is wrong: a probe that blocks (e.g. ssh waiting on
# a port that accepts TCP but never speaks SSH) takes far longer than its sleep.
windows_wait_for() {
    local timeout="$1" deadline
    shift
    deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    return 1
}

# Single bounded SSH probes: `timeout` caps each attempt even when ssh stalls
# after the TCP handshake (ConnectTimeout does not cover the SSH banner).
windows_ssh_probe() {
    local port="$1" opts
    ssh_opts opts
    timeout 20 ssh -p "$port" "${opts[@]}" "$WINDOWS_TARGET_USER@127.0.0.1" 'cmd.exe /c exit 0'
}

windows_provision_probe() {
    local port="$1" opts
    ssh_opts opts
    timeout 60 ssh -p "$port" "${opts[@]}" "$WINDOWS_TARGET_USER@127.0.0.1" \
        "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $(printf '%s' "if (Test-Path 'C:\\provision-done') { exit 0 } else { exit 1 }" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"
}

windows_ssh_wait() {
    windows_wait_for "${2:-$WINDOWS_SSH_WAIT_TIMEOUT}" windows_ssh_probe "$1"
}

windows_wait_provision_done() {
    windows_wait_for "${2:-$WINDOWS_BAKE_TIMEOUT}" windows_provision_probe "$1"
}

windows_guest_alive() { [ -n "$(qemu_pid "$1")" ]; }

# Bake waits also stop as soon as the guest powers itself off. provision.ps1
# powers off on failure, so a broken golden fails in minutes rather than sitting
# out the whole timeout. Returns 0 = ready, 1 = timeout, 2 = guest powered off.
windows_wait_ssh_or_off() {
    local name="$1" port="$2" timeout="$3" deadline
    deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        windows_ssh_probe "$port" && return 0
        windows_guest_alive "$name" || return 2
        sleep 5
    done
    return 1
}

windows_wait_provision_or_off() {
    local name="$1" port="$2" timeout="$3" deadline
    deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        windows_provision_probe "$port" && return 0
        windows_guest_alive "$name" || return 2
        sleep 5
    done
    return 1
}

# Sync the checkout (including .git/submodules) with Windows 11's bundled
# bsdtar. tar.exe consumes the archive directly from stdin.
windows_target_sync() {
    local port="$1" src="$2"
    local script='$dest=Join-Path $env:USERPROFILE ".local\share\chezmoi"; if(Test-Path $dest){Remove-Item -LiteralPath $dest -Recurse -Force}; New-Item -ItemType Directory -Path $dest -Force | Out-Null; & tar.exe -xf - -C $dest; if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}'
    local encoded opts
    encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)" || return 1
    ssh_opts opts
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
        | ssh -p "$port" "${opts[@]}" "$WINDOWS_TARGET_USER@127.0.0.1" \
            "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
}

windows_tmp_root() {
    local root="${DOTFILES_TEST_TPM_TMP_DIR:-/tmp/opencode}"
    if ! mkdir -p "$root" 2>/dev/null || [ ! -w "$root" ]; then root="/tmp"; fi
    printf '%s' "$root"
}

windows_swtpm_start() {
    local name="$1" workdir socket_dir pid waited=0
    workdir="$(windows_workdir "$name")"
    mkdir -p "$workdir"
    chmod 700 "$workdir"
    socket_dir="$(mktemp -d "$(windows_tmp_root)/dotfiles-test-tpm.XXXXXX")" || return 1
    mkdir -p "$socket_dir/tpm-state"
    chmod 700 "$socket_dir" "$socket_dir/tpm-state"
    printf '%s\n' "$socket_dir" >"$workdir/swtpm-socket-dir"
    setsid swtpm socket --tpm2 --tpmstate "dir=$socket_dir/tpm-state" \
        --ctrl "type=unixio,path=$socket_dir/swtpm.sock" \
        >"$workdir/swtpm.log" 2>&1 </dev/null &
    pid=$!
    printf '%s\n' "$pid" >"$workdir/swtpm.pid"
    while [ "$waited" -lt 20 ]; do
        [ -S "$socket_dir/swtpm.sock" ] && return 0
        if ! kill -0 "$pid" 2>/dev/null; then
            log_error "swtpm exited during startup; see $workdir/swtpm.log"
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    log_error "swtpm socket did not appear: $socket_dir/swtpm.sock"
    return 1
}

windows_swtpm_stop() {
    local workdir pid socket_dir waited=0
    workdir="$(windows_workdir "$1")"
    pid="$(cat "$workdir/swtpm.pid" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        while [ "$waited" -lt 5 ] && kill -0 "$pid" 2>/dev/null; do
            sleep 1
            waited=$((waited + 1))
        done
        kill -9 "$pid" 2>/dev/null || true
    fi
    socket_dir="$(cat "$workdir/swtpm-socket-dir" 2>/dev/null || true)"
    [ -n "$socket_dir" ] && rm -rf -- "$socket_dir"
    rm -f "$workdir/swtpm.pid" "$workdir/swtpm-socket-dir"
}

windows_qemu_start() {
    local name="$1" overlay="$2" port="$3" serial="$4" code="$5" vars="$6"
    local tpm_socket="$7" installer_iso="${8:-}" unattended_usb="${9:-}"
    local workdir smp mem disk
    workdir="$(windows_workdir "$name")"
    mkdir -p "$workdir" "$(dirname "$serial")"
    read -r smp mem disk <<<"$(qemu_sizing windows-11)"
    local -a cmd=(
        qemu-system-x86_64
        -machine pc,accel=kvm
        -cpu host
        -smp "$smp" -m "$mem"
        -drive "file=$overlay,if=ide,format=qcow2"
        -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$port-:22"
        -device e1000,netdev=n0
        -chardev "socket,id=chrtpm,path=$tpm_socket"
        -tpmdev emulator,id=tpm0,chardev=chrtpm
        -device tpm-tis,tpmdev=tpm0
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=$code"
        -drive "if=pflash,format=raw,unit=1,file=$vars"
    )
    if [ -n "$installer_iso" ]; then
        cmd+=(
            -drive "file=$installer_iso,if=ide,media=cdrom,readonly=on"
            -usb
            -drive "if=none,id=usbauto,format=raw,file=$unattended_usb"
            # removable=on is required: QEMU's usb-storage defaults to a fixed
            # disk, and Windows Setup only auto-searches removable media for
            # autounattend.xml, so without this the answer file is ignored.
            -device usb-storage,drive=usbauto,removable=on
            -boot order=d
        )
    fi
    cmd+=(
        -display none -serial "file:$serial"
        -monitor "unix:$workdir/monitor.sock,server,nowait"
        -pidfile "$workdir/qemu.pid"
        -daemonize
    )
    "${cmd[@]}" || { log_error "QEMU failed to start (KVM, OVMF, or TPM issue)"; return 1; }
}

windows_copy_bake_artifacts() {
    local image="$1" name="$2" latest result_dir
    result_dir="$(log_result_dir "$name")"
    mkdir -p "$result_dir"
    latest="$(find "$DOTFILES_TEST_RUNNER_DIR/logs" -maxdepth 1 -type d \
        -name "bake-$image-*" -print 2>/dev/null | sort | tail -1)"
    [ -n "$latest" ] || return 0
    [ -f "$latest/bake.log" ] && cp "$latest/bake.log" "$result_dir/bake.log"
    [ -f "$latest/serial.log" ] && cp "$latest/serial.log" "$result_dir/bake-serial.log"
}

# windows_monitor_send <monitor-socket> <hmp-command> — one QEMU human-monitor
# command over the unix socket (retries until QEMU has created it).
windows_monitor_send() {
    local monitor="$1" command="$2"
    python3 - "$monitor" "$command" <<'PY'
import socket
import sys
import time

path, command = sys.argv[1], sys.argv[2]
for _ in range(30):
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(path)
        client.settimeout(1)
        try:
            client.recv(1024)
        except TimeoutError:
            pass
        client.sendall(command.encode() + b"\n")
        time.sleep(1)
        client.close()
        raise SystemExit(0)
    except (FileNotFoundError, ConnectionRefusedError):
        time.sleep(1)
raise SystemExit(f"QEMU monitor did not appear: {path}")
PY
}

windows_send_space() {
    windows_monitor_send "$1" "sendkey spc"
}

# windows_screendump <monitor-socket> <out-base> — the guest's screen (Setup
# draws to the virtual display, not the serial port) as <out-base>.png when
# ImageMagick is available, else <out-base>.ppm.
windows_screendump() {
    local monitor="$1" base="$2"
    windows_monitor_send "$monitor" "screendump $base.ppm" || return 1
    if command -v convert >/dev/null 2>&1 && convert "$base.ppm" "$base.png" 2>/dev/null; then
        rm -f "$base.ppm"
    fi
}

windows_qemu_stop() {
    local name="$1" keep="${2:-0}"
    qemu_stop "$name" 1
    windows_swtpm_stop "$name"
    if [ "$keep" -ne 1 ]; then rm -rf -- "$(windows_workdir "$name")"; fi
}

target_windows_up() {
    local image="$1" name="$2" port="$3" workdir serial overlay ovmf code vars tpm_socket
    if ! windows_port_free "$port"; then
        log_error "TCP port $port is already in use; stop the other Windows VM/test first"
        return 1
    fi
    windows_copy_bake_artifacts "$image" "$name"
    if [ ! -f "$(windows_golden_path "$image")" ]; then
        log_error "Windows golden missing: $(windows_golden_path "$image")"
        log_error "bake it with: ./test/run.sh images bake $image"
        return 1
    fi
    workdir="$(windows_workdir "$name")"
    rm -rf -- "$workdir"
    mkdir -p "$workdir"
    chmod 700 "$workdir"
    serial="$(log_result_dir "$name")/serial.log"
    ovmf="$(qemu_ovmf_pair)" || { log_error "no OVMF firmware pair found"; return 1; }
    code="${ovmf%%$'\t'*}"
    vars="${ovmf#*$'\t'}"
    cp "$vars" "$workdir/vars.fd" || return 1
    overlay="$workdir/disk.qcow2"
    qemu_create_overlay "$image" "$overlay" || return 1
    windows_swtpm_start "$name" || return 1
    tpm_socket="$(cat "$workdir/swtpm-socket-dir")/swtpm.sock"
    log_info "booting Windows VM $name (SSH $port, fresh disk/EFI/TPM state)"
    windows_qemu_start "$name" "$overlay" "$port" "$serial" "$code" "$workdir/vars.fd" "$tpm_socket" || {
        windows_qemu_stop "$name" 1
        return 1
    }
    if ! windows_ssh_wait "$port" "$WINDOWS_SSH_WAIT_TIMEOUT"; then
        log_error "Windows SSH did not become ready within ${WINDOWS_SSH_WAIT_TIMEOUT}s"
        log_error "serial log: $serial"
        windows_qemu_stop "$name" 1
        return 1
    fi
}

target_windows_down() { windows_qemu_stop "$1"; }

# --fresh explicitly replaces any Windows target left alive by --keep/--reuse.
# Only one Windows target can run at a time, so a kept one must be released
# (along with its port) before another can boot.
windows_discard_kept_targets() {
    local descriptor lane name port
    while IFS= read -r descriptor; do
        [ -f "$descriptor" ] || continue
        lane="$(yq -p=json -r '.lane // ""' "$descriptor" 2>/dev/null || true)"
        [ "$lane" = "windows" ] || continue
        name="$(yq -p=json -r '.cname // ""' "$descriptor" 2>/dev/null || true)"
        [ -n "$name" ] || continue
        port="$(yq -p=json -r '.port // ""' "$descriptor" 2>/dev/null || true)"
        log_info "fresh Windows run: stopping kept target $name"
        target_windows_down "$name"
        [ -n "$port" ] && ports_release "$port"
        rm -f -- "$descriptor"
    done < <(find "$DOTFILES_TEST_RUNNER_DIR/logs" -type f -name 'kept-*.json' -print 2>/dev/null)
}

windows_images_bake() {
    local image="$1" iso="$2" bake_id logdir
    bake_id="$(date +%Y%m%d-%H%M%S)-$$"
    logdir="$DOTFILES_TEST_RUNNER_DIR/logs/bake-$image-$bake_id"
    mkdir -p "$logdir"
    DOTFILES_TEST_WINDOWS_BAKE_ID="$bake_id" \
    DOTFILES_TEST_WINDOWS_BAKE_LOG="$logdir/bake.log" \
        "$DOTFILES_TEST_RUNNER_DIR/images/windows/build.sh" "$image" "$iso" "$bake_id" \
        2>&1 | tee "$logdir/bake.log"
}

# windows_bake_cleanup <build-dir> — remove host-side bake media. Both the
# rendered autounattend.xml and the USB image contain the test account
# password, so they must not survive a completed or failed bake. (The golden
# and the VM workdir are managed separately.)
windows_bake_cleanup() {
    local build_dir="$1"
    [ -n "$build_dir" ] || return 0
    rm -rf -- "$build_dir/media" "$build_dir/unattended-usb.img"
}

# windows_record_screens <monitor> <dir> [interval] [count] — periodically
# capture the guest screen while a bake runs. Setup draws to the virtual
# display, so a timed-out bake otherwise leaves no evidence of where it stopped.
windows_record_screens() {
    local monitor="$1" dir="$2" interval="${3:-120}" count="${4:-20}" i=1
    mkdir -p "$dir"
    while [ "$i" -le "$count" ]; do
        sleep "$interval"
        [ -S "$monitor" ] || continue
        windows_screendump "$monitor" "$dir/screen-$(printf '%02d' "$i")" >/dev/null 2>&1 || true
        i=$((i + 1))
    done
}

windows_images_bake_impl() {
    local image="$1" iso="$2" bake_id="$3" name workdir build_dir media_dir usb_image
    local dest serial ovmf code vars overlay smp mem disk password_file mode owner image_name iso_env screens_pid=""
    local port="${4:-$WINDOWS_PORT}"
    image="${image:-windows-11}"
    [ "$image" = "windows-11" ] || { log_error "unsupported Windows image: $image"; return 2; }
    iso_env="$(yq -r ".images[\"$image\"].iso_env // \"DOTFILES_TEST_WINDOWS_ISO\"" "$(matrix_file)")"
    [ -n "$iso" ] || iso="${!iso_env:-}"
    image_name="$(yq -r ".images[\"$image\"].image_name // \"Windows 11 Pro\"" "$(matrix_file)")"
    export DOTFILES_TEST_WINDOWS_IMAGE_NAME="${DOTFILES_TEST_WINDOWS_IMAGE_NAME:-$image_name}"
    [ -n "$iso" ] && [ -f "$iso" ] || {
        log_error "provide the licensed Windows ISO with --iso or DOTFILES_TEST_WINDOWS_ISO"
        return 1
    }
    iso="$(cd "$(dirname "$iso")" && pwd -P)/$(basename "$iso")"
    password_file="${DOTFILES_TEST_BECOME_FILE:-}"
    [ -f "$password_file" ] || {
        log_error "DOTFILES_TEST_BECOME_FILE must name the Windows test-user password (mode 600)"
        return 1
    }
    mode="$(stat -c '%a' "$password_file")"
    owner="$(stat -c '%u' "$password_file")"
    if (( (8#$mode & 077) != 0 )) || [ "$owner" != "$(id -u)" ]; then
        log_error "password file must be owned by the current user and have no group/other permissions"
        return 1
    fi
    local tool
    for tool in qemu-system-x86_64 qemu-img swtpm python3 iconv base64 sfdisk mkfs.vfat mcopy mdir; do
        command -v "$tool" >/dev/null 2>&1 || { log_error "missing bake prerequisite: $tool"; return 1; }
    done
    [ -e /dev/kvm ] || { log_error "KVM is unavailable (/dev/kvm missing)"; return 1; }
    if ! windows_port_free "$port"; then
        log_error "TCP port $port is already in use; stop the other Windows VM/test first"
        return 1
    fi
    ovmf="$(qemu_ovmf_pair)" || { log_error "no OVMF firmware pair found"; return 1; }
    code="${ovmf%%$'\t'*}"
    vars="${ovmf#*$'\t'}"

    name="bake-$image-$bake_id"
    workdir="$(windows_workdir "$name")"
    build_dir="$DOTFILES_TEST_REPO_ROOT/test/images/windows/build/$bake_id"
    media_dir="$build_dir/media"
    usb_image="$build_dir/unattended-usb.img"
    # Remove password-bearing media on every exit path (success or failure).
    trap 'windows_bake_cleanup "$build_dir"' RETURN
    if [ -n "${DOTFILES_TEST_WINDOWS_BAKE_LOG:-}" ]; then
        serial="${DOTFILES_TEST_WINDOWS_BAKE_LOG%/bake.log}/serial.log"
    else
        serial="$workdir/serial.log"
        DOTFILES_TEST_WINDOWS_BAKE_LOG="$workdir/bake.log"
    fi
    mkdir -p "$workdir" "$media_dir" "$(dirname "$serial")"
    chmod 700 "$workdir" "$build_dir" "$media_dir"
    log_info "preparing local Windows 11 bake from $iso"

    python3 "$DOTFILES_TEST_REPO_ROOT/test/images/windows/prepare-unattend.py" \
        --source "$DOTFILES_TEST_REPO_ROOT/test/images/windows/autounattend/autounattend.xml" \
        --password-file "$password_file" \
        --public-key-file "$(ssh_key).pub" \
        --provision-template "$DOTFILES_TEST_REPO_ROOT/test/images/windows/autounattend/provision.ps1" \
        --out-dir "$media_dir/unattend" || return 1
    chmod 700 "$media_dir/unattend"
    # Windows Setup only mounts removable media that carries a partition table:
    # a bare FAT filesystem ("superfloppy") appears as an unpartitioned disk, so
    # autounattend.xml is never seen. Write an MBR with one FAT32 partition at
    # 1 MiB, format it separately, then splice it in.
    truncate -s 64M "$usb_image"
    printf 'label: dos\nstart=2048, type=c\n' | sfdisk -q "$usb_image" || return 1
    truncate -s 63M "$media_dir/usb-part.img"
    mkfs.vfat -F 32 -n DOTFILES "$media_dir/usb-part.img" >/dev/null || return 1
    dd if="$media_dir/usb-part.img" of="$usb_image" bs=1M seek=1 conv=notrunc status=none || return 1
    rm -f "$media_dir/usb-part.img"
    local usb_part="$usb_image@@1048576"
    MTOOLS_SKIP_CHECK=1 mcopy -i "$usb_part" "$media_dir/unattend/autounattend.xml" ::/autounattend.xml || return 1
    MTOOLS_SKIP_CHECK=1 mcopy -i "$usb_part" "$media_dir/unattend/provision.ps1" ::/provision.ps1 || return 1
    chmod 600 "$usb_image"
    MTOOLS_SKIP_CHECK=1 mdir -i "$usb_part" :: >/dev/null || { log_error "unable to verify unattended USB contents"; return 1; }

    read -r smp mem disk <<<"$(qemu_sizing windows-11)"
    overlay="$workdir/disk.qcow2"
    qemu-img create -f qcow2 "$overlay" "$disk" >/dev/null || return 1
    cp "$vars" "$workdir/vars.fd" || return 1
    windows_swtpm_start "$name" || return 1
    local tpm_socket
    tpm_socket="$(cat "$workdir/swtpm-socket-dir")/swtpm.sock"
    log_step "baking $image (unattended Windows Setup; timeout ${WINDOWS_BAKE_TIMEOUT}s)"
    windows_qemu_start "$name" "$overlay" "$port" "$serial" \
        "$code" "$workdir/vars.fd" "$tpm_socket" "$iso" "$usb_image" || {
        windows_qemu_stop "$name" 1
        return 1
    }
    sleep 5
    windows_send_space "$workdir/monitor.sock" || log_warn "could not send the DVD boot key; Setup may continue after timeout"
    # Capture the guest screen every two minutes (Setup's only progress output).
    windows_record_screens "$workdir/monitor.sock" "$(dirname "$serial")/screens" 120 45 &
    screens_pid=$!
    trap 'windows_bake_cleanup "$build_dir"; kill "$screens_pid" 2>/dev/null' RETURN
    windows_wait_ssh_or_off "$name" "$port" "$WINDOWS_BAKE_TIMEOUT"
    local wait_rc=$?
    if [ "$wait_rc" -ne 0 ]; then
        if [ "$wait_rc" -eq 2 ]; then
            log_error "guest powered off before SSH was available; see C:\\provision-failed.txt and C:\\provision.log on the kept disk"
        else
            log_error "unattended install did not expose SSH within ${WINDOWS_BAKE_TIMEOUT}s"
            log_error "serial log: $serial (Setup draws to the screen; screenshots in $(dirname "$serial")/screens)"
        fi
        windows_guest_alive "$name" && windows_screendump "$workdir/monitor.sock" "$(dirname "$serial")/screen-timeout" || true
        windows_qemu_stop "$name" 1
        return 1
    fi
    if [ -n "$screens_pid" ]; then
        kill "$screens_pid" 2>/dev/null || true
        wait "$screens_pid" 2>/dev/null || true
        screens_pid=""
    fi
    windows_wait_provision_or_off "$name" "$port" "$WINDOWS_BAKE_TIMEOUT"
    wait_rc=$?
    if [ "$wait_rc" -ne 0 ]; then
        if [ "$wait_rc" -eq 2 ]; then
            log_error "guest powered off while provisioning; see C:\\provision-failed.txt and C:\\provision.log on the kept disk"
        else
            log_error "provision.ps1 did not create C:\\provision-done within ${WINDOWS_BAKE_TIMEOUT}s"
        fi
        log_error "serial log: $serial"
        windows_guest_alive "$name" && windows_screendump "$workdir/monitor.sock" "$(dirname "$serial")/screen-timeout" || true
        windows_qemu_stop "$name" 1
        return 1
    fi

    local verify_ps
    verify_ps="\$ErrorActionPreference='Stop'; if(-not (Test-Path 'C:\\provision-done')){throw 'provision-done flag is missing'}; & cmd.exe /c 'net session' *>\$null; if(\$LASTEXITCODE -ne 0){throw 'net session failed; SSH token is not elevated'}; \$sshd=Get-CimInstance Win32_Service -Filter \"Name='sshd'\"; if(-not \$sshd -or \$sshd.StartMode -ne 'Auto'){throw 'sshd is not configured for automatic startup'}; if(-not (Test-Path 'C:\\Program Files\\Python312\\python.exe')){throw 'expected Python 3.12 interpreter is missing'}; if(-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)){throw 'PowerShell 7 (pwsh) is missing'}; \$rule=Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue; if(-not \$rule -or \$rule.Profile -notmatch 'Any'){throw 'OpenSSH firewall rule does not cover all profiles'}; 'Windows bake checks passed.'"
    if ! windows_ssh_ps "$port" "$verify_ps"; then
        log_error "post-bake verification failed; leaving VM state under $workdir"
        windows_qemu_stop "$name" 1
        return 1
    fi
    log_info "shutdown after bake verification"
    windows_ssh_ps "$port" 'Stop-Computer -Force' >/dev/null 2>&1 || true
    if ! qemu_wait_exit "$name" "$WINDOWS_SSH_WAIT_TIMEOUT"; then log_warn "guest did not power off cleanly"; fi
    windows_qemu_stop "$name" 1

    dest="$(windows_golden_path "$image")"
    mkdir -p "$(dirname "$dest")"
    if ! qemu-img convert -O qcow2 "$overlay" "$dest.part"; then
        rm -f "$dest.part"
        log_error "could not promote the installed disk to $dest"
        return 1
    fi
    mv -f "$dest.part" "$dest"
    chmod 600 "$dest"
    rm -f "$overlay" "$workdir/vars.fd"
    rm -rf -- "$workdir/unattended" "$media_dir"
    log_info "baked $image ($(du -h "$dest" | cut -f1)); artifacts: $serial and $DOTFILES_TEST_WINDOWS_BAKE_LOG"
}
