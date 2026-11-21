#!/usr/bin/env bash
# ports.sh — TCP port allocation for VM/Windows targets.
#
# Range 2300-2399, one lock file per port under test/run/ports/. Port 2333 is
# permanently reserved for the Windows lane (matches ansible/winvm.yaml) and is
# never handed out by the generic allocator — unless the lane's port was
# overridden (see ports_windows_alloc), in which case 2333 rejoins the pool.
# The 23xx prefix keeps the test lanes off the user's own 22xx VM forwards
# (VirtualBox/Oracle machines, e.g. win11auto3 on 2233).
#
# Sourced by test/run.sh. Unused by the lint stage (Phase A); consumed by
# Phases B-D.

ports_dir() { printf '%s/run/ports' "$DOTFILES_TEST_RUNNER_DIR"; }

PORTS_RANGE_START=2300
PORTS_RANGE_END=2399
PORTS_WINDOWS_RESERVED=2333

# ports_windows_alloc — acquire the Windows lane's SSH port.
#
# Default is the permanently reserved 2333 (ansible/winvm.yaml convention), a
# hard error when busy. DOTFILES_TEST_WINDOWS_PORT overrides it so the test lane
# can coexist with a real Windows machine that already forwards SSH on 22xx
# (e.g. the user's VirtualBox VM): the configured port is tried first, and when
# busy the lane falls back to a free port from the generic range. The generic
# allocator is also allowed to hand out 2333 in that mode, since the lane is not
# using it.
ports_windows_alloc() {
    local dir f preferred="${DOTFILES_TEST_WINDOWS_PORT:-}"
    dir="$(ports_dir)"
    mkdir -p "$dir"
    if [ -z "$preferred" ] || [ "$preferred" = "$PORTS_WINDOWS_RESERVED" ]; then
        f="$dir/$PORTS_WINDOWS_RESERVED.lock"
        if (set -o noclobber; : >"$f") 2>/dev/null; then
            printf '%s\n' "$PORTS_WINDOWS_RESERVED"
            return 0
        fi
        log_error "Windows SSH port $PORTS_WINDOWS_RESERVED is already reserved; set DOTFILES_TEST_WINDOWS_PORT to run alongside the other Windows VM"
        return 1
    fi
    f="$dir/$preferred.lock"
    if (set -o noclobber; : >"$f") 2>/dev/null; then
        printf '%s\n' "$preferred"
        return 0
    fi
    log_warn "Windows port $preferred is busy; falling back to a free port from $PORTS_RANGE_START-$PORTS_RANGE_END"
    for p in $(seq "$PORTS_RANGE_START" "$PORTS_RANGE_END"); do
        f="$dir/$p.lock"
        if (set -o noclobber; : >"$f") 2>/dev/null; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    log_error "no free port in $PORTS_RANGE_START-$PORTS_RANGE_END"
    return 1
}

# ports_alloc — print a free port and create its lock file. Returns 1 if none.
# Skips the reserved 2333 only while the Windows lane is pinned to it (no
# DOTFILES_TEST_WINDOWS_PORT override).
ports_alloc() {
    local dir p f
    dir="$(ports_dir)"
    mkdir -p "$dir"
    for p in $(seq "$PORTS_RANGE_START" "$PORTS_RANGE_END"); do
        [ -z "${DOTFILES_TEST_WINDOWS_PORT:-}" ] && [ "$p" -eq "$PORTS_WINDOWS_RESERVED" ] && continue
        f="$dir/$p.lock"
        if (set -o noclobber; : >"$f") 2>/dev/null; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    log_error "no free port in $PORTS_RANGE_START-$PORTS_RANGE_END"
    return 1
}

# ports_release <port>
ports_release() {
    rm -f "$(ports_dir)/$1.lock"
}

# ports_release_all — remove every lock file (teardown safety net).
ports_release_all() {
    rm -f "$(ports_dir)"/*.lock 2>/dev/null || true
}
