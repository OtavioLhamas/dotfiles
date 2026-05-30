# Context Map

## Contexts

- [Chezmoi](./chezmoi/CONTEXT.md) — dotfiles source state, machine classification, and package installation orchestration
- [Ansible](./ansible/CONTEXT.md) — system-wide configuration via roles targeting localhost and optional Windows hosts

## Relationships

- **Chezmoi -> Ansible**: Chezmoi's provisioning script generates the Ansible inventory and invokes the playbook. Ansible is a downstream consumer of chezmoi's machine classification data.
