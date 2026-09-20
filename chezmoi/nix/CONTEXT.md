# Nix

User-level packages and configuration on Linux/WSL via **Nix + Home Manager (standalone)**. The flake lives in the source tree at `chezmoi/nix/` as **chezmoi templates** (`.nix.tmpl`): `chezmoi apply` renders machine classification into plain Nix and deploys it to `~/nix`, where `home-manager switch` consumes it. On Windows the flake is excluded from deployment (`.chezmoiignore`).

Like the rest of the project, this is **provisioning, not convergence**: `home-manager switch` builds a new generation; it never rolls back or reconciles drift (rollback is only manual, via `home-manager switch --switch-generation`).

## Evaluation model

The flake is a **deployed, rendered artifact** — not a git-tracked input:

- Classification (distro, form factor, DE, categories, username, home, hostname) is baked in at render time via chezmoi template actions. The rendered files are plain Nix: no `builtins.getEnv`, no `--impure`.
- Because `~/nix` is a plain directory (not a git repo checkout), the flakes-only-read-git-tracked-files restriction does not apply.
- Change detection hashes the **rendered** output (`includeTemplate`), so re-rendering with new classification re-triggers `home-manager switch`.
- `flake.lock` updates happen in the source tree and are committed; the deployed copy is overwritten by `chezmoi apply` on the next run.

## Pins

- nixpkgs: **stable** `nixos-26.05` — predictable, low-churn; mise covers anything fast-moving (rule 1), so Nix does not need bleeding-edge packages.
- home-manager: `release-26.05` — the HM release branch must always match the nixpkgs branch, and `home.stateVersion` must track the HM release.
- The flake output is keyed by `.chezmoi.hostname` — no machine name is hardcoded.

## Home Manager / chezmoi boundary

Home Manager owns **packages, services and settings state only**; it must never own a config file chezmoi deploys:

| Allowed | Forbidden (conflicts with chezmoi) |
|---|---|
| `home.packages` | `home.file`, `xdg.configFile`, `home.sessionVariables` |
| `services.*` (user units), `dconf.settings` | `programs.<tool>` for tools whose config is in the source tree |

`home.sessionVariables` is forbidden because (a) nothing sources `hm-session-vars.sh` unless HM owns the shell init, and (b) shared shell env is already single-sourced in mise's `[env]` table. Shell init and shell environment are **not** a Nix concern.

## Placement

Nix is layer 3 of 5. It owns user-space packages that are **not** in the mise registry (mise is king — rule 1) and **not** system-level (requirements.yaml / packages.yaml / Ansible own those). Dotfiles and tool plugins stay chezmoi-owned (rule 2): Nix must not write a file chezmoi already manages. Shell init and shared shell env are likewise not Nix-owned: chezmoi owns the shell files, and **mise's `[env]` table is the single source** for cross-shell env vars (bash, zsh, fish, PowerShell all activate mise).

## Language

**Home Manager**:
The Nix user-environment manager, running in **standalone mode** on non-NixOS. Builds the user profile (`~/.nix-profile`) and activation scripts. Never manages system services (docker daemon, flatpak remotes — those stay on Ansible).
_Avoid_: Nix profile (when referring to the manager), user config

**Flake**:
The pinned Nix configuration: inputs (nixpkgs release, home-manager release) and the machine output. Lives at `chezmoi/nix/flake.nix.tmpl` as a chezmoi template; rendered to `~/nix/flake.nix` on apply. `flake.lock` is committed and pins the inputs; lock updates happen in the source tree, never in `~/nix` (chezmoi overwrites the deployed copy).
_Avoid_: Nix config, nix file

**Host override**:
The per-machine dimension of the flake. The flake output is keyed by `.chezmoi.hostname`; each deployed flake carries exactly its own machine's configuration. Machines differ through **machine classification** — distro, form factor, desktop environment, categories — which chezmoi renders into the flake. Modules branch on the baked-in `machine` values with `lib.optionals` / `mkIf`. The prompts stay chezmoi's; Nix only consumes the result.
_Avoid_: Hosts directory, per-hostname config, machine profile

**Generation**:
An immutable, numbered snapshot of the Home Manager environment produced by `home-manager switch`. Rollback means activating an older generation — it is manual and never automated by this project.
_Avoid_: Profile, snapshot (when unqualified)

## Boundaries

- **mise** wins for any tool in its registry (Phase 2, `dot_config/mise/config.toml`).
- **chezmoi** owns all deployed files; Home Manager writes only under `~/.nix-profile` and `~/.config/home-manager`.
- **Ansible** remains the fallback for system-level, multi-step configuration (repos, GPG keys, systemd services, flatpak remotes, Flatpak GUI apps).
- **Windows native** has no Nix layer — see `plans/dsc/`. **macOS** is out of scope.
