# Ansible

System-wide configuration and provisioning. Ansible applies roles to the local machine (and optionally a Windows host over SSH) for multi-step installations requiring repository setup, GPG keys, flatpaks, services, or post-install handlers.

Simple single-package `apt/dnf install` from default repos should go in `.chezmoidata/packages.yaml` instead (Phase 3a) — not an Ansible role.

## Language

**Role**:
A single-responsibility unit of system configuration. Each role handles one concern requiring multi-step setup (e.g., `fish` installs + sets default shell, `flatpak` installs + adds Flathub remote, `gnome` configures desktop extensions).
_Avoid_: Task, playbook, recipe

**Play**:
A section of `main.yaml` that targets a host group (`all`, `linux`, `win32nt`). Plays run sequentially and include shared task logic via `run_group_roles.yaml`.
_Avoid_: Stage, phase

**Group**:
An Ansible inventory group derived from machine classification (e.g., `work`, `gaming`, `desktop`) or OS facts (e.g., `debian`, `linux`, `win32nt`). Groups determine which roles and variables apply.
_Avoid_: Category, tag, label

**Inventory**:
The generated `inventory.yaml` file that maps `localhost` (and optionally `windows_native`) into groups. Regenerated entirely on each `chezmoi apply` — never edited by hand.
_Avoid_: Host file, machine list

**Host**:
A target machine. Always `localhost` for Linux. Under WSL, a second host `windows_native` is added with an SSH connection to the Windows host IP.
_Avoid_: Node, target, machine

**Group Variables**:
Variables scoped to a group, defined in `group_vars/<group>/vars.yaml`. Provide role lists and settings consumed by plays.
_Avoid_: Group vars (in writing), group config

**Privilege Escalation**:
The `become` mechanism (sudo) applied selectively to Linux roles that require root. Windows roles never use `become`. Controlled by the `become_roles` list.
_Avoid_: Sudo, elevation, root access
