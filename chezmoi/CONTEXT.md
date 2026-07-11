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
A script triggered by a chezmoi lifecycle event. The `read-source-state.pre` hook runs before chezmoi parses templates, so it cannot use template features — it installs raw prerequisites and Phase 1 native toolchains by reading declarative data files (`requirements.yaml`, `winget-toolchains.dsc.yaml`).
_Avoid_: Callback, trigger, middleware

**Script**:
A numbered lifecycle file in `.chezmoiscripts/` executed during `chezmoi apply`. Naming convention encodes ordering, idempotency, and change detection: `run_once_before_*` (one-time setup), `run_onchange_after_*` (re-runs when generated content changes), `run_after_*` (every apply). All scripts are Go templates.
_Avoid_: Hook, task, step

**Phase / Dependency Layer**:
A provisioning stage where each layer only depends on previous layers. Phase 1 (toolchains) must complete before Phase 2 (runtimes), which must complete before Phase 3 (configuration). This replaces the old tool-centric package priority model.
_Avoid_: Step, stage (the general term), tier

**Requirements**:
Phase 1 declarative package declaration (`.chezmoidata/requirements.yaml`). Lists native machine-wide toolchains (compilers, build tools, dev libraries) needed before mise can compile language runtimes. Read by the hook via `yq`.
_Avoid_: Prerequisites, dependencies, build-deps

**Change Detection**:
A `run_onchange_after_` script that only re-runs when a tracked file changes, using a SHA256 hash embedded in a comment:
```
# file changed: {{ include "path/to/file" | sha256sum }}
```
_Avoid_: Watch, trigger, hash check

**scriptEnv**:
Environment variables declared in `chezmoi.yaml` under `scriptEnv:` and injected into all scripts and hooks at runtime. Used instead of magic strings for shared paths.
_Avoid_: Script variables, global env