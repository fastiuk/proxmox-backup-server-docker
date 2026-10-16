# proxmox-backup-client for the end-to-end test: talks to the server over the network, like PVE does.
FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG KEYRING_SHA256=136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && curl -fsSL -o /usr/share/keyrings/proxmox-archive-keyring.gpg \
      https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
 && echo "${KEYRING_SHA256}  /usr/share/keyrings/proxmox-archive-keyring.gpg" | sha256sum -c - \
 && printf '%s\n' \
      'Types: deb' \
      'URIs: http://download.proxmox.com/debian/pbs-client' \
      'Suites: trixie' \
      'Components: main' \
      'Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg' \
      > /etc/apt/sources.list.d/pbs-client.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends proxmox-backup-client \
 && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["proxmox-backup-client"]
