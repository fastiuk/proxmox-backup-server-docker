# Proxmox Backup Server in Docker

[![CI](https://img.shields.io/github/actions/workflow/status/fastiuk/proxmox-backup-server-docker/ci.yml?branch=main&label=CI&logo=githubactions&logoColor=white)](https://github.com/fastiuk/proxmox-backup-server-docker/actions/workflows/ci.yml)
[![Tests](https://img.shields.io/github/actions/workflow/status/fastiuk/proxmox-backup-server-docker/test.yml?branch=main&label=tests&logo=githubactions&logoColor=white)](https://github.com/fastiuk/proxmox-backup-server-docker/actions/workflows/test.yml)
[![Build](https://img.shields.io/github/actions/workflow/status/fastiuk/proxmox-backup-server-docker/build.yml?branch=main&label=build&logo=docker&logoColor=white)](https://github.com/fastiuk/proxmox-backup-server-docker/actions/workflows/build.yml)
[![PBS](https://img.shields.io/docker/v/fastiuk/proxmox-backup-server?sort=semver&label=PBS&logo=proxmox&logoColor=white&color=E57000)](https://hub.docker.com/r/fastiuk/proxmox-backup-server/tags)
[![Docker pulls](https://img.shields.io/docker/pulls/fastiuk/proxmox-backup-server?logo=docker&logoColor=white)](https://hub.docker.com/r/fastiuk/proxmox-backup-server)
[![Image size](https://img.shields.io/docker/image-size/fastiuk/proxmox-backup-server/latest?logo=docker&logoColor=white)](https://hub.docker.com/r/fastiuk/proxmox-backup-server/tags)
[![Platform](https://img.shields.io/badge/platform-linux%2Famd64-blue?logo=linux&logoColor=white)](#architectures)
[![Debian](https://img.shields.io/badge/base-Debian%20trixie-A81D33?logo=debian&logoColor=white)](https://www.debian.org/releases/trixie/)
[![License](https://img.shields.io/github/license/fastiuk/proxmox-backup-server-docker)](LICENSE)

**Source:** [github.com/fastiuk/proxmox-backup-server-docker](https://github.com/fastiuk/proxmox-backup-server-docker) ·
**Image:** [hub.docker.com/r/fastiuk/proxmox-backup-server](https://hub.docker.com/r/fastiuk/proxmox-backup-server)

[Proxmox Backup Server](https://www.proxmox.com/en/products/proxmox-backup-server/overview) (PBS)
as a Docker image, built from the **official Proxmox package repository** and running
**without systemd**. Useful on a NAS (Synology, Unraid, TrueNAS SCALE, …) or any Docker host
where a bare-metal or VM install of PBS is not an option.

## Highlights

- **Official packages.** `proxmox-backup-server` comes straight from `download.proxmox.com`
  (no-subscription repository); the Proxmox archive keyring is checked against a pinned sha256.
- **No systemd emulation.** A short [entrypoint](entrypoint.sh) starts `proxmox-backup-api` as root
  and `proxmox-backup-proxy` as the `backup` user, exactly like the upstream systemd units do.
- **Tested before it ships.** Every image passes an [end-to-end test](tests/e2e.sh) before it is
  pushed: web login, datastore creation, backup and restore through `proxmox-backup-client`,
  garbage collection, verify, restart persistence, healthcheck and graceful shutdown — all with
  reduced container privileges.
- **Always current.** Rebuilt on every push and weekly, picking up new PBS releases and Debian
  security updates. Tags follow the PBS version.
- **Locked down.** Runs with `no-new-privileges` and a minimal capability set, takes the first admin
  password from a Docker secret, and every GitHub Action and lint image is pinned by digest.
- **Batteries included.** Healthcheck, clean `SIGTERM` handling, SBOM attestation.

## Quick start

```bash
mkdir pbs && cd pbs
curl -fsSLO https://raw.githubusercontent.com/fastiuk/proxmox-backup-server-docker/main/compose.yaml
# first start only: a password for admin@pbs, and uncomment the secret lines in compose.yaml
(umask 077; read -rsp 'admin@pbs password: ' pw && echo "$pw" > pbs_admin_password.txt)
docker compose up -d
```

Or with plain `docker run`:

```bash
docker run -d --name pbs --init --restart unless-stopped \
  --security-opt no-new-privileges:true --cap-drop ALL \
  --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETUID --cap-add SETGID \
  --cap-add NET_BIND_SERVICE --cap-add KILL \
  -p 8007:8007 --tmpfs /run \
  -e TZ=Europe/Berlin \
  -e PBS_ADMIN_PASSWORD_FILE=/run/secrets/pbs_admin_password \
  -v "$PWD/pbs_admin_password.txt:/run/secrets/pbs_admin_password:ro" \
  -v pbs-etc:/etc/proxmox-backup \
  -v pbs-lib:/var/lib/proxmox-backup \
  -v pbs-logs:/var/log/proxmox-backup \
  -v /srv/backups:/backups \
  fastiuk/proxmox-backup-server:latest
```

Open `https://<host>:8007` and log in as **`admin`** with the realm
**Proxmox Backup authentication server**. The account now lives in `/etc/proxmox-backup`: remove the
secret from the configuration and delete `pbs_admin_password.txt`.

## Configuration

| Volume | Contents |
|---|---|
| `/etc/proxmox-backup` | configuration, users, keys, TLS certificate. **Keep this safe.** |
| `/var/lib/proxmox-backup` | job state and statistics |
| `/var/log/proxmox-backup` | task logs |
| `/backups` | suggested mount point for datastores (any path works) |
| `/run` | must be a `tmpfs` |

| Variable | Default | Description |
|---|---|---|
| `TZ` | `UTC` | time zone used for GC, prune, verify and sync schedules |
| `PBS_ADMIN_PASSWORD_FILE` | – | file (e.g. a Docker secret) with the password for `admin@pbs`, created with the `Admin` role on start if it does not exist yet (at least 8 characters) |
| `PBS_ADMIN_PASSWORD` | – | the same as a plain variable; it stays visible in `docker inspect`, so prefer the file. The daemons never see either |

Port `8007/tcp` serves the web UI, the API and backup traffic over HTTPS.

> **Docker Desktop (macOS/Windows):** bind mounts there ignore `chown`, and PBS refuses to start
> unless its directories belong to the `backup` user. Use named volumes instead of host paths.

On first start PBS creates a self-signed certificate named `<hostname>.<DNS search domain>`.
Certificate names are limited to 64 characters, which long search domains (common on cloud VMs)
exceed; the entrypoint then issues the certificate for the bare hostname instead. Setting a short
`hostname` (as in `compose.yaml`) is a good idea either way.

## Create a datastore

In the web UI: **Datastore → Add Datastore**, path `/backups/store`. Or from the shell:

```bash
docker exec pbs proxmox-backup-manager datastore create store /backups/store
docker exec pbs proxmox-backup-manager datastore update store --gc-schedule daily
docker exec pbs proxmox-backup-manager prune-job create store-prune --store store \
  --schedule daily --keep-daily 14 --keep-weekly 8 --keep-monthly 12
docker exec pbs proxmox-backup-manager verify-job create store-verify --store store \
  --schedule weekly --ignore-verified true --outdated-after 30
```

Let PBS create the datastore directory: it has to belong to the container's `backup` user
(uid 34). If you create it yourself, `chown 34:34` it.

## Connect Proxmox VE

Create a dedicated user and API token that may back up and restore, but **not delete** backups:

```bash
docker exec pbs proxmox-backup-manager user create pve@pbs
docker exec pbs proxmox-backup-manager user generate-token pve@pbs pve    # note the secret
docker exec pbs proxmox-backup-manager acl update /datastore/store DatastoreBackup --auth-id pve@pbs
docker exec pbs proxmox-backup-manager acl update /datastore/store DatastoreBackup --auth-id 'pve@pbs!pve'
docker exec pbs proxmox-backup-manager cert info | grep Fingerprint
```

In Proxmox VE: **Datacenter → Storage → Add → Proxmox Backup Server**, user `pve@pbs!pve`,
the token secret as password and the fingerprint from above. Since the token cannot delete
backups, leave retention to the PBS prune job. Client-side encryption can be enabled on the
same dialog; store the key somewhere outside the PVE host.

## Security

PBS holds the keys to all your backups, so treat it as the most sensitive host on the network:

- **Keep port 8007 off the internet.** Publish it on a LAN address only (`192.0.2.10:8007:8007`)
  and use a VPN for remote access.
- **Least privilege for clients.** Give Proxmox VE a `DatastoreBackup` token (see above): it can
  add and restore backups but cannot delete them.
- **Two-factor login** for `admin@pbs`: **Access Control → Two Factor Authentication** (TOTP or WebAuthn).
- **Client-side encryption** in Proxmox VE, so the server only ever stores encrypted chunks. Keep
  the key somewhere other than the PVE host.
- **Protect `/etc/proxmox-backup`.** It holds the server's private keys and the user database.
- **Container privileges.** The examples above and `compose.yaml` run with `no-new-privileges` and
  only `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID`, `SETGID`, `NET_BIND_SERVICE` and `KILL`; CI tests
  exactly that. As upstream, the API daemon runs as root inside the container, the proxy as `backup`.
- **Supply chain.** PBS comes from the official Proxmox repository with the keyring pinned by sha256.
  GitHub Actions are pinned by commit SHA, lint tools by image digest, and the workflows are audited
  with [zizmor](https://github.com/zizmorcore/zizmor). Images carry an SBOM; build provenance is off
  because in GitHub Actions it would embed the push event, including committer e-mail addresses.

## Updating

```bash
docker compose pull && docker compose up -d
```

Do **not** use **Administration → Updates → Upgrade** in the web UI. It upgrades packages inside
the running container, the daemons are not restarted, and the changes disappear with the next image.

## Limitations

Docker is not a platform Proxmox supports for PBS. Everything that needs systemd or the host
is unavailable:

- **Administration → Services, Syslog, Network, Time** do not work.
- No daily update timer: no "updates available" notifications and no automatic ACME renewal.
  The self-signed certificate is valid for 1000 years, or upload your own.
- No disk, ZFS or tape management.
- The web UI shell is not usable (`root@pam` has no password); use `docker exec -it pbs bash`.
- A daemon reload (`SIGHUP`) restarts the container.

## Synology DSM

- Over SSH, Docker lives in `/usr/local/bin/docker`.
- Container Manager does not create missing bind-mount directories: `mkdir -p etc lib logs` next to `compose.yaml`.
- Shared folders use Synology ACLs that do not know uid 34. Use a dedicated shared folder on a
  redundant volume and hand a sub-directory over to plain Linux permissions:

  ```bash
  mkdir /volume1/pbs/store
  /usr/syno/bin/synoacltool -del /volume1/pbs/store
  chown 34:34 /volume1/pbs/store && chmod 750 /volume1/pbs/store
  ```

  Mount it with `/volume1/pbs/store:/backups` and create the datastore at `/backups`.

## Tags

| Tag | Meaning |
|---|---|
| `latest` | newest build |
| `4`, `4.2`, `4.2.8` | follow the PBS version |
| `4.2.8-1` | exact Debian package version |

Images are rebuilt weekly even without a new PBS release (Debian security updates). Pin a digest
if you need byte-for-byte reproducibility.

## Architectures

Only `linux/amd64` for now: Proxmox publishes server packages for amd64 only. arm64 builds exist
only as community rebuilds (for example
[wofferl/proxmox-backup-arm64](https://github.com/wofferl/proxmox-backup-arm64)). The CI matrix is
prepared for `linux/arm64` on native GitHub runners.

## Building and testing locally

```bash
docker build -t pbs:local .
docker build --build-arg PBS_VERSION=4.2.8-1 -t pbs:4.2.8-1 .   # pin a version
tests/e2e.sh pbs:local
```

The test needs Docker and bash. It starts throwaway containers on a private network and removes
them when it finishes.

## CI

| Workflow | Runs on | What it does |
|---|---|---|
| [CI](.github/workflows/ci.yml) | push, PR | hadolint, shellcheck, actionlint, zizmor (workflow security), compose validation |
| [Tests](.github/workflows/test.yml) | push, PR | builds the image and runs the end-to-end test |
| [Build](.github/workflows/build.yml) | `main` only: push, weekly, manual | resolves the newest PBS version, builds, tests, pushes by digest, creates the multi-arch manifest and tags, syncs this README to Docker Hub |

## License

The files in this repository are released under the [MIT License](LICENSE).
The image contains Proxmox Backup Server, licensed under the AGPL-3.0 by Proxmox Server Solutions
GmbH, and Debian packages under their respective licenses.

This project is not affiliated with or endorsed by Proxmox Server Solutions GmbH.
Proxmox® is a registered trademark of Proxmox Server Solutions GmbH.
