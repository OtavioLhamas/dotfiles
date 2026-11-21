#!/usr/bin/env bash
# test/run.sh — non-interactive test-suite entrypoint.
#
# Commands: run | scenarios | doctor-host | images | report | cases
# Phase A implements: run --stage lint, scenarios, doctor-host.
#
# All commands are non-interactive and safe without a TTY.

set -uo pipefail

RUNNER_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P -- "$RUNNER_DIR/.." && pwd -P)"
export DOTFILES_TEST_REPO_ROOT="$REPO_ROOT"
export DOTFILES_TEST_RUNNER_DIR="$RUNNER_DIR"

# shellcheck source=lib/log.sh
source "$RUNNER_DIR/lib/log.sh"
# shellcheck source=lib/matrix.sh
source "$RUNNER_DIR/lib/matrix.sh"
# shellcheck source=lib/preseed.sh
source "$RUNNER_DIR/lib/preseed.sh"
# shellcheck source=lib/ports.sh
source "$RUNNER_DIR/lib/ports.sh"
# shellcheck source=lib/stage_lint.sh
source "$RUNNER_DIR/lib/stage_lint.sh"
# shellcheck source=lib/health-check.sh
source "$RUNNER_DIR/lib/health-check.sh"
# shellcheck source=lib/ssh.sh
source "$RUNNER_DIR/lib/ssh.sh"
# shellcheck source=lib/cloudinit.sh
source "$RUNNER_DIR/lib/cloudinit.sh"
# shellcheck source=lib/qemu.sh
source "$RUNNER_DIR/lib/qemu.sh"
# shellcheck source=lib/targets.sh
source "$RUNNER_DIR/lib/targets.sh"
# shellcheck source=lib/stage_target.sh
source "$RUNNER_DIR/lib/stage_target.sh"
# shellcheck source=lib/windows.sh
source "$RUNNER_DIR/lib/windows.sh"
# shellcheck source=lib/stage_windows.sh
source "$RUNNER_DIR/lib/stage_windows.sh"

usage() {
    cat <<'EOF'
Usage: test/run.sh <command> [flags]

Commands:
  run           Execute stages against resolved scenarios
  scenarios     List scenarios from matrix.yaml
  doctor-host   Report which lanes are usable on this machine
  images        Container/VM images: build | pull | bake | list | rm
  report        (Phase E) Render a run summary
  cases         (Phase F) Assertion cases

run flags (repeatable where marked *):
  --scenario <name>*         Named scenario from matrix.yaml
  --image <name>*            All scenarios on an image
  --distro <id>*             ubuntu | debian | fedora | cachyos | pop | windows-11
  --os <linux|windows>*      Filter by OS
  --lane <lint|container|vm|windows>*   Filter by lane
  --de <de>*                 gnome | cosmic | kde | niri | none      (override)
  --ds <wayland|x11|none>*   Display server override
  --form <desktop|laptop|server>*       Override
  --category <cat>*          Comma list or repeatable (override)
  --stage <list>             lint | doctor | dry-run | apply | verify | all  (default: lint)
  --fresh                    Discard/ignore any kept target (default)
  --reuse <run-id>           Attach to a target kept alive from a previous run
  --keep                     Do not tear down; print connection details on exit
  --parallel <n>             Max concurrent scenarios (default 1)
  --fail-fast                Stop on first unexpected failure
  --all                      Select every scenario
  --list                     Resolve and print targets; execute nothing
EOF
}

# csv <items...> — comma-join (empty for no items).
csv() {
    local IFS=,
    printf '%s' "$*"
}

# --- run --------------------------------------------------------------------

