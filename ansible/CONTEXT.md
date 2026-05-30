# Ansible

System-wide configuration and provisioning. Ansible applies roles to the local machine (and optionally a Windows host over SSH) to install packages, configure services, and set desktop environment preferences.

## Language

**Role**:
A single-responsibility unit of system configuration. Each role handles one concern (e.g., `gnome` configures the desktop environment, `windows_appx` removes bloatware).
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
Variables scoped to a group, defined in `group_vars/<group>/vars.yaml`. Provide package lists and settings consumed by roles.
_Avoid_: Group vars (in writing), group config

**Privilege Escalation**:
The `become` mechanism (sudo) applied selectively to Linux roles that require root. Windows roles never use `become`. Controlled by the `become_roles` list.
_Avoid_: Sudo, elevation, root access
