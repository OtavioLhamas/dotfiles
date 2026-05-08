#!/bin/bash
# Health check script for dotfiles system
# Verifies chezmoi, mise, ansible, and other tools are properly configured

set -euo pipefail

echo "=========================================="
echo "   Dotfiles System Health Check"
echo "=========================================="

FAILED=0

# --- Chezmoi checks ---
echo ""
echo "--- Chezmoi ---"

if command -v chezmoi &>/dev/null; then
    echo "chezmoi: $(chezmoi --version | head -1)"
    
    echo ""
    echo "Running chezmoi doctor..."
    chezmoi doctor || FAILED=1
    
    echo ""
    echo "Chezmoi data:"
    chezmoi data --format=json | jq '.data // {}' || FAILED=1
    
    echo ""
    echo "Testing template execution (category):"
    chezmoi execute-template '{{ .category }}' || FAILED=1
else
    echo "ERROR: chezmoi not found in PATH"
    FAILED=1
fi

# --- Mise checks ---
echo ""
echo "--- Mise ---"

if command -v mise &>/dev/null; then
    echo "mise: $(mise --version)"
    
    echo ""
    echo "Running mise doctor..."
    mise doctor || FAILED=1
    
    echo ""
    echo "Mise config:"
    if [ -f "$HOME/.config/mise/config.toml" ]; then
        cat "$HOME/.config/mise/config.toml"
    else
        echo "Warning: mise config.toml not found at expected location"
    fi
else
    echo "WARNING: mise not found in PATH"
fi

# --- Ansible checks ---
echo ""
echo "--- Ansible ---"

if command -v ansible &>/dev/null; then
    echo "ansible: $(ansible --version | head -1)"
    
    if [ -f "ansible/inventory.yaml" ]; then
        echo ""
        echo "Inventory syntax check:"
        ansible-inventory -i ansible/inventory.yaml --list || FAILED=1
    fi
else
    echo "WARNING: ansible not found in PATH"
fi

# --- Bitwarden checks ---
echo ""
echo "--- Bitwarden ---"

if command -v bw &>/dev/null; then
    echo "bw: $(bw --version)"
    
    BW_STATUS=$(bw status 2>/dev/null | jq -r '.status // "unauthenticated"')
    echo "Bitwarden status: $BW_STATUS"
    
    if [ "$BW_STATUS" != "unlocked" ]; then
        echo "WARNING: Bitwarden vault is not unlocked. Run:"
        echo "  export BW_SESSION=\$(bw unlock --raw)"
    fi
else
    echo "WARNING: bw (Bitwarden CLI) not found in PATH"
fi

# --- Summary ---
echo ""
echo "=========================================="
if [ "$FAILED" -eq 0 ]; then
    echo "   Health check PASSED"
else
    echo "   Health check FAILED"
fi
echo "=========================================="

exit "$FAILED"
