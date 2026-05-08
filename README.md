# Dotfiles Management System

A dotfiles and system configuration management project using **chezmoi**, **mise**, and **Ansible**, with the goal to create an idempotent, declarative setup that allows easy reproduction.

## Supported Platforms

- Linux (Debian, Ubuntu, Pop!\_OS, Fedora)
- Windows 11 Native
- WSL (Windows Subsystem for Linux)
- Multiple Desktop Environments: GNOME, COSMIC, KDE

## Architecture

| Tool | Purpose |
| ------ | --------- |
| **chezmoi** | Dotfiles management, machine classification prompts, bootstrap orchestration |
| **mise** | User-space development tool installation (languages, CLI tools) |
| **Ansible** | System-wide configuration, services, desktop environment settings |
| **WinGet DSC** | Windows native declarative package/configuration management |

## Quick Start

### Linux / WSL

```bash
./bootstrap.sh
```

### Windows 11 Native

```powershell
.\bootstrap.ps1
```

## Testing

```bash
# Health checks
test/health-check.sh

# Dry runs
test/dry-run.sh
```

## Directory Structure

- `chezmoi/` — Chezmoi source state (dotfiles, scripts, hooks, templates)
- `ansible/` — Ansible playbooks, roles, group_vars, inventory
- `test/` — Health check and dry-run scripts

## Machine Classification

During `chezmoi apply`, you'll be prompted for:

- **Category** (multi-choice): work, personal, gaming, multimedia, development
- **Form Factor**: desktop, laptop, server
- **Desktop Environment** (Linux only): gnome, cosmic, kde, none

These classifications drive conditional dotfile installation and Ansible role selection.

## Package Installation Priority

1. **mise** — if available in registry (user-space tools)
2. **WinGet DSC** — on Windows native, if available
3. **Ansible roles** — system packages and configurations
4. **Chezmoi scripts** — anything not covered above, declared in `.chezmoidata/packages.yaml`

## Password Management

Bitwarden CLI (`bw`) is installed by the `read-source-state.pre` hook before dotfiles are fetched. Templates can use `{{ bitwardenFields ... }}` to retrieve secrets.

## License

MIT
