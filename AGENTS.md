# Dotfiles Management System — Agent Guide

## Project Overview

This repository brings a machine up to a **minimum desirable state** (see [README Scope](./README.md#scope)): it installs packages, places dotfiles, applies defaults, and configures systems across multiple platforms. It is designed to work after a fresh OS install, on a new machine, or on a VPS.

This is a **provisioning** project, not a declarative configuration manager. It is **idempotent but not convergent**: it adds, overwrites, and configures toward the declared state, but never uninstalls, removes, or reconciles the system back to it. The declaration is a floor, not a ceiling.

## Domain Language

See [CONTEXT-MAP.md](./CONTEXT-MAP.md) for context boundaries and glossaries ([chezmoi/CONTEXT.md](./chezmoi/CONTEXT.md), [ansible/CONTEXT.md](./ansible/CONTEXT.md)). Use the terms defined there.

## Key Tools

| Tool | Role |
|------|------|
| **chezmoi** | Dotfiles source state, machine classification prompts, lifecycle scripts |
| **mise** | User-space development tools and languages |
| **Nix / Home Manager** | User-level packages + configs on Linux/WSL (flake in `chezmoi/nix/`); never duplicates mise-managed tools or chezmoi-managed files |
| **Ansible** | System-wide configuration requiring multi-step setup (repos, GPG keys, flatpaks, services) |
| **WinGet DSC** | Windows native declarative package management |

## Architecture: Dependency Layers (Phases)

Provisioning is organized around dependency layers, not around tools. Every phase only depends on previous phases.

| Phase | Layer | Mechanism |
|-------|-------|-----------|
| **0** | Bootstrap | `bootstrap.sh` / `bootstrap.ps1` — installs chezmoi only |
| **1** | Native toolchains | `hooks.read-source-state.pre` — bare essentials (git, curl, yq, bw), then reads `requirements.yaml` / `winget-toolchains.dsc.yaml` to install compilers, build tools, dev libraries |
| **2** | Language runtimes & package managers | `run_once_before_10-install-mise` installs mise itself; dotfiles deployed (config.toml, winget.dsc.yaml); `run_onchange_after_20-mise-install` + `run_onchange_after_25-winget-configure` apply tools with change detection via SHA256 hashes |
| **3** | System configuration | `run_onchange_after_30-install-packages` installs simple apt/dnf packages from `packages.yaml`; `run_after_40-ansible-provision` runs Ansible for multi-step roles; `run_after_50-wsl` sets up WSL on Windows |

### Phase 1 Declarative Files

- **requirements.yaml** — `.chezmoidata/requirements.yaml`: Linux system toolchain packages (gcc, build-essential, libreadline-dev, etc.). Read by the hook via `yq`.
- **winget-toolchains.dsc.yaml** — `.chezmoidata/winget-toolchains.dsc.yaml`: Windows toolchain DSC (VS BuildTools, curl, git). Read by the hook via `winget configure`.
- **dot_buildtools.vsconfig** — VS workload configuration. Applied by the hook after VS BuildTools installation via `vs_installer.exe modify`.

### Package Placement Heuristic

| Question | Answer |
|----------|--------|
| Is it a compiler/build-tool/dev-library? | → `requirements.yaml` (Phase 1) |
| Is it in the mise registry? | → `dot_config/mise/config.toml` (Phase 2) |
| Is it Windows native and available via winget? | → `dot_config/winget.dsc.yaml` (Phase 2) |
| Is it a user-space package not in mise, or user-level config that would be an Ansible role? | → `chezmoi/nix/` Home Manager flake (Phase 3) |
| Is it a single `apt/dnf install` from default repos? | → `.chezmoidata/packages.yaml` (Phase 3a) |
| Does it need repo setup, GPG key, flatpak, or post-install? | → Ansible role (Phase 3b) |

## Chezmoi Source Path

Chezmoi source lives in `./chezmoi/`, not the default `~/.local/share/chezmoi`. All chezmoi commands need `--source ./chezmoi`:

```bash
chezmoi apply --source ./chezmoi
chezmoi diff --source ./chezmoi
chezmoi execute-template --source ./chezmoi < template.tmpl
```

## Data Flow

1. `bootstrap.sh/ps1` → installs chezmoi → `chezmoi init --apply`
2. `hooks.read-source-state.pre` → installs bare essentials (git, curl, yq, bw) → reads `requirements.yaml` / `winget-toolchains.dsc.yaml` → installs native toolchains
3. Machine classification prompts → writes `chezmoi.yaml`
4. `run_once_before_10-install-mise` → installs mise
5. Dotfiles deployed (mise config.toml, winget.dsc.yaml, etc.)
6. `run_onchange_after_20-mise-install` → runs `mise install` (only when config.toml changes)
7. `run_onchange_after_25-winget-configure` → runs `winget configure` (only when DSC changes, Windows only)
8. `run_once_before_15-install-nix` → installs Nix (multi-user daemon, one-time, Linux/WSL only)
9. `run_onchange_after_35-home-manager-switch` → runs `home-manager switch --flake "$NIX_DIR#otavio"` with machine classification exported as `CHEZMOI_*` env vars (change-detected, Linux/WSL only; after mise so mise wins PATH, before Ansible)
10. `run_onchange_after_30-install-packages` → installs simple packages from `.chezmoidata/packages.yaml` (only when file changes)
11. `run_after_40-ansible-provision` → generates `ansible/inventory.yaml`, runs Ansible playbook
12. `run_after_50-wsl` → WSL setup (Windows only)

### Windows Support

- **Native Windows 11**: Uses PowerShell + WinGet DSC + PowerShell scripts. Ansible is not run.
- **WSL**: Runs the full Linux flow. Ansible targets both WSL `localhost` and the Windows native host via SSH.
- `test/dry-run.sh` is interactive by design (uses `-K` unless `DOTFILES_TEST` is set); use `test/run.sh run --stage lint --all` for the non-interactive path.
- Health check warnings about Bitwarden being unauthenticated or mise version updates are expected in dev environments — not failures.

## Templating

- All `.chezmoiscripts` are `.tmpl` files — Go templates evaluated by chezmoi before execution
- Prefer template conditionals (`{{ if }}`, `{{ range }}`) over shell conditionals
- Use `.chezmoi.*` variables for OS/arch/distro detection at template time
- Reusable template snippets live in `.chezmoitemplates/` (e.g., `package` for category-filtered package installation)
- Machine classification (desktop environment, display server) lives in `.chezmoi.yaml.tmpl`; the test runner derives DE/DS for a scenario by rendering that template, so the two never drift
- `.chezmoihooks/` scripts are the **only** non-template files — they run before chezmoi parses anything
- `scriptEnv` in `.chezmoi.yaml.tmpl` provides environment variables to all scripts and hooks

### Change Detection

Scripts with `run_onchange_after_` prefix re-run only when their (generated) content changes. Use the SHA256 comment pattern to tie a script's execution to another file:

```bash
#!/bin/bash
# config file changed: {{ include "path/to/file" | sha256sum }}
mise install
```

When `path/to/file` changes, the SHA256 in the comment changes → the script content changes → chezmoi re-runs it.

## Conventions

- Always use `.yaml` extension, never `.yml`
- Provisioning is **additive**: never add logic that uninstalls, removes, or reconciles the system toward the declared state — the declaration is a floor, not a ceiling
- Ansible roles are single-responsibility (one role per concern)
- `ansible/inventory.yaml` is fully regenerated on each `chezmoi apply` — never edit by hand
- Keep `bootstrap.sh`/`bootstrap.ps1` minimal — they only install chezmoi
- Windows native uses PowerShell + WinGet DSC; Ansible is not run on Windows native
- Under WSL, Ansible targets both `localhost` and `windows_native` (via SSH to Windows host IP)
- `scriptEnv` in chezmoi config provides shared environment variables to all scripts
- Shared shell environment variables (EDITOR, MANPAGER, FZF_*, ...) are single-sourced in mise's `[env]` table (`dot_config/mise/config.toml.tmpl`) — not duplicated per shell, and never `home.sessionVariables`
- Test artifacts (`test/logs/`, `test/images/golden/`, built ISOs/qcow2 images, `test/run/`) are gitignored and never committed

## Testing

The test suite is a non-interactive harness driven by `test/run.sh`. Use it instead of the legacy scripts.

Run this before finishing any change (seconds, no target needed):

```bash
./test/run.sh run --stage lint --all
```

| Command | Purpose |
|---------|---------|
| `./test/run.sh run --stage lint --all` | Host-only lint across every scenario data variant |
| `./test/run.sh doctor-host` | Report which lanes (lint/container/vm/windows) are usable on this machine |
| `./test/run.sh scenarios` | List scenarios from `test/matrix.yaml` |
| `./test/run.sh run --list [selectors]` | Resolve and print targets without executing |

Selectors are AND-composed: `--scenario`, `--image`, `--distro`, `--os`, `--lane`. Variant overrides (`--de`, `--ds`, `--form`, `--category`) synthesize an ephemeral scenario when no `--scenario` is given. Other flags: `--stage <list>`, `--parallel <n>`, `--fail-fast`, `--all`.

Harness environment variables — set by the harness, **never in interactive shells**:

- `DOTFILES_TEST` — switches `run_after_40-ansible-provision` and `test/dry-run.sh` from interactive `-K` to non-interactive `--become-password-file`.
- `DOTFILES_TEST_BECOME_FILE` — path to the become-password file (empty for NOPASSWD sudo).
- `DOTFILES_TEST_EXCLUDE_ROLES` — comma list rendered as an `excluded_roles` extra-var.

The legacy scripts remain: `./test/health-check.sh` (host health check) and `./test/dry-run.sh` (chezmoi + Ansible dry run). `dry-run.sh` stays **interactive by design** — it uses `-K` unless `DOTFILES_TEST` is set. Phase E replaces both with thin wrappers around the runner.
