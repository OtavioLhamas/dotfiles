#!/usr/bin/env bash
# stage_target.sh — stages that run against a booted SSH target (container
# lane now; VM lane reuses these in Phase C).
#
# Stage convention: return 0 = pass, 1 = fail, 2 = skip.
#
# Remote scripts are rendered locally (token substitution) and piped to
# `bash -s`, so scenario values never round-trip through SSH argument
# re-parsing. The target repo path is canonical (see targets.sh): the config's
# hook path is hardcoded to `.local/share/chezmoi/chezmoi/...`.
#
# Sourced by test/run.sh.

# Default role exclusions for the container lane:
#   docker  — docker-in-docker is not a valid test of the role
#   gnome   — no desktop environment
#   flatpak — its system helper requires polkit, which will not start in the
#             container (flatpak-system-helper: "Can't get polkit authority").
#             The VM lane covers flatpak and everything built on it.
#   (bitwarden/deskflow/discord/obsidian/prismlauncher/spotify/steam/stremio
#    install via flatpak and inherit the same limitation.)
CONTAINER_EXCLUDE_ROLES="${CONTAINER_EXCLUDE_ROLES:-docker,gnome,flatpak,bitwarden,deskflow,discord,obsidian,prismlauncher,spotify,steam,stremio}"

record_get() {
    printf '%s' "$1" | yq -p=json -r "$2"
}

record_de() { record_get "$1" '.env.XDG_CURRENT_DESKTOP // ""'; }
record_ds() { record_get "$1" '.env.XDG_SESSION_TYPE // ""'; }
record_lane() { record_get "$1" '.lane // "container"'; }

# record_exclude_roles <record> — role exclusions are a lane property: the
# container lane must skip docker (docker-in-docker invalid), gnome (no DE)
# and everything flatpak-based (no polkit); the VM lane runs the full role
# set for real, so it renders no exclusions at all.
record_exclude_roles() {
    case "$(record_lane "$1")" in
        vm) ;;
        *) printf '%s' "$CONTAINER_EXCLUDE_ROLES" ;;
    esac
}

# record_nix_flag <record> — "1"/"0" for DOTFILES_TEST_NIX (Decision 10: the
# per-scenario `nix` dimension; off where Nix cannot run, e.g. Fedora/SELinux).
# NB: yq's `//` treats false as empty, so branch on the printed value.
record_nix_flag() {
    case "$(record_get "$1" '.nix')" in
        false) printf '0' ;;
        *) printf '1' ;;
    esac
}

# github_token — pass a token to the target so mise's GitHub API calls are
# authenticated (unauthenticated requests are limited to 60/hour per IP, which
# repeated container runs exhaust). Uses $GITHUB_TOKEN, else `gh auth token`.
github_token() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        printf '%s' "$GITHUB_TOKEN"
        return
    fi
    if command -v gh >/dev/null 2>&1; then
        gh auth token 2>/dev/null || true
    fi
}

# render_script <template> KEY=VALUE... — replace @@KEY@@ tokens.
render_script() {
    local tmpl="$1"
    shift
    local pair k v
    for pair in "$@"; do
        k="${pair%%=*}"
        v="${pair#*=}"
        tmpl="${tmpl//@@${k}@@/$v}"
    done
    printf '%s' "$tmpl"
}

# --- doctor -----------------------------------------------------------------

stage_target_doctor() {
    local record="$1" port="$2"
    if ! target_ssh_cmd "$port" '[ -x "$HOME/.local/bin/chezmoi" ] || command -v chezmoi >/dev/null 2>&1'; then
        log_info "doctor: chezmoi not installed yet (fresh target); skipping"
        return 2
    fi
    local script
    script="$(render_script "$(health_check_script)" "IGNORE_ROWS=$HEALTH_CHECK_DOCTOR_IGNORE")"
    printf '%s' "$script" | target_ssh_script "$port"
}

# --- dry-run ----------------------------------------------------------------

