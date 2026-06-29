# A disposable, systemd-enabled Ubuntu box for the black-box validation harness.
# server-setup converges THIS throwaway container, never the CI runner's host
# (D15 — we don't cut root SSH on an ephemeral GitHub runner). It ships systemd
# (as PID 1) plus the few base tools a fresh Hetzner box already has, and a
# running sshd so the SSH cutover's `reload` works like it does on a real VPS.
# Everything else (ufw, fail2ban, Docker…) is installed BY the convergence under
# test — that's the point.
#
# Deliberately NOT shipped: systemd-timesyncd. A fresh Hetzner box doesn't have
# it either, so leaving it out makes the box reproduce reality — `do_timesync`
# must install it (a box that ships it would mask that bug, and once did). We DO
# ship chrony, a competing NTP daemon, so the convergence's purge-the-rival path
# is actually exercised: a real box may arrive with chrony owning the clock.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
        systemd systemd-sysv chrony \
        sudo iproute2 ca-certificates curl gnupg openssh-server && \
    systemctl enable ssh && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /var/log/*

# A real provisioned VPS always has root's authorized_keys (that's how you SSH in
# to run server-setup at all). Seed a dummy one so the box mirrors that: the SSH
# cutover's safety gate refuses key-only SSH when `deploy` has no key, and on a
# real box `deploy` inherits this very key via the deploy-user seed. Content only
# needs to be non-empty for the gate.
RUN install -d -m 0700 /root/.ssh && \
    echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA validation-box-dummy' \
        > /root/.ssh/authorized_keys && \
    chmod 0600 /root/.ssh/authorized_keys

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
