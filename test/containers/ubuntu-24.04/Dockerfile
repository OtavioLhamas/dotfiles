# Systemd-enabled Ubuntu 24.04 test target for the container lane.
#
# Hand-rolled (repo-owned recipe, no external base-image dependency). The image
# is the *minimum* needed to boot, accept SSH, and run bootstrap.sh — everything
# else is installed by the provisioning pipeline itself: the Phase 1 hook reads
# .chezmoidata/requirements.yaml (toolchains AND the bootstrap substrate) and
# installs anything missing. The substrate below is the irreducible bootstrap
# set the hook cannot install for itself (it needs wget/curl before it can read
# requirements.yaml).
#
# The harness SSH key is injected at container start, never baked in.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Boot/login: systemd + dbus, sshd, sudo, bash. Bootstrap substrate: curl/wget
# (bootstrap.sh installs chezmoi; the hook uses a temporary yq parser), git +
# ca-certificates for the clone/HTTPS.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus \
        openssh-server sudo bash \
        git curl wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Harness login user — mirrors the cloud-init image / Dockerfile in the plan.
RUN useradd -m -s /bin/bash -G sudo provision \
    && echo 'provision ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/provision \
    && chmod 440 /etc/sudoers.d/provision

# Public submodules are fetched over HTTPS (never SSH) — see AGENTS.md.
RUN git config --system url."https://github.com/".insteadOf git@github.com:

# sshd starts under systemd (PID 1); enable it without needing systemd at build.
RUN mkdir -p /run/sshd /etc/systemd/system/multi-user.target.wants \
    && ln -sf /lib/systemd/system/ssh.service \
        /etc/systemd/system/multi-user.target.wants/ssh.service

STOPSIGNAL SIGRTMIN+3
EXPOSE 22
CMD ["/sbin/init"]
