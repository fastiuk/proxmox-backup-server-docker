#!/usr/bin/env bash
# End-to-end test of a built image: first-run admin, web login, datastore, backup and restore
# over the network with proxmox-backup-client, GC and verify, restart persistence, healthcheck,
# graceful shutdown under reduced privileges, admin password from a secret file or the environment,
# and first start with a DNS search domain too long for the certificate name.
#
# usage: tests/e2e.sh <image>
set -euo pipefail

IMAGE=${1:?usage: tests/e2e.sh <image>}
HERE=$(cd "$(dirname "$0")" && pwd)
RUN_ID=pbs-e2e-$$
SERVER=$RUN_ID-server
LONG=$RUN_ID-longdns
CLIENT_IMAGE=pbs-e2e-client:local
# named volumes, not bind mounts: Docker Desktop bind mounts ignore chown, which PBS relies on
VOLUMES=(etc lib logs backups restore)
WORK=$(mktemp -d)
# throwaway credential for this test container only
PASSWORD=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
FINGERPRINT=""
# the hardened settings README and compose.yaml recommend; the test proves PBS works with them
HARDENING=(--init --tmpfs /run --security-opt no-new-privileges:true --cap-drop ALL
    --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETUID --cap-add SETGID
    --cap-add NET_BIND_SERVICE --cap-add KILL)

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
# match on captured output: piping into "grep -q" breaks the writer's pipe and trips pipefail
contains() { grep -q -- "$1" <<<"$2"; }

cleanup() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        echo "--- server log (tail) ---" >&2
        docker logs "$SERVER" 2>&1 | tail -40 >&2 || true
    fi
    docker rm -fv "$SERVER" "$LONG" >/dev/null 2>&1 || true
    docker network rm "$RUN_ID" >/dev/null 2>&1 || true
    for v in "${VOLUMES[@]}"; do docker volume rm "$RUN_ID-$v" >/dev/null 2>&1 || true; done
    rm -rf "$WORK"
    exit "$status"
}
trap cleanup EXIT

pbm() { docker exec "$SERVER" proxmox-backup-manager "$@"; }

client() {
    docker run --rm --network "$RUN_ID" \
        -e PBS_REPOSITORY="admin@pbs@$SERVER:e2e" \
        -e PBS_PASSWORD="$PASSWORD" \
        -e PBS_FINGERPRINT="$FINGERPRINT" \
        -v "$WORK/data:/data:ro" -v "$RUN_ID-restore:/restore" \
        "$CLIENT_IMAGE" "$@"
}

wait_ready() {
    local name=${1:-$SERVER}
    for _ in $(seq 60); do
        docker exec "$name" curl -fsk -o /dev/null https://127.0.0.1:8007/ 2>/dev/null && return 0
        sleep 2
    done
    docker logs "$name" 2>&1 | tail -20 >&2
    fail "PBS in $name did not answer on :8007"
}

