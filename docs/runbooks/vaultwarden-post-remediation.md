# Runbook — Vaultwarden Post-Remediation Verification

| | |
|---|---|
| Scope | Steps after **R1** of `scripts/security/remediate-tier1-baseline.sh` has been applied (see `docs/security/remediation-postapply-20260814.md` for verification gate) |
| Executor | Human operator (root). Agent performs read-only verification only. |
| Compliance | GDPR Art. 32 (security of processing), ISO 27001:2022 A.8.7 (cryptographic key management), SOC 2 CC8.1 (change logging) |

## Preconditions

- [ ] Post-apply verification confirms R1 effects: `/home/jol/secrets` and
      `/home/jol/secrets/vaultwarden` = `700 root:root`, `db.sqlite3*` and
      `rsa_key.pem` = `600`
- [ ] Maintenance window announced; Vaultwarden is briefly unavailable during restart

## 1. Restart the container

Ownership of the data files changed to `root:root` in R1; the container runs as root,
so a restart re-opens the database cleanly and re-validates access.

```bash
sudo docker restart jol-vaultwarden
```

## 2. Health check

The container carries a configured Docker healthcheck; use both layers:

```bash
# Layer 1 — container health status
docker ps --filter name=jol-vaultwarden --format '{{.Names}}\t{{.Status}}'

# Layer 2 — process-level probe (works regardless of healthcheck config)
docker exec jol-vaultwarden /vaultwarden --version

# Layer 3 — evidence for the change log
docker inspect --format '{{.State.Health.Status}} since {{range .State.Health.Log}}{{.End}}{{end}}' jol-vaultwarden
```

| Command | Expected result |
|---|---|
| Layer 1 | `jol-vaultwarden` status shows **`Up <duration> (healthy)`** within ~30 s |
| Layer 2 | Prints the vaultwarden version string, exit code 0 |
| Layer 3 | `healthy` with a recent timestamp |

**If NOT healthy within 60 s:** capture `docker logs --tail 100 jol-vaultwarden`
into the change record, check for permission errors (would indicate an ownership
mistake in R1), and escalate — do NOT chmod anything ad hoc.

## 3. Store the age backup key in Vaultwarden

The symmetric secret protecting encrypted production backups
(`/opt/jol/backups/encrypted/*.age`) is stored as a Vaultwarden item:

| Field | Value |
|---|---|
| Item name | **`JOL-PROD-BACKUP-AGE-KEY`** |
| Collection | Organization vault (security team access) |
| Type | Secure note / custom field |
| Value | The secret supplied to `age -p` during R2 — typed manually into the UI, never pasted from shell history, terminal scrollback, or any log |

- [ ] Item created and visible to the security collection
- [ ] A test decryption of one archived backup succeeds using the stored value:
      `age -d -p <encrypted file> | head -c 0` must exit 0 (prompt satisfied from the vault entry)
- [ ] Losing this value loses the only production database backup — the item's
      existence is a restore-dependency, record it in the asset register (ISO 27001 A.5.9)

## 4. Backup–restore drill pointer

Restoring from an `age`-encrypted dump is part of the fleet restore-drill program
(3-2-1 rule; pbs01 as the encrypted offsite target). Until a dedicated drill
runbook exists, every drill MUST include:

1. Retrieve `JOL-PROD-BACKUP-AGE-KEY` from Vaultwarden
2. Decrypt the newest `*.age` archive into scratch space **outside** `/opt/jol`
   and outside the Marketplace tree (scope segregation — never restore Tier-1
   church data into marketplace paths)
3. Load into a scratch PostgreSQL instance; row-count sanity check
4. Securely delete the decrypted copy immediately after the drill
5. Log drill date, participant, result, and RTO observation per SOC 2 A1.3

Cadence target: quarterly, and after every change to the backup chain.

## 5. Change-log entry (SOC 2 CC8.1)

Record: restart timestamp, health-check outputs, vault item name created
(**never the value**), drill pointer acknowledgment — in the PR description and
`/var/log/jol-remediation/` as applicable.