cmd_run() {
    local -a scen=() img=() distro=() osf=() lanef=() cats=()
    local stage="lint" list=0 parallel=1 fail_fast=0 all=0
    local ov_de="" ov_ds="" ov_ds_set=0 ov_form=""
    local _keep=0 _reuse="" _fresh=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --scenario) scen+=("${2:?--scenario needs a value}"); shift 2 ;;
            --image) img+=("${2:?--image needs a value}"); shift 2 ;;
            --distro) distro+=("${2:?--distro needs a value}"); shift 2 ;;
            --os) osf+=("${2:?--os needs a value}"); shift 2 ;;
            --lane) lanef+=("${2:?--lane needs a value}"); shift 2 ;;
            --de) ov_de="${2:?--de needs a value}"; shift 2 ;;
            --ds)
                ov_ds="${2:?--ds needs a value}"
                [ "$ov_ds" = "none" ] && ov_ds=""
                ov_ds_set=1
                shift 2
                ;;
            --form) ov_form="${2:?--form needs a value}"; shift 2 ;;
            --category) cats+=("${2:?--category needs a value}"); shift 2 ;;
            --stage) stage="${2:?--stage needs a value}"; shift 2 ;;
            --fresh) _fresh=1; shift ;;
            --reuse) _reuse="${2:?--reuse needs a value}"; shift 2 ;;
            --keep) _keep=1; shift ;;
            --parallel) parallel="${2:?--parallel needs a value}"; shift 2 ;;
            --fail-fast) fail_fast=1; shift ;;
            --list) list=1; shift ;;
            --all) all=1; shift ;;
            -h|--help) usage; return 0 ;;
            *) log_error "unknown flag: $1"; return 2 ;;
        esac
    done
    KEEP_TARGET="$_keep"
    # --reuse <run-id> attaches to a target kept by a previous run's --keep;
    # --fresh discards it. Reuse implies keep (the target must survive the
    # run), so run_target_record never tears an attached target down.
    REUSE_RUN=""
    if [ -n "$_reuse" ] && [ "$_fresh" -eq 0 ]; then
        REUSE_RUN="$_reuse"
        if [ ! -d "$RUNNER_DIR/logs/$_reuse" ]; then
            log_warn "--reuse: no such run $_reuse; targets will boot fresh"
            REUSE_RUN=""
        fi
    fi
    : "$all"

    local -a stages=()
    IFS=',' read -r -a stages <<<"$stage"
    local do_lint=0 do_doctor=0 do_dry=0 do_apply=0 do_verify=0 s
    for s in "${stages[@]}"; do
        case "$s" in
            lint) do_lint=1 ;;
            doctor) do_doctor=1 ;;
            dry-run) do_dry=1 ;;
            apply) do_apply=1 ;;
            verify) do_verify=1 ;;
            all) do_lint=1; do_doctor=1; do_dry=1; do_apply=1; do_verify=1 ;;
            *) log_error "unknown stage: $s"; return 2 ;;
        esac
    done
    local do_target=0
    if [ "$do_doctor" -eq 1 ] || [ "$do_dry" -eq 1 ] || [ "$do_apply" -eq 1 ] || [ "$do_verify" -eq 1 ]; then
        do_target=1
    fi
    if [ "$do_lint" -eq 0 ] && [ "$do_target" -eq 0 ]; then
        log_error "no runnable stage in: $stage"
        return 2
    fi

    matrix_validate || return 1

    local has_override=0
    if [ -n "$ov_de$ov_ds$ov_form" ] || [ "${#cats[@]}" -gt 0 ]; then
        has_override=1
    fi

    # Overrides for matrix_apply_overrides / matrix_synthesize (shell vars).
    OV_DE="$ov_de"
    OV_DS="$ov_ds"
    OV_DS_SET="$ov_ds_set"
    OV_FORM="$ov_form"
    OV_CATS="$(csv "${cats[@]}")"

    local -a records=()
    local line
    if [ "$has_override" -eq 1 ] && [ "${#scen[@]}" -eq 0 ]; then
        # Synthesize ephemeral scenario(s) from a base image.
        local -a bases=()
        if [ "${#img[@]}" -gt 0 ]; then
            bases=("${img[@]}")
        elif [ "${#distro[@]}" -gt 0 ]; then
            local d di
            for d in "${distro[@]}"; do
                di="$(matrix_default_image "$d")"
                [ -n "$di" ] && [ "$di" != "null" ] || { log_error "no default image for distro: $d"; return 2; }
                bases+=("$di")
            done
        else
            log_error "override flags need --image or --distro (or --scenario)"
            return 2
        fi
        while IFS= read -r line; do
            [ -n "$line" ] && records+=("$line")
        done < <(matrix_synthesize "${bases[@]}")
    else
        while IFS= read -r line; do
            [ -n "$line" ] && records+=("$line")
        done < <(
            F_SCEN_CSV="$(csv "${scen[@]}")" \
            F_IMG_CSV="$(csv "${img[@]}")" \
            F_DISTRO_CSV="$(csv "${distro[@]}")" \
            F_OS_CSV="$(csv "${osf[@]}")" \
            F_LANE_CSV="$(csv "${lanef[@]}")" \
                matrix_resolve
        )
        if [ "$has_override" -eq 1 ]; then
            local -a tmp=()
            local rec
            for rec in "${records[@]}"; do
                tmp+=("$(printf '%s' "$rec" | matrix_apply_overrides)")
            done
            records=("${tmp[@]}")
        fi
    fi

    if [ "${#records[@]}" -eq 0 ]; then
        log_error "no scenarios matched the given selectors"
        return 2
    fi

    if [ "$list" -eq 1 ]; then
        printf '%s%-40s %-18s %-6s %-7s %s%s\n' "$C_BOLD" "scenario" "image" "lane" "form" "categories/de/ds" "$C_RESET"
        local rec
        for rec in "${records[@]}"; do
            printf '%-40s %-18s %-6s %-7s %s\n' \
                "$(printf '%s' "$rec" | yq -p=json -r '.name')" \
                "$(printf '%s' "$rec" | yq -p=json -r '.image')" \
                "$(printf '%s' "$rec" | yq -p=json -r '.lane')" \
                "$(printf '%s' "$rec" | yq -p=json -r '.data.form_factor')" \
                "$(printf '%s' "$rec" | yq -p=json -r '[.data.categories|join("+"), .data.desktop_environment, (.data.display_server // "-")]|join("/")')"
        done
        return 0
    fi

    log_init_run "$stage"

    local rec name tf
    for rec in "${records[@]}"; do
        name="$(printf '%s' "$rec" | yq -p=json -r '.name')"
        tf="$(log_target_file "$name")"
        printf '%s\n' "$rec" >"$tf"
    done

    if [ "$do_lint" -eq 1 ]; then
        if [ "$parallel" -gt 1 ]; then
            log_info "lint: ${#records[@]} scenario(s), parallel=$parallel"
            find "$LOG_RUN_DIR/targets" -name '*.json' -print0 |
                xargs -0 -P "$parallel" -I{} "$RUNNER_DIR/run.sh" __lint-worker {}
        else
            for rec in "${records[@]}"; do
                name="$(printf '%s' "$rec" | yq -p=json -r '.name')"
                log_step "lint: $name"
                stage_lint_run "$rec" || true
                if [ "$fail_fast" -eq 1 ]; then
                    local st
                    st="$(yq -p=json -r '.status' "$(log_result_dir "$name")/lint.json" 2>/dev/null || true)"
                    [ "$st" = "fail" ] && { log_warn "--fail-fast: stopping"; break; }
                fi
            done
        fi

        # Run-level Nix flake validation (once), using the first scenario's config.
        preseed_write_config "$LOG_RUN_DIR/nix-chezmoi.yaml" "${records[0]}"
        stage_lint_nix_run "$LOG_RUN_DIR/nix-chezmoi.yaml" || true

        log_step "lint: Windows unattended renderer"
        run_one_stage "_windows-unattend" lint stage_lint_windows_unattend || true
    fi

    if [ "$do_target" -eq 1 ]; then
        for rec in "${records[@]}"; do
            if ! run_target_record "$rec" "$do_doctor" "$do_dry" "$do_apply" "$do_verify"; then
                if [ "$fail_fast" -eq 1 ]; then
                    log_warn "--fail-fast: stopping"
                    break
                fi
            fi
        done
    fi

    log_summary
}

