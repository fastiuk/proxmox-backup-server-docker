#!/bin/bash
# Runs the two PBS daemons without systemd: the API server as root and the proxy as "backup".
set -euo pipefail

LIBDIR=/usr/lib/$(uname -m)-linux-gnu/proxmox-backup

# Bind mounts arrive owned by root; PBS refuses to start unless these belong to "backup".
mkdir -p /etc/proxmox-backup /var/lib/proxmox-backup /var/log/proxmox-backup /run/proxmox-backup
chown backup:backup /etc/proxmox-backup /var/lib/proxmox-backup /var/log/proxmox-backup /run/proxmox-backup
chmod 700 /etc/proxmox-backup

# PBS names its self-signed certificate "<hostname>.<resolv.conf search>", but an X.509 CN holds
# at most 64 characters; long search domains (cloud VMs, CI runners) make the API fail on first
# start. In that case create the certificate here with the bare hostname; PBS keeps an existing one.
if [ ! -e /etc/proxmox-backup/proxy.pem ]; then
    host=$(hostname)
    search=$(awk '$1 == "search" { $1 = ""; sub(/^ +/, ""); print; exit }' /etc/resolv.conf 2>/dev/null || true)
    cn=$host${search:+.$search}
    if [ "${#cn}" -gt 64 ]; then
        openssl req -x509 -newkey rsa:4096 -nodes -days 365000 \
            -subj "/O=Proxmox Backup Server/CN=${host:0:64}" \
            -addext "subjectAltName=DNS:$host,DNS:localhost,IP:127.0.0.1" \
            -keyout /etc/proxmox-backup/proxy.key -out /etc/proxmox-backup/proxy.pem 2>/dev/null
        chown root:backup /etc/proxmox-backup/proxy.key /etc/proxmox-backup/proxy.pem
        chmod 640 /etc/proxmox-backup/proxy.key /etc/proxmox-backup/proxy.pem
        echo "certificate name '$cn' is too long, created a self-signed one for '$host'" >&2
    fi
fi

# Optional first-run admin: create admin@pbs once, then keep the password out of the daemons' env.
if [ -n "${PBS_ADMIN_PASSWORD:-}" ] && ! grep -qx 'user: admin@pbs' /etc/proxmox-backup/user.cfg 2>/dev/null; then
    proxmox-backup-manager user create admin@pbs --password "$PBS_ADMIN_PASSWORD" \
        --comment "created from PBS_ADMIN_PASSWORD" >/dev/null
    proxmox-backup-manager acl update / Admin --auth-id admin@pbs
    echo "created admin@pbs from PBS_ADMIN_PASSWORD" >&2
fi
unset PBS_ADMIN_PASSWORD

api=""
proxy=""
stop_daemons() {
    kill -TERM ${api:+"$api"} ${proxy:+"$proxy"} 2>/dev/null || true
    wait
}
trap 'stop_daemons; exit 0' TERM INT

"$LIBDIR/proxmox-backup-api" &
api=$!

# On first start the API generates the auth keys and TLS certificate the proxy needs.
for _ in $(seq 30); do
    [ -e /etc/proxmox-backup/proxy.pem ] && [ -e /etc/proxmox-backup/csrf.key ] && break
    kill -0 "$api" 2>/dev/null || { echo "proxmox-backup-api failed to start" >&2; exit 1; }
    sleep 1
done

setpriv --reuid=backup --regid=backup --init-groups "$LIBDIR/proxmox-backup-proxy" &
proxy=$!

# If either daemon dies, stop the container so Docker's restart policy brings both back.
wait -n || true
echo "a PBS daemon exited, stopping container" >&2
stop_daemons
exit 1
