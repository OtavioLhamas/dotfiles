#!/bin/bash
# Dry run script for dotfiles system
# Performs dry runs for both chezmoi and ansible without making changes

set -euo pipefail

FAILED=0

# --- Chezmoi dry run ---
if command -v chezmoi &>/dev/null; then
    echo "Running chezmoi apply --dry-run --verbose..."
    chezmoi apply --source chezmoi --dry-run --verbose || {
        echo "ERROR: chezmoi dry run failed"
        FAILED=1
    }

    # Check specific scripts (NOTE: all .chezmoiscripts should be .tmpl files)
    if [ -d "chezmoi/.chezmoiscripts" ]; then
        for script in chezmoi/.chezmoiscripts/run_after_*.sh.tmpl; do
            if [ -f "$script" ]; then
                # Generate the script from template and syntax check it
                chezmoi execute-template --source chezmoi <"$script" | bash -n || {
                    echo "ERROR: Syntax error in generated script from $(basename "$script")"
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
if command -v ansible-playbook &>/dev/null; then
    if [ -f "ansible/inventory.yaml" ] && [ -f "ansible/main.yaml" ]; then
        echo "Running ansible-playbook --check..."

        ansible-playbook \
            -i ansible/inventory.yaml \
            --check \
            --diff \
            "$EXTRA_VARS" \
            ansible/main.yaml || {
            echo "ERROR: Ansible dry run failed"
            FAILED=1
        }

    else
        echo "WARNING: Ansible files not found, skipping ansible dry run"
    fi
else
    echo "WARNING: ansible-playbook not found in PATH"
fi

# --- Summary ---
echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "   Dry run PASSED"
else
    echo "   Dry run FAILED"
fi

exit "$FAILED"
