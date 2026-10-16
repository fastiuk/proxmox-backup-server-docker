# Proxmox Backup Server from the official Proxmox repository, run without systemd.
FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive
# Empty = newest version in the repository; CI pins the exact version it tags the image with.
ARG PBS_VERSION=""
# sha256 of https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
ARG KEYRING_SHA256=136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl openssl tzdata \
 && curl -fsSL -o /usr/share/keyrings/proxmox-archive-keyring.gpg \
      https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
 && echo "${KEYRING_SHA256}  /usr/share/keyrings/proxmox-archive-keyring.gpg" | sha256sum -c - \
 && printf '%s\n' \
      'Types: deb' \
      'URIs: http://download.proxmox.com/debian/pbs' \
      'Suites: trixie' \
      'Components: pbs-no-subscription' \
      'Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg' \
      > /etc/apt/sources.list.d/pbs.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends "proxmox-backup-server${PBS_VERSION:+=${PBS_VERSION}}" \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

EXPOSE 8007
VOLUME ["/etc/proxmox-backup", "/var/lib/proxmox-backup", "/var/log/proxmox-backup"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD ["curl", "-fsk", "-o", "/dev/null", "https://127.0.0.1:8007/"]

ENTRYPOINT ["/entrypoint.sh"]
