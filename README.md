# Dotfiles Management System

> [!WARNING]
> This is a work in progress, current commit might be in a broken state

A dotfiles and system configuration management project using **chezmoi**, **mise**, and **Ansible**, with the goal to create an idempotent, declarative setup that allows for easy reproduction.

## Quick Start

### Linux / WSL

```bash
git clone https://github.com/OtavioLhamas/dotfiles.git ~/.local/share/chezmoi/
~/.local/share/chezmoi/bootstrap.sh
```

or

```bash
curl https://github.com/OtavioLhamas/dotfiles.git/bootstrap.sh | sh
```

### Windows 11 Native

Make sure you have the necessary execution policy:

```powershell
# Requires elevated privileges
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine
```

Enable winget configure:

```powershell
winget configure --enable
```

```powershell
git clone https://github.com/OtavioLhamas/dotfiles.git ~/.local/share/chezmoi/
~/.local/share/chezmoi/bootstrap.ps1
```

or

```powershell
irm https://github.com/OtavioLhamas/dotfiles.git/bootstrap.ps1 | iex
```

## Supported Platforms

Should work on any Debian, Ubuntu, or Fedora based distro, and Windows 11.

These are the specific versions I validated:

- Debian 13
- Ubuntu 24.04
- Ubuntu Server 24.04
- Pop!\_OS 22.04, 24.04
- Fedora 44 Workstation Live
- Windows 11 25H2
- WSL (Windows Subsystem for Linux)

- Desktop Environments: GNOME, COSMIC

## Architecture

| Tool | Purpose |
| ------ | --------- |
| **chezmoi** | Dotfiles management, machine classification prompts, bootstrap orchestration |
| **mise** | User-space development tool installation (languages, CLI tools) |
| **Ansible** | System-wide configuration, services, desktop environment settings |
| **WinGet DSC** | Windows native declarative package/configuration management |

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

## Flowchart

```mermaid
---
config:
  theme: dark
  layout: dagre
---
flowchart TB
    Start(("Start: Fresh Machine")) --> OS_Check{"Identify Target OS"}
    OS_Check -- Linux --> Lin_Start["Run: bootstrap.sh"]
    OS_Check -- Windows 11 --> Win_Start["Run: bootstrap.ps1"]
    Win_Start & Lin_Start --> Bootstrap["Install chezmoi &\n`chezmoi init --apply`"]
    Bootstrap --> Pre_State_Hook["Chezmoi Pre-State Hook"]
    Pre_State_Hook --> BW_Auth["Install & Authenticate Bitwarden CLI\nFetch Git Access Tokens"]
    BW_Auth --> Ext_Clone["Git Clones Externals & Submodules"]
    Ext_Clone -- Linux --> Lin_Before["Run: run_before*.sh"]
    Ext_Clone -- Windows --> Win_Before["Run: run_before*.ps1"]
    Win_Before & Lin_Before--> Mise_Bin["Install mise"]
    Mise_Bin --> Mise_Apply["chezmoi apply: Apply State Files"]
    Mise_Apply -- Linux --> Lin_After["Run: run_after*.sh"]
    Mise_Apply -- Windows --> Win_After["Run: run_after*.ps1"]
    Lin_After --> Lin_Provision["Provision Setup: mise install, Execute Ansible Playbooks"]
    Win_After --> Win_Provision["Provision Setup: mise install, winget configure"]
    Win_Provision --> WSL_Install["Configure WSL"]
    WSL_Install --> WSL_User["Inject $USER to /etc/wsl.conf"]
    WSL_User --> WSL_Boot["WSL Guest: Execute Linux bootstrap.sh"]
    WSL_Boot --> Lin_Start
    Lin_Provision -- Standard Linux --> Final(("ENVIRONMENT READY"))
    Lin_Provision -- WSL Guest --> SSH_Loopback["Ansible Play: Target Windows Host via Local Loopback SSH"]
    SSH_Loopback --> Final
```

## License

MIT
