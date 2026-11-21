#!/usr/bin/env bash
# health-check.sh — target-agnostic health checks (doctor equivalent).
#
# Runs on a target, locally or over SSH. Phase A provides the function set;
# Phases B-D consume it from the container/VM/windows lanes. The legacy
# test/health-check.sh keeps working as a standalone script until Phase E
# replaces it with a wrapper around this module.
#
# Sourced by test/run.sh.

# chezmoi doctor rows that fail for environmental (not provisioning) reasons:
#   hardlink — the source tree lives on a git/overlay filesystem in the
#              container lanes, so /tmp is a different device and hardlinks
#              cannot be created. Irrelevant to deployed state.
HEALTH_CHECK_DOCTOR_IGNORE="${HEALTH_CHECK_DOCTOR_IGNORE:-hardlink}"

# health_check_script — emit the remote check script on stdout.
health_check_script() {
    cat <<'SCRIPT'
set -u
failed=0
# Tooling installed by the harness / bootstrap lives here.
export PATH="$HOME/.local/bin:$PATH"
export LANG="${LANG:-C.UTF-8}" LC_ALL="${LC_ALL:-C.UTF-8}"

if command -v chezmoi >/dev/null 2>&1; then
    doctor_out="$(chezmoi doctor 2>&1)"
    doctor_rc=$?
    printf '%s\n' "$doctor_out"
    # A nonzero doctor rc is only a failure if the offending rows are not
    # environment-specific (see HEALTH_CHECK_DOCTOR_IGNORE in the lib).
    if [ "$doctor_rc" -ne 0 ]; then
        bad="$(printf '%s\n' "$doctor_out" | awk -v ignore="@@IGNORE_ROWS@@" '
            BEGIN { n=split(ignore, a, ","); for (i=1;i<=n;i++) skip[a[i]]=1 }
            $1=="error" && !($2 in skip) { print $2 }')"
        [ -n "$bad" ] && { echo "chezmoi doctor: unexpected errors: $bad"; failed=1; }
    fi
else
    echo "chezmoi: NOT FOUND"
    failed=1
fi

if command -v mise >/dev/null 2>&1; then
    mise doctor 2>&1 || true
fi

if command -v ansible-inventory >/dev/null 2>&1; then
    ansible-inventory --list >/dev/null 2>&1 || true
fi

if command -v bw >/dev/null 2>&1; then
    bw_status="$(bw status 2>/dev/null || true)"
    echo "bitwarden: ${bw_status:-unknown}"
fi

if [ "$failed" -eq 0 ]; then
    echo "health-check: PASSED"
else
    echo "health-check: FAILED"
fi
exit "$failed"
SCRIPT
}

# health_check_local — run the checks on this machine.
health_check_local() {
    bash -s <<<"$(health_check_script)"
}

# health_check_ssh [ssh args...] — run the checks on a remote target.
health_check_ssh() {
    ssh "$@" bash -s <<<"$(health_check_script)"
}
