# Context Map

## Contexts

- [Chezmoi](./chezmoi/CONTEXT.md) — dotfiles source state, machine classification, and package installation orchestration
- [Ansible](./ansible/CONTEXT.md) — system-wide configuration via roles targeting localhost and optional Windows hosts
- [Nix](./chezmoi/nix/CONTEXT.md) — user-level packages and configuration on Linux/WSL via Nix + Home Manager (standalone)

## Relationships

- **Chezmoi -> Ansible**: Chezmoi's provisioning script generates the Ansible inventory and invokes the playbook. Ansible is a downstream consumer of chezmoi's machine classification data.
- **Chezmoi -> Nix**: Chezmoi scripts install Nix (one-time) and run `home-manager switch` (change-detected), pointing at the flake in `chezmoi/nix/` via the `NIX_DIR` scriptEnv variable. Machine classification stays chezmoi's; the flake selects per-host modules by hostname.
- **Nix vs Ansible**: Nix owns user-level packages/configs on Linux; Ansible is the minimized fallback for system-level, multi-step configuration Nix cannot express (docker daemon, flatpak remotes, Flatpak GUI apps).
