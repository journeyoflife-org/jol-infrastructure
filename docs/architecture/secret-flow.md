# Secret Flow Architecture

## Vaultwarden → External Secrets Operator → Kubernetes Secret

```
┌──────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  Vaultwarden  │────▶│ External Secrets  │────▶│  Kubernetes     │
│  (self-hosted)│ API │ Operator (ESO)   │ sync │ Secret          │
└──────────────┘     └──────────────────┘     └────────┬────────┘
                                                       │
                                                       ▼
                                                ┌─────────────────┐
                                                │  Application Pod │
                                                │  (env/mount)     │
                                                └─────────────────┘
```

## Flow Steps
1. Secrets are stored in Vaultwarden organized by `{env}/{service}/{key}`
2. `ClusterSecretStore` defines the Vaultwarden connection (webhook provider)
3. `ExternalSecret` resources in each namespace request specific secrets
4. ESO polls Vaultwarden on `refreshInterval` (default: 1h)
5. ESO creates/updates native Kubernetes `Secret` objects
6. Pods mount secrets via `envFrom` or `volumeMounts`

## Security Controls
- Vaultwarden API token stored in Kubernetes Secret (bootstrapped manually)
- IRSA role for ESO limits AWS access to secret retrieval only
- Network Policy restricts ESO pod egress to Vaultwarden + K8s API only
- All secrets encrypted at rest (KMS) and in transit (TLS)
- Audit log: Vaultwarden records all access events

## Secret Rotation
1. Update secret value in Vaultwarden
2. ESO detects change on next refresh cycle
3. Kubernetes Secret is updated
4. Application detects change via file watch or restart
5. Old secret value invalidated at the service level

## On-prem Instance (operator workstation — corrected 2026-10-22)

**This section previously stated the vault runs on `admin01` (deployed 2026-08-08,
issue #26). That is wrong, and the error caused a multi-hour outage of the backup
onboarding on 2026-10-21/22: while hunting a pbs01 password we concluded "the vault
is unreachable because admin01 is unreachable", when in fact the vault has always
been running on the machine we were typing on.**

Verified live state (2026-10-22, `docker ps` / `docker inspect` / `ss -tlnp`):

| Item | Reality |
|------|---------|
| Host | the operator **workstation** (`hostname` = `ubuntu`, Ubuntu 24.04.5, `192.168.88.249/24` on `enp8s0`) — **not** admin01 (`10.10.10.50`, a separate box, currently off the network) |
| Container | `jol-vaultwarden`, image `vaultwarden/server:latest`, `Up … (healthy)`, `restart=unless-stopped` |
| Binding | published as `127.0.0.1:8090->80`; `ROCKET_ADDRESS=0.0.0.0` inside the container, so the loopback publish is the only thing limiting reachability |
| Liveness | `http://127.0.0.1:8090/alive` → **200** (reachable from this machine, no TLS, no credentials needed to see it) |
| Data | `/home/jol/secrets/vaultwarden` (316 K): `db.sqlite3` 278 528 B, `-shm`, `-wal`, `rsa_key.pem`, `tmp/`; dir `700 jol:jol` |
| Filesystem | `/home` = plain ext4 on `nvme0n1p7`, **not encrypted**, 80 % used (18 G free) |
| Backup | **none** — no cron, no systemd timer, no archive anywhere on this host |

### Configuration defects found (open, each needs an operator decision)

| # | Finding | Why it matters | Fix |
|---|---------|----------------|-----|
| V1 | `SIGNUPS_ALLOWED=true` | anyone who can reach the port can create accounts and use the instance as free infrastructure; harmless only while the loopback binding holds, dangerous the moment a proxy or a `-p 8090:80` change lands | `SIGNUPS_ALLOWED=false`, `INVITATIONS_ALLOWED=false` |
| V2 | `ADMIN_TOKEN` is a **plaintext 64-char value** (not Argon2-hashed) | readable by any member of the `docker` group via `docker inspect` (that includes ordinary operator shells and CI agents), and by anything reading the compose/run file or shell history; the admin panel can reset vault users | generate a hash (`docker exec -it jol-vaultwarden /vaultwarden hash`) and store only the hash, in a `600`-mode env file owned by root |
| V3 | Image tag `:latest`, no digest | an unreviewed `docker pull` can change the credential server underneath you; the fleet convention is SHA/digest pinning with a rollback path | pin by digest (`vaultwarden/server@sha256:…`), record the previous digest |
| V4 | No backup of `/home/jol/secrets/vaultwarden` | the **only** copy of every fleet credential sits on one unencrypted partition of a daily-driver desktop; disk loss = unrecoverable, fleet-wide credential event. Vaultwarden's own README: "We cannot be held liable for any data loss … we highly recommend performing regular backups" | `scripts/maintenance/vaultwarden-backup.sh` (pause → consistent copy → verify SQLite integrity → `600` archive + SHA256, 14-copy retention), plus an off-machine copy and an offline recovery kit |
| V5 | No TLS, `DOMAIN=http://127.0.0.1:8090` | fine while loopback-only (browsers treat `localhost` as a secure context), fatal if ever exposed on a LAN — master passwords and vault payloads would cross the network in cleartext | put a TLS reverse proxy in front **before** any non-loopback binding; never widen the port first |
| V6 | No `sqlite3` CLI on the host or in the image | a naive `cp db.sqlite3` while the service is live can capture a torn/mid-transaction state | the backup script freezes the container (`docker pause`) and copies the db + `-wal` + `-shm` as one set, then verifies with `PRAGMA integrity_check` |

### Standing rules (unchanged, and reinforced by this incident)

The on-prem fleet keeps its own Vaultwarden for credentials that never enter
Kubernetes (switch, host-local accounts):

- Items are stored per `{env}/{domain}/{host}/{key}`, e.g.
  `prod/network/n2048-admin`, and are client-side encrypted (usable by
  standard Bitwarden clients)
- Browser use requires putting a TLS reverse proxy in front first
  (WebCrypto requires HTTPS); until then retrieve items via API
- Never write secret values into this repository; helper scripts read
  them from environment variables (see `scripts/network/`)
- **The agent must not read `/home/jol/secrets/**` or any vault content**
  (Tier-1 forbidden list). Retrieval is a human action; the operator pastes
  secrets into the target system's own form, never into a chat or a command line
- A credential store is not a backup, and a backup target is not a key store:
  keep the vault backed up (encrypted, off-host) and keep key material out of
  ordinary config backups