stage_target_dry_run() {
    local record="$1" port="$2"
    local cfg
    cfg="$(preseed_config_text "$TARGET_REPO/chezmoi" "$record")"

    # Write the pre-seed config (fed over stdin; no shell re-parsing).
    printf '%s' "$cfg" | target_ssh_cmd_stdin "$port" \
        "mkdir -p $TARGET_HOME/.config/chezmoi && cat > $TARGET_HOME/.config/chezmoi/chezmoi.yaml"

    local tmpl script
    tmpl="$(cat <<'REMOTE'
set -euo pipefail
DEST="@@DEST@@"; DE="@@DE@@"; DS="@@DS@@"; NIX="@@NIX@@"
export PATH="$HOME/.local/bin:$PATH"
# sshd does not propagate the image's LANG; Ansible refuses to run without a
# usable locale. C.UTF-8 exists on every distro we target.
export LANG="${LANG:-C.UTF-8}" LC_ALL="${LC_ALL:-C.UTF-8}"
# Wait for cloud-init to finish (cloud images hold the apt lock during
# late-stage package installs; SSH becomes reachable before that). Poll with a
# portable awk extractor (grep -E has no \K) and a bounded ceiling so a
# detection miss can never hang the run.
wait_cloud_init() {
    local i=0 s
    while [ "$i" -lt 200 ]; do
        s="$(cloud-init status 2>/dev/null | awk -F': *' '/^status:/{print $2; exit}' || true)"
        if [ "$s" = "done" ] || [ "$s" = "error" ]; then
            return 0
        fi
        sleep 3
        i=$((i + 1))
    done
    return 0
}
echo "--- waiting for cloud-init ---"
wait_cloud_init

if ! command -v chezmoi >/dev/null 2>&1; then
    echo "installing chezmoi..."
    mkdir -p "$HOME/.local/bin"
    sh -c "$(curl -fsSL https://get.chezmoi.io)" -- -b "$HOME/.local/bin"
fi

cd "$HOME"
echo "--- chezmoi init ---"
XDG_CURRENT_DESKTOP="$DE" XDG_SESSION_TYPE="$DS" DOTFILES_TEST=1 \
DOTFILES_TEST_NIX="$NIX" \
    chezmoi init --source "$DEST/chezmoi"
echo "--- chezmoi apply --dry-run --verbose ---"
XDG_CURRENT_DESKTOP="$DE" XDG_SESSION_TYPE="$DS" DOTFILES_TEST=1 \
DOTFILES_TEST_NIX="$NIX" \
    chezmoi apply --dry-run --verbose --source "$DEST/chezmoi"
echo "dry-run OK"
REMOTE
)"
    script="$(render_script "$tmpl" \
        "DEST=$TARGET_REPO" "DE=$(record_de "$record")" "DS=$(record_ds "$record")" \
        "NIX=$(record_nix_flag "$record")")"
    printf '%s' "$script" | target_ssh_script "$port"
}

# --- apply ------------------------------------------------------------------

stage_target_apply() {
    local record="$1" port="$2"

    # Pre-seed the config so `chezmoi init` never prompts for classification.
    # (dry-run writes it too, but apply must stand alone.)
    local cfg
    cfg="$(preseed_config_text "$TARGET_REPO/chezmoi" "$record")"
    printf '%s' "$cfg" | target_ssh_cmd_stdin "$port" \
        "mkdir -p $TARGET_HOME/.config/chezmoi && cat > $TARGET_HOME/.config/chezmoi/chezmoi.yaml"

    local tmpl script
    tmpl="$(cat <<'REMOTE'
set -euo pipefail
DEST="@@DEST@@"; DE="@@DE@@"; DS="@@DS@@"; EXCL="@@EXCL@@"; NIX="@@NIX@@"
GITHUB_TOKEN="@@GITHUB_TOKEN@@"; export GITHUB_TOKEN
# sshd does not propagate the image's LANG; Ansible refuses to run without a
# usable locale. C.UTF-8 exists on every distro we target.
export LANG="${LANG:-C.UTF-8}" LC_ALL="${LC_ALL:-C.UTF-8}"
# Wait for cloud-init to finish (cloud images hold the apt lock during
# late-stage package installs; SSH becomes reachable before that). Poll with a
# portable awk extractor (grep -E has no \K) and a bounded ceiling so a
# detection miss can never hang the run.
wait_cloud_init() {
    local i=0 s
    while [ "$i" -lt 200 ]; do
        s="$(cloud-init status 2>/dev/null | awk -F': *' '/^status:/{print $2; exit}' || true)"
        if [ "$s" = "done" ] || [ "$s" = "error" ]; then
            return 0
        fi
        sleep 3
        i=$((i + 1))
    done
    return 0
}
echo "--- waiting for cloud-init ---"
wait_cloud_init
cd "$DEST"
echo "--- running bootstrap.sh ---"
XDG_CURRENT_DESKTOP="$DE" XDG_SESSION_TYPE="$DS" \
DOTFILES_TEST=1 DOTFILES_TEST_EXCLUDE_ROLES="$EXCL" DOTFILES_TEST_NIX="$NIX" \
    bash bootstrap.sh
echo "apply OK"
REMOTE
)"
    script="$(render_script "$tmpl" \
        "DEST=$TARGET_REPO" "DE=$(record_de "$record")" "DS=$(record_ds "$record")" \
        "EXCL=$(record_exclude_roles "$record")" "GITHUB_TOKEN=$(github_token)" \
        "NIX=$(record_nix_flag "$record")")"

    # Run the remote script, then collect post-apply artifacts (best effort —
    # they must never flip the stage result).
    local rc=0
    printf '%s' "$script" | target_ssh_script "$port" || rc=$?
    stage_target_collect_artifacts "$record" "$port"
    return "$rc"
}

