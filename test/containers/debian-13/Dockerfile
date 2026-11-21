# Systemd-enabled Debian 13 test target for the container lane.
#
# Minimal boot + bootstrap substrate only; the provisioning pipeline installs
# the rest (Phase 1 hook reads .chezmoidata/requirements.yaml — toolchains,
# bootstrap substrate, and the Ansible interpreter packages). See the Ubuntu
# Dockerfile for the full rationale.
FROM debian:13

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus \
        openssh-server sudo bash \
        git curl wget ca-certificates \
        locales \
    && rm -rf /var/lib/apt/lists/*

# Ansible requires an initialisable locale. Generate it here because sshd does
# not propagate the image's LANG; the target stage scripts export C.UTF-8.
RUN sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen \
    && locale-gen

RUN useradd -m -s /bin/bash -G sudo provision \
    && echo 'provision ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/provision \
    && chmod 440 /etc/sudoers.d/provision

RUN git config --system url."https://github.com/".insteadOf git@github.com:

RUN mkdir -p /run/sshd /etc/systemd/system/multi-user.target.wants \
    && ln -sf /lib/systemd/system/ssh.service \
        /etc/systemd/system/multi-user.target.wants/ssh.service

STOPSIGNAL SIGRTMIN+3
EXPOSE 22
CMD ["/sbin/init"]