login_ok() {
    local out
    out=$(docker exec "${1:-$SERVER}" curl -fsk \
        --data-urlencode "username=admin@pbs" --data-urlencode "password=$PASSWORD" \
        https://127.0.0.1:8007/api2/json/access/ticket) || return 1
    contains '"ticket"' "$out"
}

# process names are cut to 15 chars, so match on the full command line
daemon_pid() { docker exec "$SERVER" pgrep -of "proxmox-backup/$1\$"; }

step "build test client"
ARCH=$(docker image inspect -f '{{.Architecture}}' "$IMAGE")
docker build -q --platform "linux/$ARCH" -t "$CLIENT_IMAGE" -f "$HERE/client.Dockerfile" "$HERE" >/dev/null

step "start server"
mkdir -p "$WORK/data"
printf '%s\n' "$PASSWORD" >"$WORK/admin_password"
chmod 644 "$WORK/admin_password"
docker network create "$RUN_ID" >/dev/null
for v in "${VOLUMES[@]}"; do docker volume create "$RUN_ID-$v" >/dev/null; done
# short, fixed DNS search domain: PBS creates its own certificate (see the long-domain case below);
# the admin password comes from a secret file, the long-domain case covers the plain variable
docker run -d --name "$SERVER" --network "$RUN_ID" "${HARDENING[@]}" \
    --hostname pbs-e2e --dns-search example.com \
    -e TZ=Europe/Kyiv -e PBS_ADMIN_PASSWORD_FILE=/run/secrets/pbs_admin_password \
    -v "$WORK/admin_password:/run/secrets/pbs_admin_password:ro" \
    -v "$RUN_ID-etc:/etc/proxmox-backup" \
    -v "$RUN_ID-lib:/var/lib/proxmox-backup" \
    -v "$RUN_ID-logs:/var/log/proxmox-backup" \
    -v "$RUN_ID-backups:/backups" \
    "$IMAGE" >/dev/null
wait_ready
pbm versions

step "daemons run as the right users, without the admin password in their env"
[ "$(docker exec "$SERVER" ps -o user= -p "$(daemon_pid proxmox-backup-api)" | tr -d ' ')" = root ] \
    || fail "api is not running as root"
[ "$(docker exec "$SERVER" ps -o user= -p "$(daemon_pid proxmox-backup-proxy)" | tr -d ' ')" = backup ] \
    || fail "proxy is not running as backup"
# read each environ as the daemon's own user: Docker drops CAP_SYS_PTRACE, so root can't read others'
for pair in proxmox-backup-api:root proxmox-backup-proxy:backup; do
    d=${pair%%:*}
    env=$(docker exec -u "${pair#*:}" "$SERVER" cat "/proc/$(daemon_pid "$d")/environ" | tr '\0' '\n') \
        || fail "cannot read the environment of $d"
    contains '^TZ=' "$env" || fail "unexpected environment for $d"
    if contains '^PBS_ADMIN_PASSWORD' "$env"; then fail "$d sees PBS_ADMIN_PASSWORD*"; fi
done

step "web login as admin@pbs"
login_ok || fail "login failed"

step "create datastore"
pbm datastore create e2e /backups/e2e | tail -2
FINGERPRINT=$(pbm cert info | sed -n 's/^Fingerprint (sha256): //p')
[ -n "$FINGERPRINT" ] || fail "no certificate fingerprint"

step "back up a directory"
head -c 4194304 /dev/urandom >"$WORK/data/random.bin"
seq 1 200000 >"$WORK/data/numbers.txt"
mkdir -p "$WORK/data/nested/dir"
echo "hello from e2e" >"$WORK/data/nested/dir/hello.txt"
client backup data.pxar:/data --backup-id e2e

step "restore and compare"
client restore host/e2e data.pxar /restore/data
docker run --rm -v "$WORK/data:/data:ro" -v "$RUN_ID-restore:/restore:ro" --entrypoint diff "$IMAGE" \
    -r /data /restore/data || fail "restored data differs"

step "garbage collection and verify"
contains 'TASK OK' "$(pbm garbage-collection start e2e)" || fail "GC failed"
contains 'TASK OK' "$(pbm verify e2e)" || fail "verify failed"

step "restart keeps config and backups"
docker restart "$SERVER" >/dev/null
wait_ready
login_ok || fail "login failed after restart"
contains 'host/e2e' "$(client snapshot list)" || fail "snapshot missing after restart"

step "healthcheck reports healthy"
health=""
for _ in $(seq 40); do
    health=$(docker inspect -f '{{.State.Health.Status}}' "$SERVER")
    [ "$health" = healthy ] && break
    sleep 3
done
[ "$health" = healthy ] || fail "healthcheck status: $health"

step "graceful stop"
docker stop -t 30 "$SERVER" >/dev/null
code=$(docker inspect -f '{{.State.ExitCode}}' "$SERVER")
[ "$code" = 0 ] || fail "container exited with $code on SIGTERM"

step "starts with a DNS search domain too long for the certificate name (admin from env)"
docker run -d --name "$LONG" "${HARDENING[@]}" --hostname pbs-e2e-long \
    --dns-search "averyveryveryverylongsearchdomain.bx.internal.cloudapp.example" \
    -e PBS_ADMIN_PASSWORD="$PASSWORD" \
    "$IMAGE" >/dev/null
wait_ready "$LONG"
contains 'CN *= *pbs-e2e-long' \
    "$(docker exec "$LONG" openssl x509 -in /etc/proxmox-backup/proxy.pem -noout -subject)" \
    || fail "certificate is not issued for the bare hostname"
login_ok "$LONG" || fail "login with PBS_ADMIN_PASSWORD failed"

printf '\nALL E2E TESTS PASSED\n'