# --- single-stage runner ----------------------------------------------------

# run_one_stage <name> <stage-name> <fn> [args...] — capture, record, return
# the stage's own status (0/1/2).
run_one_stage() {
    local name="$1" stage_name="$2" fn="$3"
    shift 3
    local rdir log start rc dur status detail
    rdir="$(log_result_dir "$name")"
    mkdir -p "$rdir"
    log="$rdir/$stage_name.log"
    start="$(date +%s)"
    if log_capture "$log" "$fn" "$@"; then rc=0; else rc=$?; fi
    dur=$(( $(date +%s) - start ))
    case "$rc" in
        0) status=pass; detail="" ;;
        2) status=skip; detail="skipped" ;;
        *)
            status=fail
            detail="$stage_name failed"
            log_info "--- $name/$stage_name failed (tail) ---"
            tail -15 "$log" 2>/dev/null || true
            ;;
    esac
    log_write_result "$name" "$stage_name" "$status" "$dur" "$detail" "$log"
    return "$rc"
}

# run_target_record <record> <doctor> <dry> <apply> <verify> — boot a target,
# run the requested stages in order, tear down. Returns 1 if any stage failed.
# With --reuse, attaches to a previously kept target (skips boot + sync);
# attached and --keep targets survive the run and get a kept-<name>.json
# descriptor for the next --reuse round-trip.
run_target_record() {
    local rec="$1" want_doctor="$2" want_dry="$3" want_apply="$4" want_verify="$5"
    local name lane rc=0
    name="$(record_get "$rec" '.name')"
    lane="$(record_get "$rec" '.lane')"

    case "$lane" in
        container | vm | windows) ;;
        *)
            log_warn "lane '$lane' target stages are not implemented yet; skipping $name"
            log_write_result "$name" "$LOG_STAGE" skip 0 "lane '$lane' not implemented" ""
            return 0
            ;;
    esac

    local port="" cname="" attached=0 kept
    if [ -n "${REUSE_RUN:-}" ]; then
        kept="$RUNNER_DIR/logs/$REUSE_RUN/kept-$name.json"
        if [ -f "$kept" ]; then
            port="$(yq -p=json -r '.port' "$kept")"
            cname="$(yq -p=json -r '.cname' "$kept")"
            attached=1
            log_step "$lane: $name reusing run $REUSE_RUN (port $port)"
            (set -o noclobber; : >"$(ports_dir)/$port.lock") 2>/dev/null || true
        else
            log_warn "--reuse: no kept target '$name' in run $REUSE_RUN; booting fresh"
        fi
    fi

    if [ "$attached" -eq 0 ]; then
        if [ "$lane" = "windows" ]; then
            cname="$name"
            # Port 2333 is pinned, so a non-reuse run starts fresh by closing
            # any Windows target previously left alive with --keep.
            windows_discard_kept_targets
            if ! port="$(ports_windows_alloc)"; then
                log_write_result "$name" "$LOG_STAGE" fail 0 "Windows port unavailable" ""
                return 1
            fi
            log_step "windows: $name (reserved port $port)"
        elif ! port="$(ports_alloc)"; then
            log_write_result "$name" "$LOG_STAGE" fail 0 "no free port" ""
            return 1
        elif [ "$lane" = "vm" ]; then
            cname="$name"
            log_step "vm: $name (port $port)"
        else
            cname="dotfiles-test-${LOG_RUN_ID}-${name}"
            log_step "container: $name (port $port)"
        fi

        if ! target_up "$lane" "$(record_get "$rec" '.image')" "$cname" "$port"; then
            log_write_result "$name" "$LOG_STAGE" fail 0 "target failed to start" ""
            ports_release "$port"
            return 1
        fi

        if [ "$lane" = "windows" ]; then
            log_info "syncing working tree to %USERPROFILE%\\.local\\share\\chezmoi"
        else
            log_info "syncing working tree to $TARGET_REPO"
        fi
        if ! target_sync "$lane" "$port" "$DOTFILES_TEST_REPO_ROOT" "$TARGET_REPO"; then
            log_write_result "$name" "$LOG_STAGE" fail 0 "working-tree sync failed" ""
            target_down "$lane" "$cname"
            ports_release "$port"
            return 1
        fi
    fi

    local dry_fn=stage_target_dry_run apply_fn=stage_target_apply verify_fn=stage_target_verify doctor_fn=stage_target_doctor
    if [ "$lane" = "windows" ]; then
        dry_fn=stage_windows_dry_run
        apply_fn=stage_windows_apply
        verify_fn=stage_windows_verify
        doctor_fn=stage_windows_doctor
    fi
    if [ "$want_dry" -eq 1 ]; then run_one_stage "$name" dry-run "$dry_fn" "$rec" "$port" || rc=1; fi
    local apply_failed=0
    if [ "$want_apply" -eq 1 ]; then
        if ! run_one_stage "$name" apply "$apply_fn" "$rec" "$port"; then
            rc=1
            apply_failed=1
        fi
    fi
    if [ "$want_verify" -eq 1 ]; then
        if [ "$apply_failed" -eq 1 ]; then
            # Idempotency is meaningless on a target whose first apply failed.
            log_warn "skipping verify: apply failed for $name"
            log_write_result "$name" verify skip 0 "apply failed; idempotency not testable" ""
        else
            run_one_stage "$name" verify "$verify_fn" "$rec" "$port" || rc=1
        fi
    fi
    if [ "$want_doctor" -eq 1 ]; then run_one_stage "$name" doctor "$doctor_fn" "$rec" "$port" || rc=1; fi

    if [ "$KEEP_TARGET" -eq 1 ] || [ "$attached" -eq 1 ]; then
        target_keep_hint "$lane" "$name" "$cname" "$port"
        # Descriptor for the next --reuse round-trip (written to this run's
        # log dir, and refreshed in the run we attached from so repeated
        # reuses of the original keep id keep working).
        printf '{"lane":"%s","name":"%s","cname":"%s","port":%s,"image":"%s"}\n' \
            "$lane" "$name" "$cname" "$port" "$(record_get "$rec" '.image')" \
            >"$LOG_RUN_DIR/kept-$name.json"
        if [ "$attached" -eq 1 ] && [ "$LOG_RUN_DIR" != "$RUNNER_DIR/logs/$REUSE_RUN" ]; then
            cp "$LOG_RUN_DIR/kept-$name.json" "$RUNNER_DIR/logs/$REUSE_RUN/kept-$name.json" 2>/dev/null || true
        fi
        # The port lock stays held: the target is still listening on it.
    else
        target_down "$lane" "$cname"
        ports_release "$port"
    fi
    return "$rc"
}