# stage_target_collect_artifacts <record> <port> — persist diagnostic state
# next to the stage logs: chezmoi's persistent-state dump and the inventory
# ansible generated during apply (both regenerated every apply).
stage_target_collect_artifacts() {
    local record="$1" port="$2" rdir
    rdir="$(log_result_dir "$(record_get "$record" '.name')")"
    mkdir -p "$rdir"
    if ! target_ssh_cmd "$port" \
        "export PATH=\"\$HOME/.local/bin:\$PATH\"; chezmoi state dump --format json" \
        >"$rdir/chezmoi-state.json" 2>/dev/null; then
        rm -f "$rdir/chezmoi-state.json"
    fi
    if ! target_ssh_cmd "$port" "cat $TARGET_REPO/ansible/inventory.yaml" \
        >"$rdir/ansible-inventory.yaml" 2>/dev/null; then
        rm -f "$rdir/ansible-inventory.yaml"
    fi
    return 0
}

# Tasks that are known non-idempotent and therefore excluded from the
# "ansible changed=0" assertion. `deb822_repository` rewrites its .sources
# file on every run in this collection version, regardless of whether the
# signing key is a URL or a local path (upstream module limitation).
# Everything else must be changed=0 on re-run.
VERIFY_XFAIL_TASKS_RE='TASK \[(rsync|vivaldi|fish|wezterm)[^]]*(PPA|deb822|repository|key)'

# --- verify -----------------------------------------------------------------

