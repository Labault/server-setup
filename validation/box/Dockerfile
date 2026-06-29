# A disposable, systemd-enabled Ubuntu box for the black-box validation harness.
# server-setup converges THIS throwaway container, never the CI runner's host
# (D15 — we don't cut root SSH on an ephemeral GitHub runner). It ships systemd
# (as PID 1) plus the few base tools a fresh Hetzner box already has, and a
# running sshd so the SSH cutover's `reload` works like it does on a real VPS.
# Everything else (ufw, fail2ban, Docker…) is installed BY the convergence under
# test — that's the point.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
        systemd systemd-sysv systemd-timesyncd \
        sudo iproute2 ca-certificates curl gnupg openssh-server && \
    systemctl enable ssh && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /var/log/*

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