# target_keep_hint <lane> <name> <cname> <port> — lane-appropriate connection
# details for a kept target (--keep / --reuse).
target_keep_hint() {
    local lane="$1" name="$2" cname="$3" port="$4"
    case "$lane" in
        vm)
            log_info "vm kept: overlay + OVMF vars + seed under $(vm_workdir "$name")"
            log_info "serial: $(log_result_dir "$name")/serial.log"
            log_info "ssh: ssh -p $port -o IdentitiesOnly=yes -i $(ssh_key) $SSH_TARGET_USER@127.0.0.1"
            ;;
        windows)
            log_info "windows kept: overlay + OVMF vars under $(windows_workdir "$name")"
            log_info "TPM state/socket: $(cat "$(windows_workdir "$name")/swtpm-socket-dir" 2>/dev/null || true)"
            log_info "serial: $(log_result_dir "$name")/serial.log"
            log_info "ssh: ssh -p $port -o IdentitiesOnly=yes -i $(ssh_key) $WINDOWS_TARGET_USER@127.0.0.1"
            ;;
        *)
            log_info "target kept: docker exec -it $cname bash"
            log_info "ssh: ssh -p $port -i $(ssh_key) $SSH_TARGET_USER@127.0.0.1"
            ;;
    esac
}

# --- hidden worker (used by --parallel) -------------------------------------

