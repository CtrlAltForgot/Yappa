ARG BASE_IMAGE=ubuntu@sha256:52df9b1ee71626e0088f7d400d5c6b5f7bb916f8f0c82b474289a4ece6cf3faf
FROM ${BASE_IMAGE}

ARG PACKAGE_MANAGER
RUN set -eux; \
    case "$PACKAGE_MANAGER" in \
      apt) \
        apt-get update; \
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
          bash ca-certificates coreutils dbus iproute2 iptables procps \
          systemd systemd-sysv uidmap ufw util-linux; \
        rm -rf /var/lib/apt/lists/*; \
        ;; \
      dnf) \
        dnf install -y \
          bash ca-certificates coreutils dbus firewalld iproute iptables-nft \
          procps-ng shadow-utils systemd util-linux; \
        dnf clean all; \
        ;; \
      microdnf) \
        for attempt in 1 2 3; do \
          microdnf clean all; \
          if microdnf install -y \
            bash ca-certificates dbus firewalld iproute iptables-nft procps-ng \
            shadow-utils systemd util-linux; then \
            break; \
          fi; \
          test "$attempt" -lt 3; \
          sleep "$((attempt * 2))"; \
        done; \
        microdnf clean all; \
        ;; \
      *) exit 64 ;; \
    esac

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
