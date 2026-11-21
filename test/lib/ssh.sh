#!/usr/bin/env bash
# ssh.sh — SSH access helpers for target lanes (container now, VM in Phase C).
#
# All remote commands run through `bash -s`/`bash -c`, never the login shell:
# the fish role changes the target's default shell, so relying on it would
# break later stages.
#
# Sourced by test/run.sh.

# ssh_key — path to the harness keypair, generated on first use
# (test/run/ is gitignored; the key is injected into containers at start).
ssh_key() {
    local dir="$DOTFILES_TEST_RUNNER_DIR/run/keys"
    local key="$dir/id_ed25519"
    if [ ! -f "$key" ]; then
        mkdir -p "$dir"
        ssh-keygen -t ed25519 -N '' -f "$key" -C dotfiles-test >/dev/null
    fi
    printf '%s' "$key"
}

ssh_public_key() { printf '%s' "$(cat "$(ssh_key).pub")"; }

# ssh_opts <array-name> — fill an array with the harness SSH options.
ssh_opts() {
    local -n _out="$1"
    _out=(
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o BatchMode=yes
        -o IdentitiesOnly=yes
        -o ConnectTimeout=10
        # Heavy guest installs (winget/DSC/mise) can stall the VM for minutes;
        # tolerate ~10 minutes of unresponsiveness before giving up.
        -o ServerAliveInterval=30
        -o ServerAliveCountMax=20
        -i "$(ssh_key)"
    )
}

SSH_TARGET_USER="${SSH_TARGET_USER:-provision}"

# target_ssh_cmd <port> <command...> — run a shell command on the target.
# The command is piped to `bash -s` so the (possibly-fish) login shell never
# re-parses it.
target_ssh_cmd() {
    local port="$1"
    shift
    local cmd="$*"
    local opts
    ssh_opts opts
    printf '%s' "$cmd" | ssh -p "$port" "${opts[@]}" "$SSH_TARGET_USER@127.0.0.1" bash -s
}

# target_ssh_cmd_stdin <port> <command...> — like target_ssh_cmd but leaves
# stdin free for data (e.g. a tar stream). The command must not contain single
# quotes (it is wrapped in single quotes for the remote shell).
target_ssh_cmd_stdin() {
    local port="$1"
    shift
    local cmd="$*"
    local opts
    ssh_opts opts
    ssh -p "$port" "${opts[@]}" "$SSH_TARGET_USER@127.0.0.1" "bash -c '$cmd'"
}

# target_ssh_script <port> [args...] — run a bash script (stdin) on the target,
# passing positional args. The heredoc at the call site should be quoted.
target_ssh_script() {
    local port="$1"
    shift
    local opts
    ssh_opts opts
    ssh -p "$port" "${opts[@]}" "$SSH_TARGET_USER@127.0.0.1" bash -s -- "$@"
}

# ssh_wait <port> [timeout-seconds]
ssh_wait() {
    local port="$1" timeout="${2:-60}" waited=0
    local opts
    ssh_opts opts
    while [ "$waited" -lt "$timeout" ]; do
        if ssh -p "$port" "${opts[@]}" "$SSH_TARGET_USER@127.0.0.1" true 2>/dev/null; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}