cmd_lint_worker() {
    local tf="${1:?worker needs a target file}"
    [ -f "$tf" ] || { log_error "worker: no such target file: $tf"; return 1; }
    local rec
    rec="$(cat "$tf")"
    stage_lint_run "$rec" || true
    return 0
}

# --- scenarios --------------------------------------------------------------

cmd_scenarios() {
    matrix_validate || return 1
    printf '%s%-40s %-18s %-8s %s%s\n' "$C_BOLD" "scenario" "image" "lane" "categories" "$C_RESET"
    matrix_resolve | while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%-40s %-18s %-8s %s\n' \
            "$(printf '%s' "$line" | yq -p=json -r '.name')" \
            "$(printf '%s' "$line" | yq -p=json -r '.image')" \
            "$(printf '%s' "$line" | yq -p=json -r '.lane')" \
            "$(printf '%s' "$line" | yq -p=json -r '.data.categories|join("+")')"
    done
}

# --- doctor-host ------------------------------------------------------------

_doctor_cmd() {
    local label="$1"
    shift
    local path
    if path="$(command -v "$1" 2>/dev/null)"; then
        printf '  %s[ok]%s   %-22s %s\n' "$C_GREEN" "$C_RESET" "$label" "$path"
        return 0
    fi
    printf '  %s[miss]%s %-22s\n' "$C_RED" "$C_RESET" "$label"
    return 1
}

_doctor_any_cmd() {
    local label="$1"
    shift
    local c path
    for c in "$@"; do
        if path="$(command -v "$c" 2>/dev/null)"; then
            printf '  %s[ok]%s   %-22s %s\n' "$C_GREEN" "$C_RESET" "$label" "$path"
            return 0
        fi
    done
    printf '  %s[miss]%s %-22s (any of: %s)\n' "$C_RED" "$C_RESET" "$label" "$*"
    return 1
}

_doctor_ovmf() {
    local f
    for f in \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/qemu/OVMF_CODE.fd; do
        if [ -f "$f" ]; then
            printf '  %s[ok]%s   %-22s %s\n' "$C_GREEN" "$C_RESET" "OVMF firmware" "$f"
            return 0
        fi
    done
    printf '  %s[miss]%s %-22s\n' "$C_RED" "$C_RESET" "OVMF firmware"
    return 1
}

