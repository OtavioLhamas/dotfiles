#!/usr/bin/env bash
# stage_lint.sh — the host-only lint stage.
#
# Runs once per resolved scenario data variant (no target needed):
#   1. render every .chezmoiscripts/*.sh.tmpl + bash -n (+ shellcheck, warn-only)
#   2. chezmoi apply --dry-run  (catches dotfile template runtime errors)
#   3. Ansible --syntax-check against a scenario-rendered inventory
# Windows scenarios are recorded as `skip` (Windows rendering lands in Phase D).
#
# Sourced by test/run.sh.

# stage_lint_run <scenario-record-json>
# Returns 0=pass, 1=fail, 2=skip. Always writes a result.json.
stage_lint_run() {
    local record="$1"
    (stage_lint_body "$record")
}

stage_lint_body() {
    local record="$1"
    local name os
    name="$(printf '%s' "$record" | yq -p=json -r '.name')"
    os="$(printf '%s' "$record" | yq -p=json -r '.os')"

    local rdir log cfg
    rdir="$(log_result_dir "$name")"
    mkdir -p "$rdir"
    log="$rdir/lint.log"
    : >"$log"
    cfg="$rdir/chezmoi.yaml"
    preseed_write_config "$cfg" "$record"

    local start
    start="$(date +%s)"

    if [ "$os" = "windows" ]; then
        printf 'skipped: windows template rendering requires a Windows host (Phase D)\n' >>"$log"
        log_write_result "$name" lint skip 0 "windows rendering requires Phase D" "$log"
        return 2
    fi

    # Scenario env (init-time DE/DS knobs) + harness non-interactive marker.
    # NOPASSWD targets pass no become flag, so DOTFILES_TEST_BECOME_FILE is
    # left unset (Ansible rejects an empty --become-password-file).
    # shellcheck disable=SC1090
    eval "$(preseed_env_for_record "$record")"
    export DOTFILES_TEST=1

    local rc=0 detail=""
    if ! stage_lint_scripts "$cfg" >>"$log" 2>&1; then
        rc=1
        detail="script render/syntax failed"
    fi
    if [ "$rc" -eq 0 ] && ! stage_lint_dry_run "$cfg" >>"$log" 2>&1; then
        rc=1
        detail="chezmoi apply --dry-run failed"
    fi
    if [ "$rc" -eq 0 ] && ! stage_lint_ansible "$cfg" >>"$log" 2>&1; then
        rc=1
        detail="ansible --syntax-check failed"
    fi

    local dur=$(( $(date +%s) - start ))
    if [ "$rc" -eq 0 ]; then
        log_write_result "$name" lint pass "$dur" "" "$log"
        return 0
    fi
    log_write_result "$name" lint fail "$dur" "$detail" "$log"
    return 1
}

# --- step 1: render scripts + syntax ----------------------------------------

