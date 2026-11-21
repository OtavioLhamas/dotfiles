# Systemd-enabled Fedora 44 test target for the container lane.
#
# Minimal boot + bootstrap substrate only; the provisioning pipeline installs
# the rest (Phase 1 hook reads .chezmoidata/requirements.yaml). Fedora's base
# image uses systemd as PID 1 (no systemd-sysv); the dnf Ansible module uses
# the dnf CLI and needs no extra Python library. See the Ubuntu Dockerfile for
# the full rationale.
FROM fedora:44

RUN dnf install -y --setopt=install_weak_deps=False \
        dbus \
        openssh-server sudo bash \
        git curl wget ca-certificates tar \
    && dnf clean all

RUN useradd -m -s /bin/bash -G wheel provision \
    && echo 'provision ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/provision \
    && chmod 440 /etc/sudoers.d/provision

RUN git config --system url."https://github.com/".insteadOf git@github.com:

RUN mkdir -p /run/sshd \
    && systemctl enable sshd

STOPSIGNAL SIGRTMIN+3
EXPOSE 22
CMD ["/sbin/init"]