cmd_doctor_host() {
    local lint_ok=0

    log_step "lane: lint (required)"
    _doctor_cmd chezmoi chezmoi && lint_ok=1 || true
    _doctor_cmd yq yq || lint_ok=0
    _doctor_cmd ansible-playbook ansible-playbook || lint_ok=0
    _doctor_cmd bash bash || lint_ok=0

    log_step "lane: container"
    _doctor_cmd docker docker || true

    log_step "lane: vm / windows"
    _doctor_cmd qemu-system-x86_64 qemu-system-x86_64 || true
    _doctor_cmd qemu-img qemu-img || true
    _doctor_any_cmd "ISO tool" genisoimage mkisofs xorriso || true
    _doctor_cmd swtpm swtpm || true
    _doctor_cmd python3 python3 || true
    _doctor_cmd mkfs.vfat mkfs.vfat || true
    _doctor_cmd mcopy mcopy || true
    _doctor_cmd iconv iconv || true
    _doctor_cmd setsid setsid || true
    _doctor_ovmf || true
    if [ -e /dev/kvm ]; then
        printf '  %s[ok]%s   %-22s %s\n' "$C_GREEN" "$C_RESET" "/dev/kvm" "present"
    else
        printf '  %s[miss]%s %-22s %s\n' "$C_RED" "$C_RESET" "/dev/kvm" "no KVM acceleration"
    fi

    log_step "sync"
    _doctor_cmd rsync rsync || true
    _doctor_cmd ssh ssh || true

    log_step "Windows bake inputs"
    local windows_iso="${DOTFILES_TEST_WINDOWS_ISO:-}"
    if [ -n "$windows_iso" ] && [ -f "$windows_iso" ]; then
        printf '  %s[ok]%s   %-22s %s\n' "$C_GREEN" "$C_RESET" "Windows ISO" "$windows_iso"
    else
        printf '  %s[miss]%s %-22s (set DOTFILES_TEST_WINDOWS_ISO to a licensed local ISO)\n' "$C_RED" "$C_RESET" "Windows ISO"
    fi
    if [ -n "${DOTFILES_TEST_BECOME_FILE:-}" ] && [ -f "$DOTFILES_TEST_BECOME_FILE" ]; then
        local password_mode
        password_mode="$(stat -c '%a' "$DOTFILES_TEST_BECOME_FILE" 2>/dev/null || true)"
        if [ "$password_mode" = "600" ]; then
            printf '  %s[ok]%s   %-22s %s\n' "$C_GREEN" "$C_RESET" "Windows password" "$DOTFILES_TEST_BECOME_FILE"
        else
            printf '  %s[warn]%s %-22s (file mode is %s; use chmod 600)\n' "$C_YELLOW" "$C_RESET" "Windows password" "$password_mode"
        fi
    else
        printf '  %s[miss]%s %-22s (set DOTFILES_TEST_BECOME_FILE to a mode-600 password file)\n' "$C_RED" "$C_RESET" "Windows password"
    fi

    log_step "lane: vm goldens ($GOLDEN_DIR)"
    local mf gkey gtype gmiss=0
    mf="$(matrix_file)"
    if [ -f "$mf" ]; then
        while IFS='|' read -r gkey gtype; do
            case "$gtype" in
                cloud | cloud-baked | windows-baked | manual-recipe)
                    if [ -f "$(qemu_golden_path "$gkey")" ]; then
                        printf '  %s[ok]%s   %-22s %s\n' "$C_GREEN" "$C_RESET" "$gkey" "$(qemu_golden_path "$gkey")"
                    else
                        printf '  %s[miss]%s %-22s (images pull / images bake)\n' "$C_RED" "$C_RESET" "$gkey"
                        gmiss=1
                    fi
                    ;;
            esac
        done < <(yq -r '.images | to_entries[] | select(.value.type == "cloud" or .value.type == "cloud-baked" or .value.type == "windows-baked" or .value.type == "manual-recipe") | [.key, .value.type] | @tsv' "$mf" | tr '\t' '|')
        [ "$gmiss" -eq 0 ] || log_info "goldens are a cache, not a prerequisite: missing only means the lane cannot boot yet"
    fi

    if [ "$lint_ok" -eq 1 ]; then
        log_info ""
        log_info "lint prerequisites: OK"
        return 0
    fi
    log_error "lint prerequisites: MISSING (see above)"
    return 1
}

# --- images -----------------------------------------------------------------

cmd_images() {
    local sub="${1:-}"
    [ $# -gt 0 ] && shift || true
    case "$sub" in
        build) images_build "$@" ;;
        pull) images_pull "$@" ;;
        bake) images_bake "$@" ;;
        list) images_list "$@" ;;
        rm) images_rm "$@" ;;
        "") log_error "images: subcommand required (build|pull|bake|list|rm)"; return 2 ;;
        *) log_error "images: unknown subcommand: $sub"; return 2 ;;
    esac
}

images_build() {
    local lane="" image=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --lane) lane="${2:?--lane needs a value}"; shift 2 ;;
            --image) image="${2:?--image needs a value}"; shift 2 ;;
            *) log_error "images build: unknown flag: $1"; return 2 ;;
        esac
    done
    matrix_validate || return 1
    local mf count=0 key type df tag
    mf="$(matrix_file)"
    while IFS='|' read -r key type df tag; do
        [ "$type" = "container" ] || continue
        [ -n "$lane" ] && [ "$lane" != "container" ] && continue
        [ -n "$image" ] && [ "$key" != "$image" ] && continue
        [ -n "$df" ] && [ "$df" != "null" ] || { log_error "image $key has no dockerfile"; return 1; }
        log_step "building $key -> $tag"
        docker build -t "$tag" -f "$DOTFILES_TEST_REPO_ROOT/$df" "$(dirname "$DOTFILES_TEST_REPO_ROOT/$df")" || return 1
        count=$((count + 1))
    done < <(yq -r '.images | to_entries[] | [.key, (.value.type // ""), (.value.dockerfile // ""), (.value.tag // "")] | @tsv' "$mf" | tr '\t' '|')
    [ "$count" -gt 0 ] || { log_error "no container images matched"; return 2; }
    log_info "built $count image(s)"
}

