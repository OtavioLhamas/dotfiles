#!/bin/bash
# Dry run script for dotfiles system
# Performs dry runs for both chezmoi and ansible without making changes

set -euo pipefail

echo "=========================================="
echo "   Dotfiles System Dry Run"
echo "=========================================="

FAILED=0

# --- Chezmoi dry run ---
echo ""
echo "--- Chezmoi Dry Run ---"

if command -v chezmoi &>/dev/null; then
    echo "Running chezmoi apply --dry-run --verbose..."
    chezmoi apply --dry-run --verbose || {
        echo "ERROR: chezmoi dry run failed"
        FAILED=1
    }
    
    # Check specific scripts
    if [ -d "chezmoi/.chezmoiscripts" ]; then
        for script in chezmoi/.chezmoiscripts/run_after_*.sh; do
            if [ -f "$script" ]; then
                echo ""
                echo "Dry run: $(basename "$script")"
                # We can't truly dry-run a shell script, but we can syntax check it
                bash -n "$script" || {
                    echo "ERROR: Syntax error in $(basename "$script")"
                    FAILED=1
                }
            fi
        done
    fi
else
    echo "ERROR: chezmoi not found in PATH"
    FAILED=1
fi

# --- Ansible dry run ---
echo ""
echo "--- Ansible Dry Run ---"

if command -v ansible-playbook &>/dev/null; then
    if [ -f "ansible/inventory.yaml" ] && [ -f "ansible/main.yaml" ]; then
        echo "Running ansible-playbook --check..."
        
        # Pass chezmoi data as extra vars if available
        EXTRA_VARS=""
        if command -v chezmoi &>/dev/null; then
            CHEZMOI_DATA=$(chezmoi data --format=json | jq '.data // {}')
            if [ -n "$CHEZMOI_DATA" ] && [ "$CHEZMOI_DATA" != "{}" ]; then
                echo "$CHEZMOI_DATA" > /tmp/chezmoi-data-dryrun.json
                EXTRA_VARS="-e @/tmp/chezmoi-data-dryrun.json"
            fi
        fi
        
        ansible-playbook \
            -i ansible/inventory.yaml \
            --check \
            --diff \
            $EXTRA_VARS \
            ansible/main.yaml || {
            echo "ERROR: Ansible dry run failed"
            FAILED=1
        }
        
        rm -f /tmp/chezmoi-data-dryrun.json
    else
        echo "WARNING: Ansible files not found, skipping ansible dry run"
    fi
else
    echo "WARNING: ansible-playbook not found in PATH"
fi

# --- Summary ---
echo ""
echo "=========================================="
if [ "$FAILED" -eq 0 ]; then
    echo "   Dry run PASSED"
else
    echo "   Dry run FAILED"
fi
echo "=========================================="

exit "$FAILED"