stage_lint_scripts() {
    local cfg="$1"
    local tmp script out rc=0
    tmp="$(mktemp -d)"
    for script in "$DOTFILES_TEST_REPO_ROOT"/chezmoi/.chezmoiscripts/*.sh.tmpl; do
        [ -f "$script" ] || continue
        out="$tmp/$(basename "${script%.tmpl}")"
        if ! chezmoi execute-template --config "$cfg" --source "$DOTFILES_TEST_REPO_ROOT/chezmoi" \
            <"$script" >"$out" 2>"$out.err"; then
            printf 'FAIL render: %s\n' "$(basename "$script")"
            sed 's/^/    /' "$out.err"
            rc=1
            continue
        fi
        if ! bash -n "$out" 2>"$out.syntax"; then
            printf 'FAIL bash -n: %s\n' "$(basename "$script")"
            sed 's/^/    /' "$out.syntax"
            rc=1
            continue
        fi
        if command -v shellcheck >/dev/null 2>&1; then
            if ! shellcheck -s bash -S warning "$out" >"$out.sc" 2>&1; then
                printf 'WARN shellcheck: %s\n' "$(basename "$script")"
                sed 's/^/    /' "$out.sc"
            fi
        fi
    done
    rm -rf "$tmp"
    return "$rc"
}

# --- step 2: chezmoi apply --dry-run ----------------------------------------

stage_lint_dry_run() {
    local cfg="$1"
    chezmoi apply --dry-run --config "$cfg" --source "$DOTFILES_TEST_REPO_ROOT/chezmoi"
}

# --- step 3: Ansible syntax check -------------------------------------------

stage_lint_ansible() {
    local cfg="$1"
    local invdir inv rc
    invdir="$(mktemp -d)"
    inv="$invdir/inventory.yaml"
    chezmoi execute-template --config "$cfg" --source "$DOTFILES_TEST_REPO_ROOT/chezmoi" \
        <"$DOTFILES_TEST_REPO_ROOT/chezmoi/.chezmoitemplates/ansible-inventory.yaml" >"$inv" || {
        rm -rf "$invdir"
        return 1
    }
    printf -- '--- generated inventory ---\n'
    sed 's/^/    /' "$inv"
    (cd "$DOTFILES_TEST_REPO_ROOT/ansible" && ansible-playbook --syntax-check -i "$inv" main.yaml)
    rc=$?
    rm -rf "$invdir"
    return "$rc"
}

# --- step 4: Nix flake validation (host, run-level, once) -------------------

# stage_lint_nix_run <cfg> — render the Nix tree and run `nix flake check`
# (evaluation only) when nix is present. Writes a result under scenario `_nix`.
stage_lint_nix_run() {
    local cfg="$1"
    local rdir log start rc=0 detail=""
    rdir="$(log_result_dir "_nix")"
    mkdir -p "$rdir"
    log="$rdir/lint.log"
    : >"$log"
    start="$(date +%s)"

    local flake="$DOTFILES_TEST_REPO_ROOT/chezmoi/nix/flake.nix.tmpl"
    if [ ! -f "$flake" ]; then
        printf 'skip: chezmoi/nix/flake.nix.tmpl not present\n' >>"$log"
        log_write_result "_nix" lint skip 0 "flake template not present" "$log"
        return 2
    fi

    local tmp
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/home"
    local f out
    for f in "$DOTFILES_TEST_REPO_ROOT"/chezmoi/nix/*.nix.tmpl "$DOTFILES_TEST_REPO_ROOT"/chezmoi/nix/home/*.nix.tmpl; do
        [ -f "$f" ] || continue
        out="$tmp/$(basename "${f%.tmpl}")"
        case "$f" in
            */nix/home/*) out="$tmp/home/$(basename "${f%.tmpl}")" ;;
        esac
        if ! chezmoi execute-template --config "$cfg" --source "$DOTFILES_TEST_REPO_ROOT/chezmoi" \
            <"$f" >"$out" 2>>"$log"; then
            rc=1
            detail="nix template render failed: $(basename "$f")"
            break
        fi
    done
    [ -f "$DOTFILES_TEST_REPO_ROOT/chezmoi/nix/flake.lock" ] && cp -f "$DOTFILES_TEST_REPO_ROOT/chezmoi/nix/flake.lock" "$tmp/flake.lock"

    if [ "$rc" -eq 0 ] && ! command -v nix >/dev/null 2>&1; then
        printf 'skip: nix not installed (flake template rendered OK)\n' >>"$log"
        rm -rf "$tmp"
        log_write_result "_nix" lint skip 0 "nix not installed" "$log"
        return 2
    fi

    if [ "$rc" -eq 0 ]; then
        printf 'running: nix flake check --no-build --no-write-lock-file\n' >>"$log"
        if ! (cd "$tmp" && nix --extra-experimental-features "nix-command flakes" \
            flake check --no-build --no-write-lock-file) >>"$log" 2>&1; then
            rc=1
            detail="nix flake check failed"
        fi
    fi
    rm -rf "$tmp"

    local dur=$(( $(date +%s) - start ))
    if [ "$rc" -eq 0 ]; then
        log_write_result "_nix" lint pass "$dur" "" "$log"
        return 0
    fi
    log_write_result "_nix" lint fail "$dur" "$detail" "$log"
    return 1
}