# images_list — every image with its artifact status (docker tag for
# containers, golden file for cloud/cloud-baked).
images_list() {
    matrix_validate || return 1
    local mf key type tag detail present
    mf="$(matrix_file)"
    printf '%s%-28s %-13s %-8s %s%s\n' "$C_BOLD" "image" "type" "status" "artifact" "$C_RESET"
    while IFS='|' read -r key type tag; do
        case "$type" in
            container)
                detail="$tag"
                if docker image inspect "$tag" >/dev/null 2>&1; then present=present; else present=missing; fi
                ;;
            cloud | cloud-baked | windows-baked | manual-recipe)
                detail="$(qemu_golden_path "$key")"
                if [ -f "$detail" ]; then present=present; else present=missing; fi
                ;;
            *)
                detail="-"
                present="n/a"
                ;;
        esac
        printf '%-28s %-13s %-8s %s\n' "$key" "$type" "$present" "$detail"
    done < <(yq -r '.images | to_entries[] | [.key, (.value.type // ""), (.value.tag // "")] | @tsv' "$mf" | tr '\t' '|')
}

images_rm() {
    local mf key type tag
    mf="$(matrix_file)"
    while IFS=$'\t' read -r key type tag; do
        if docker rmi "$tag" >/dev/null 2>&1; then log_info "removed $tag"; fi
    done < <(yq -r '.images | to_entries[] | select(.value.type == "container") | [.key, .value.type, (.value.tag // "")] | @tsv' "$mf")
}

# images_checksum_ok <file> <sha256> <sha512> — verify against whichever pin
# the image declares (Debian publishes only SHA512; Ubuntu/Fedora SHA256).
# Prints the actual digest on mismatch so the matrix pin can be updated.
images_checksum_ok() {
    local file="$1" sha256="$2" sha512="$3" want got algo
    if [ -n "$sha256" ] && [ "$sha256" != "null" ]; then
        want="$sha256" algo="sha256"
        got="$(sha256sum "$file" | awk '{print $1}')"
    elif [ -n "$sha512" ] && [ "$sha512" != "null" ]; then
        want="$sha512" algo="sha512"
        got="$(sha512sum "$file" | awk '{print $1}')"
    else
        log_error "no checksum pin for $file"
        return 1
    fi
    if [ "$got" != "$want" ]; then
        log_error "$algo mismatch for $file"
        log_error "expected: $want"
        log_error "actual:   $got"
        return 1
    fi
    return 0
}

# images_pull [--image <name>] — download pinned stock cloud images into
# $GOLDEN_DIR (gitignored). Idempotent: an existing golden whose checksum
# still matches is skipped; a mismatch aborts (corrupt file or upstream
# republish — fix procedure: delete the file or update the matrix pin, then
# re-pull).
images_pull() {
    local image=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --image) image="${2:?--image needs a value}"; shift 2 ;;
            *) log_error "images pull: unknown flag: $1"; return 2 ;;
        esac
    done
    matrix_validate || return 1
    mkdir -p "$GOLDEN_DIR"

    local mf count=0 key type url sha256 sha512 dest tmp
    mf="$(matrix_file)"
    while IFS='|' read -r key type url sha256 sha512; do
        [ "$type" = "cloud" ] || continue
        [ -n "$image" ] && [ "$key" != "$image" ] && continue
        [ -n "$url" ] && [ "$url" != "null" ] || { log_error "image $key has no url pin"; return 1; }
        if { [ -z "$sha256" ] || [ "$sha256" = "null" ]; } && { [ -z "$sha512" ] || [ "$sha512" = "null" ]; }; then
            log_error "image $key has no checksum pin"
            return 1
        fi
        dest="$(qemu_golden_path "$key")"

        if [ -f "$dest" ]; then
            if images_checksum_ok "$dest" "$sha256" "$sha512"; then
                log_info "$key: golden up to date ($dest)"
                count=$((count + 1))
                continue
            fi
            log_error "$key: existing golden fails its pin; delete it and re-pull:"
            log_error "  rm '$dest' && ./test/run.sh images pull --image $key"
            return 1
        fi

        command -v curl >/dev/null 2>&1 || { log_error "curl is required for images pull"; return 1; }
        tmp="$dest.part"
        log_step "pulling $key -> $dest"
        if ! curl -fL --retry 3 --connect-timeout 15 -o "$tmp" "$url"; then
            rm -f "$tmp"
            log_error "$key: download failed ($url)"
            return 1
        fi
        if ! images_checksum_ok "$tmp" "$sha256" "$sha512"; then
            rm -f "$tmp"
            log_error "$key: download discarded (checksum mismatch)"
            return 1
        fi
        mv "$tmp" "$dest"
        count=$((count + 1))
    done < <(yq -r '.images | to_entries[] | [.key, (.value.type // ""), (.value.url // ""), (.value.sha256 // ""), (.value.sha512 // "")] | @tsv' "$mf" | tr '\t' '|')

    if [ "$count" -eq 0 ]; then
        [ -n "$image" ] && log_error "no cloud image named: $image" || log_error "no cloud images in matrix.yaml"
        return 2
    fi
    log_info "pulled/verified $count golden(s) in $GOLDEN_DIR"
}

