#Requires -RunAsAdministrator
# Dotfiles bootstrap script for Windows 11 Native
# Minimal bootstrap: installs chezmoi, enables OpenSSH Server, installs mise

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Write-Host "=== Dotfiles Bootstrap (Windows Native) ===" -ForegroundColor Cyan

# Install winget if missing (should be present on Windows 11)
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Error "winget is required but not found. Please install App Installer from Microsoft Store."
    exit 1
}

# Install git if missing
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Installing git..."
    winget install --id Git.Git --source winget --accept-source-agreements --accept-package-agreements
}

# Install chezmoi
if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
    Write-Host "Installing chezmoi..."
    Invoke-Expression (Invoke-RestMethod -Uri https://get.chezmoi.io/ps1)
} else {
    Write-Host "chezmoi already installed"
}

# Install mise for Windows
if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
    Write-Host "Installing mise..."
    winget install --id jdx.mise --source winget --accept-source-agreements --accept-package-agreements
} else {
    Write-Host "mise already installed"
}

# Enable OpenSSH Server (needed for Ansible from WSL)
$sshServer = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
if ($sshServer.State -ne 'Installed') {
    Write-Host "Enabling OpenSSH Server..."
    Add-WindowsCapability -Online -Name $sshServer.Name
    Start-Service sshd
    Set-Service -Name sshd -StartupType 'Automatic'
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue
    Write-Host "OpenSSH Server enabled"
} else {
    Write-Host "OpenSSH Server already enabled"
}

# Ensure sshd is running
$sshdStatus = Get-Service sshd -ErrorAction SilentlyContinue
if ($sshdStatus -and $sshdStatus.Status -ne 'Running') {
    Start-Service sshd
}

Write-Host "Bootstrap complete. Run the following to init and apply:" -ForegroundColor Green
Write-Host "  chezmoi init <your-repo-url>"
Write-Host "  chezmoi apply"
