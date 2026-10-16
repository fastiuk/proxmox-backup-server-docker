#!/bin/bash
# Runs the two PBS daemons without systemd: the API server as root and the proxy as "backup".
set -euo pipefail

LIBDIR=/usr/lib/$(uname -m)-linux-gnu/proxmox-backup

# Bind mounts arrive owned by root; PBS refuses to start unless these belong to "backup".
mkdir -p /etc/proxmox-backup /var/lib/proxmox-backup /var/log/proxmox-backup /run/proxmox-backup
chown backup:backup /etc/proxmox-backup /var/lib/proxmox-backup /var/log/proxmox-backup /run/proxmox-backup
chmod 700 /etc/proxmox-backup

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
# shellcheck disable=SC2329  # invoked via trap
term() {
    stop_daemons
    exit 0
}
trap term TERM INT

"$LIBDIR/proxmox-backup-api" &
api=$!

# On first start the API generates the auth keys and TLS certificate the proxy needs.
for _ in $(seq 30); do
    [ -e /etc/proxmox-backup/proxy.pem ] && [ -e /etc/proxmox-backup/csrf.key ] && break
    sleep 1
done

setpriv --reuid=backup --regid=backup --init-groups "$LIBDIR/proxmox-backup-proxy" &
proxy=$!

# If either daemon dies, stop the container so Docker's restart policy brings both back.
wait -n || true
echo "a PBS daemon exited, stopping container" >&2
stop_daemons
exit 1
