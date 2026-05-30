# Dotfiles Management System — Agent Guide

## Project Overview

This repository manages dotfiles, packages, installations, system configurations, and environment setup across multiple platforms. It is designed to work after a fresh OS install, on a new machine, or on a VPS.

## Domain Language

See [CONTEXT-MAP.md](./CONTEXT-MAP.md) for context boundaries and glossaries ([chezmoi/CONTEXT.md](./chezmoi/CONTEXT.md), [ansible/CONTEXT.md](./ansible/CONTEXT.md)). Use the terms defined there.

## Key Tools


| Tool | Role |
|------|------|
| **chezmoi** | Dotfiles source state, machine classification prompts, lifecycle scripts |
| **mise** | User-space development tools and languages |
| **Ansible** | System-wide configuration, services, desktop environment settings |
| **WinGet DSC** | Windows native declarative package management |


### Package Priority

1. **mise** — if tool is in mise registry (defined in `dot_config/mise/config.toml`)
2. **WinGet DSC** — on Windows native (`dot_config/winget.dsc.yaml`)
3. **Ansible** — system packages via roles (`ansible/roles/<role>/`)
4. **Chezmoi scripts** — fallback, declared in `.chezmoidata/packages.yaml`


### Windows Support

- **Native Windows 11**: Uses PowerShell + WinGet DSC + PowerShell scripts. Ansible is not run.
- **WSL**: Runs the full Linux flow. Ansible targets both WSL `localhost` and the Windows native host via SSH.
- `dry-run.sh` has a known bug: `$EXTRA_VARS` is unbound — the Ansible section will fail. The chezmoi section is the useful one.
- Health check warnings about Bitwarden being unauthenticated or mise version updates are expected in dev environments — not failures.

## Chezmoi Source Path

Chezmoi source lives in `./chezmoi/`, not the default `~/.local/share/chezmoi`. All chezmoi commands need `--source ./chezmoi`:

```bash
chezmoi apply --source ./chezmoi
chezmoi diff --source ./chezmoi
chezmoi execute-template --source ./chezmoi < template.tmpl
```

## Data Flow

1. `chezmoi init` → `hooks.read-source-state.pre` → installs raw prerequisites (git, curl, yq, bw). This hook is **not** a template — no Go template features available.
2. `chezmoi apply` → prompts for classification → writes `chezmoi.yaml`
3. `run_once_before_10-install-managers` → installs mise
4. `run_after_10-install-packages` → installs fallback packages from `.chezmoidata/packages.yaml`
5. `run_after_20-provision` → runs `mise install`, generates `ansible/inventory.yaml`, runs Ansible playbook

## Package Priority

When adding a new tool, place it in the highest tier that supports it:

1. **mise** — `chezmoi/dot_config/mise/config.toml`
2. **WinGet DSC** — `chezmoi/dot_config/winget.dsc.yaml` (Windows native only)
3. **Ansible roles** — `ansible/roles/<role>/`
4. **Chezmoi scripts** — `.chezmoidata/packages.yaml` (last resort)

## Templating

- All `.chezmoiscripts` are `.tmpl` files — Go templates evaluated by chezmoi before execution
- Prefer template conditionals (`{{ if }}`, `{{ range }}`) over shell conditionals
- Use `.chezmoi.*` variables for OS/arch/distro detection at template time
- Reusable template snippets live in `.chezmoitemplates/` (e.g., `package` for category-filtered package installation)
- `ensure-pre-requisites.sh` under `.chezmoihooks/` is the **only** non-template file — it runs before chezmoi parses anything

## Conventions

- Always use `.yaml` extension, never `.yml`
- Ansible roles are single-responsibility (one role per concern)
- `ansible/inventory.yaml` is fully regenerated on each `chezmoi apply` — never edit by hand
- Keep `bootstrap.sh`/`bootstrap.ps1` minimal — they only install chezmoi and git
- Windows native uses PowerShell + WinGet DSC; Ansible is not run on Windows native
- Under WSL, Ansible targets both `localhost` and `windows_native` (via SSH to Windows host IP)

## Testing

After making changes, always verify:

```bash
./test/health-check.sh
./test/dry-run.sh
```