stage_target_verify() {
    local record="$1" port="$2"
    local tmpl script
    tmpl="$(cat <<'REMOTE'
set -uo pipefail
DEST="@@DEST@@"; DE="@@DE@@"; DS="@@DS@@"; EXCL="@@EXCL@@"; NIX="@@NIX@@"
GITHUB_TOKEN="@@GITHUB_TOKEN@@"; export GITHUB_TOKEN
XFAIL_RE='@@XFAIL_RE@@'
export PATH="$HOME/.local/bin:$PATH"
# Match the apply stage's locale (sshd does not propagate it).
export LANG="${LANG:-C.UTF-8}" LC_ALL="${LC_ALL:-C.UTF-8}"
cd "$HOME"
SRC="$DEST/chezmoi"
run_env() { XDG_CURRENT_DESKTOP="$DE" XDG_SESSION_TYPE="$DS" "$@"; }
failed=0

# Idempotency check #1: a second apply exits 0 and re-runs no run_onchange
# scripts. We deliberately do NOT use `chezmoi diff` here: chezmoi includes
# every script in the target state, so a raw diff always lists run_after
# scripts as "new file" even when nothing has drifted.
echo "--- verify: second apply + run_onchange detection ---"
apply_out="$(run_env env DOTFILES_TEST=1 DOTFILES_TEST_EXCLUDE_ROLES="$EXCL" \
    DOTFILES_TEST_NIX="$NIX" \
    chezmoi apply --verbose --source "$SRC" 2>&1)"
apply_rc=$?
if [ "$apply_rc" -ne 0 ]; then
    echo "FAIL: second apply exited $apply_rc"
    printf '%s\n' "$apply_out" | tail -30
    failed=1
fi
# A run_onchange script re-executing prints its chezmoi "script" progress
# marker (not the script body, which --verbose also echoes as a diff).
if printf '%s\n' "$apply_out" | grep -qE 'chezmoi: (run_onchange|script)'; then
    echo "FAIL: a run_onchange script re-executed on the second apply"
    failed=1
fi

# Idempotency check #2: Ansible reported changed=0 on the re-run, ignoring
# the documented xfail repo tasks. `deb822_repository` rewrites its .sources
# file on every run in this collection version (upstream module limitation);
# everything else must be changed=0.
echo "--- verify: ansible idempotency recap ---"
recap="$(printf '%s\n' "$apply_out" | grep -E 'changed=[0-9]+' | tail -1)"
echo "recap: $recap"
changed="$(printf '%s' "$recap" | grep -oE 'changed=[0-9]+' | head -1 | cut -d= -f2)"
if [ -n "${changed:-}" ] && [ "$changed" -ne 0 ]; then
    changed_tasks="$(printf '%s\n' "$apply_out" | awk '/^TASK \[/{t=$0} /changed: \[localhost\]/{print t}')"
    unexpected="$(printf '%s\n' "$changed_tasks" | grep -vE "$XFAIL_RE" || true)"
    if [ -n "$unexpected" ]; then
        echo "FAIL: ansible reported unexpected changes on re-run:"
        printf '%s\n' "$unexpected"
        failed=1
    else
        echo "ansible re-run: only known xfail repo tasks changed:"
        printf '%s\n' "$changed_tasks" | sed 's/^/  xfail: /'
    fi
fi

# Idempotency check #3: the managed dotfiles are all present and match.
# `R` (script will be run) is reported for every run_after/run_onchange script
# on every apply and is not drift. The read-source-state hook prints its own
# output on stderr/stdout, so only lines matching chezmoi's status format
# ("XY path", two status chars then a space) are considered.
echo "--- verify: chezmoi status (managed files) ---"
status_out="$(run_env chezmoi status --source "$SRC" 2>/dev/null | grep -E '^ ?[ MADRX?]{2} ' | grep -vE '^ *R ' || true)"
if [ -n "$status_out" ]; then
    echo "FAIL: chezmoi status reports drift:"
    printf '%s\n' "$status_out" | head -30
    failed=1
else
    echo "chezmoi status: clean"
fi

# Idempotency check #4: `chezmoi diff` shows no drift beyond the built-in
# script noise and the scenario's declared expect.diff_allowlist. Paths come
# from "diff --git a/<path> b/<path>" headers. Built-ins: chezmoi lists every
# .chezmoiscripts entry as a new file on every diff (scripts are source
# entries, never destination files).
echo "--- verify: chezmoi diff (allowlist) ---"
DIFF_ALLOW='@@DIFF_ALLOW@@'
diff_paths="$(run_env chezmoi diff --source "$SRC" 2>/dev/null \
    | sed -nE 's#^diff --git a/(.*) b/.*#\1#p' || true)"
remaining="$(printf '%s\n' "$diff_paths" \
    | grep -vE '^$|^\.chezmoiscripts/|^\.chezmoiversion$' || true)"
if [ -n "$DIFF_ALLOW" ]; then
    remaining="$(printf '%s\n' "$remaining" | grep -vE "$DIFF_ALLOW" | grep -vE '^$' || true)"
fi
if [ -n "$remaining" ]; then
    echo "FAIL: chezmoi diff shows drift beyond expect.diff_allowlist:"
    printf '%s\n' "$remaining" | sed 's/^/  diff: /'
    failed=1
else
    echo "chezmoi diff: clean (script noise + allowlist filtered)"
fi

[ "$failed" -eq 0 ] && echo "verify OK"
exit "$failed"
REMOTE
)"
    local diff_allow
    diff_allow="$(record_get "$record" '.expect.diff_allowlist // [] | join("|")')"
    script="$(render_script "$tmpl" \
        "DEST=$TARGET_REPO" "DE=$(record_de "$record")" "DS=$(record_ds "$record")" \
        "EXCL=$(record_exclude_roles "$record")" "GITHUB_TOKEN=$(github_token)" \
        "XFAIL_RE=$VERIFY_XFAIL_TASKS_RE" \
        "NIX=$(record_nix_flag "$record")" \
        "DIFF_ALLOW=$diff_allow")"
    printf '%s' "$script" | target_ssh_script "$port"
}
