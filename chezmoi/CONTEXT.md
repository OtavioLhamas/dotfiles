# Chezmoi

Dotfiles source state and machine bootstrap. Chezmoi manages user-space configuration files, classifies the machine interactively on first run, and orchestrates the package installation pipeline across platforms.

## Language

**Source State**:
The `chezmoi/` directory tree containing all managed dotfiles, templates, scripts, and data. This is chezmoi's input — never the deployed output in `$HOME`.
_Avoid_: Dotfiles repo, config directory

**Machine Classification**:
The interactive process that runs on first `chezmoi apply`. Prompts the user (`promptChoiceOnce`, `promptMultichoiceOnce`) to assign categories, a form factor, and a desktop environment. Results are persisted to `chezmoi.yaml` and drive all downstream conditional logic.
_Avoid_: Setup wizard, onboarding, machine profile

**Category**:
A purpose label assigned to the machine: `work`, `personal`, `gaming`, `multimedia`, or `development`. A machine can have multiple categories.
_Avoid_: Type, role, group

**Form Factor**:
The hardware class of the machine: `desktop`, `laptop`, or `server`. Exactly one per machine.
_Avoid_: Machine type, hardware type

**External**:
An external git repository imported into the source state via `.chezmoiexternal.yaml.tmpl`. Used to pull in dotfiles from other repos, conditionally based on machine classification.
_Avoid_: Submodule, dependency, plugin

**Hook**:
A script triggered by a chezmoi lifecycle event. The `read-source-state.pre` hook runs before chezmoi parses templates, so it cannot use template features — it installs raw prerequisites (git, curl, yq, Bitwarden CLI).
_Avoid_: Callback, trigger, middleware

**Script**:
A numbered lifecycle file in `.chezmoiscripts/` executed during `chezmoi apply`. Naming convention encodes ordering and idempotency: `run_once_before_*` (one-time setup), `run_after_*` (every apply). All scripts are Go templates.
_Avoid_: Hook, task, step

**Package Priority**:
The four-tier installation order for tools: (1) mise if in its registry, (2) WinGet DSC on Windows native, (3) Ansible for system packages, (4) chezmoi scripts as fallback. A tool should be placed in the highest tier that supports it.
_Avoid_: Package order, install priority