# images_bake <name> — build a cloud-baked golden from a cloud base or the
# Windows golden from the user-supplied ISO. Re-bake = same command.
images_bake() {
    local image="${1:-}" iso="${DOTFILES_TEST_WINDOWS_ISO:-}"
    [ -n "$image" ] || { log_error "usage: images bake <name>"; return 2; }
    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --iso) iso="${2:?--iso needs a path}"; shift 2 ;;
            *) log_error "images bake: unknown flag: $1"; return 2 ;;
        esac
    done
    matrix_validate || return 1
    mkdir -p "$GOLDEN_DIR"

    local mf btype base packages p items="" runcmds="" workdir seed serial dest
    mf="$(matrix_file)"
    btype="$(yq -r ".images[\"$image\"].type // \"\"" "$mf")"
    if [ "$btype" = "windows-baked" ]; then
        windows_images_bake "$image" "$iso"
        return $?
    fi
    [ "$btype" = "cloud-baked" ] || { log_error "$image is not a cloud-baked image (type: ${btype:-none})"; return 2; }
    base="$(yq -r ".images[\"$image\"].base" "$mf")"

    # Split bake.packages: plain names go to the packages module; "@..."
    # group/environment specs become dnf runcmd fallbacks (bake seed template
    # documents why the exact dnf form waits for the first Fedora bake).
    packages="$(yq -r ".images[\"$image\"].bake.packages[]" "$mf")"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in
            @*)
                runcmds+="  - dnf -y install '$p' || dnf -y groupinstall '$p' || dnf -y groupinstall '${p#@}'"$'\n'
                ;;
            *)
                items+="  - $p"$'\n'
                ;;
        esac
    done <<<"$packages"
    [ -n "$items" ] || items="  []"
    if [ -z "$items" ] && [ -z "$runcmds" ]; then
        log_error "$image: bake.packages is empty"
        return 1
    fi

    if [ ! -f "$(qemu_golden_path "$base")" ]; then
        log_error "base golden missing: $(qemu_golden_path "$base")"
        log_error "fetch it first: ./test/run.sh images pull --image $base"
        return 1
    fi
    command -v qemu-img >/dev/null 2>&1 || { log_error "qemu-img missing (doctor-host)"; return 1; }

    workdir="$(vm_workdir "bake-$image")"
    seed="$workdir/seed.iso"
    serial="$workdir/serial.log"
    dest="$(qemu_golden_path "$image")"

    rm -rf "$workdir"
    log_step "baking $image from $base (15-25 min; package downloads dominate)"
    cloudinit_seed_iso "$workdir" bake-user-data.yaml.tmpl \
        "PACKAGE_ITEMS=$items" "BAKE_RUNCMD=$runcmds" || return 1
    qemu_launch "bake-$image" "$image" "" "$seed" "$serial" "$base" || {
        qemu_stop "bake-$image" 1
        return 1
    }

    if ! qemu_wait_exit "bake-$image" "$VM_BAKE_TIMEOUT"; then
        qemu_stop "bake-$image" 1
        log_error "bake timed out after ${VM_BAKE_TIMEOUT}s (guest never powered off)"
        log_error "serial log: $serial — workdir kept for inspection: $workdir"
        return 1
    fi
    local keep=0
    if [ -f "$serial" ] && grep -qiE 'cloud-init.*(error|failed)' "$serial"; then
        keep=1
        log_warn "bake: cloud-init reported errors; keeping workdir for inspection: $workdir"
        log_warn "bake: serial log: $serial"
    fi

    # Flatten (convert) so the new golden does not chain off its base.
    log_info "promoting booted disk -> $dest"
    if ! qemu-img convert -O qcow2 "$workdir/disk.qcow2" "$dest.part"; then
        rm -f "$dest.part"
        qemu_stop "bake-$image" 1
        return 1
    fi
    mv "$dest.part" "$dest"
    qemu_stop "bake-$image" "$keep"
    log_info "baked $image ($(du -h "$dest" | cut -f1)) — verify by running its scenario"
}

cmd_not_implemented() {
    log_error "'$1' is not implemented until $2"
    return 2
}

# --- dispatch ---------------------------------------------------------------

cmd="${1:-}"
if [ $# -gt 0 ]; then shift; fi

case "$cmd" in
    run) cmd_run "$@" ;;
    scenarios) cmd_scenarios "$@" ;;
    doctor-host) cmd_doctor_host "$@" ;;
    images) cmd_images "$@" ;;
    report) cmd_not_implemented report "Phase E" ;;
    cases) cmd_not_implemented cases "Phase F" ;;
    __lint-worker) cmd_lint_worker "$@" ;;
    -h | --help | help | "") usage; [ -n "$cmd" ] || exit 2 ;;
    *) log_error "unknown command: $cmd"; usage; exit 2 ;;
esac
