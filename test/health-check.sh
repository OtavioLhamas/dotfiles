#!/bin/bash
# Health check script for dotfiles system
# Verifies chezmoi, mise, ansible, and other tools are properly configured

FAILED=0

WARNING=()
ERROR=()

# --- Chezmoi checks ---
if command -v chezmoi &>/dev/null; then
    CHEZMOI_SOURCE="./chezmoi"
    output=$(chezmoi doctor --source "$CHEZMOI_SOURCE")
    status=$?

    if [ $status -ne 0 ]; then
        FAILED=1
        ERROR+=("chezmoi doctor: $output")
    fi

    warnings=$(echo "$output" | grep -i "warning|error")

    if [[ -n "$warnings" ]]; then
        WARNING+=("chezmoi doctor: $(echo "$warnings" | xargs)")
    fi
else
    ERROR+=("chezmoi: Command not found in PATH")
    FAILED=1
fi

# --- Mise checks ---
if command -v mise &>/dev/null; then
    # Capture stdout (Problems)
    report=$(mise doctor 2>/dev/null)

    status=$?

    if [ $status -ne 0 ]; then
        ERROR+=("$report")
        FAILED=1
    fi

    # Capture stderr (Warnings)
    logs=$(mise doctor 2>&1 >/dev/null)

    if [ -n "$logs" ]; then
        WARNING+=("$logs")
    fi

    if [ ! -f "$HOME/.config/mise/config.toml" ]; then
        WARNING+=("mise: config.toml not found at expected location")
    fi
else
    ERROR+=("mise: Command not found in PATH")
    FAILED=1
fi

# --- Ansible checks ---
if command -v ansible &>/dev/null; then
    # TODO: actually test ansible inventory stderr
    if [ -f "ansible/inventory.yaml" ]; then
        ansible-inventory -i ansible/inventory.yaml --list &>/dev/null || FAILED=1
    fi
else
    echo "WARNING: ansible not found in PATH"
fi

# --- Bitwarden checks ---
if command -v bw &>/dev/null; then

    # TODO: actually test the bw status output
    BW_STATUS=$(bw status 2>/dev/null | yq -r '.status // "unauthenticated"')
    echo "Bitwarden status: $BW_STATUS"

    if [ "$BW_STATUS" != "unlocked" ]; then
        echo "WARNING: Bitwarden vault is not unlocked. Run:"
        echo "  export BW_SESSION=\$(bw unlock --raw)"
    fi
else
    ERROR+=("bw (Bitwarden CLI) not found in PATH")
    FAILED=1
fi

# --- Summary ---
if [ "$FAILED" -eq 0 ]; then
    echo "Health check PASSED"
else
    echo "Health check FAILED"
fi

if [ ${#WARNING[@]} -ne 0 ]; then
    echo "    WARNINGS:"
    for warn in "${WARNING[@]}"; do echo "    - $warn"; done
fi

if [ ${#ERROR[@]} -ne 0 ]; then
    echo "    ERRORS:"
    for error in "${ERROR[@]}"; do echo "    - $error"; done
fi

exit "$FAILED"
