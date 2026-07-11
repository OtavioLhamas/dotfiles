# Dotfiles bootstrap script for Windows 11 Native
# Minimal bootstrap: installs chezmoi only, everything else is handled by chezmoi scripts

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$bin_dir = "$HOME/.local/bin"
$chezmoi_path = "$bin_dir/chezmoi"

# Install chezmoi
if (-not ($chezmoi_cmd = Get-Command $chezmoi_path -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path $bin_dir)) { New-Item -ItemType Directory -Path $bin_dir -Force }

    Write-Host "Installing chezmoi..."
    iex "&{$(irm 'https://get.chezmoi.io/ps1')} -b '$bin_dir'"
    $chezmoi_cmd = $chezmoi_path
} else {
    Write-Host "chezmoi already installed"
    $chezmoi_cmd = $chezmoi_cmd.Source
}

# Get the script directory
$script_dir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$source_path = Join-Path $script_dir "chezmoi"

Write-Host "Running 'chezmoi init OtavioLhamas --apply --source=$script_dir\chezmoi'" -ForegroundColor Cyan
& $chezmoi_cmd init OtavioLhamas --apply --source="$source_path"
