# GO/NO-GO — `remediate-tier1-baseline.sh` execution

| Field | Value |
|---|---|
| Date | 2026-08-14 |
| Mode | HUMAN-EXECUTES — agent prepared and analyzes only; human runs all `sudo` steps |
| Script | `scripts/security/remediate-tier1-baseline.sh` (S0 review: all PASS, see `remediation-review-20260814.md`) |
| Compliance | ISO 27001:2022 A.8.32 (change management), SOC 2 CC3.1 (control activities) |
| **Decision** | **SUPERSEDED — apply never executed; see `remediation-postapply-20260814.md` (INC-20260814-01). Pre-flight and prediction set remain valid for a future apply.** |

## STEP 1 — Dry run (operator executes exactly this, from the repo root)

```bash
sudo DRY_RUN=1 bash scripts/security/remediate-tier1-baseline.sh \
     | tee /tmp/rem-dryrun.log
```

Paste the full output back. `/tmp/rem-dryrun.log` contains paths/modes only
(never secret material) but is still confidential — delete after analysis.

## Pre-flight evidence (captured read-only, 2026-08-14)

| Check | Result |
|---|---|
| `age` binary | ✅ `/usr/bin/age` v1.1.1 |
| Vaultwarden reachable | ✅ `jol-vaultwarden` Up (healthy) |
| Session logging | ✅ `SCRIPT_COMMAND_LOG` unset, no `script` process, no tmux `pipe-pane` |
| Plaintext dump present | ✅ `/opt/jol/backups/jol_lt_platform_prod_backup_2026_07_18.dump` — 223922 bytes, mode `664 jol:jol` |
| World-writable baseline | 295 objects (audit `world_writable.txt`) |
| Free space `/opt/jol` | 506 G — ample |

## STEP 2 — Analysis contract (what the pasted output is graded against)

**Fail triggers (any one → NO-GO):**
1. Any `ABORT` line — must be **zero** in a dry run
2. Any `command not found` — must be **zero**
3. Any `CHANGED` line — dry run must emit `DRYRUN`/`SKIP` only
4. Any target path outside the R1–R4 list below → **STOP**, escalate

### Predicted DRYRUN set (== future APPLY `CHANGED` set)

| Req | Predicted line (target → goal state) | Count |
|---|---|---|
| R1 | `/home/jol/secrets` 775 jol:jol → 700 root:root | 1 |
| R1 | `/home/jol/secrets/vaultwarden` 775 → 700 root:root | 1 |
| R1 | `db.sqlite3`, `db.sqlite3-shm`, `db.sqlite3-wal`, `rsa_key.pem` → 600 root:root | 4 |
| R2 | dump interim: 664 → 600 jol:jol | 1 |
| R2 | `DRYRUN age-encrypt ... -> /opt/jol/backups/encrypted/*.age, verify round-trip, then remove plaintext` | 1 |
| R3 | `DRYRUN move old /var/log residue under /opt/jol/backup/log-residue-20260221 (700 root:root)` | 1 |
| R4 | `DRYRUN chmod o-w on all N objects` — expected N ≈ 295 (accept 290–300; outside → justify) | 1 |
| R4 | group-write 775 → 755: `/opt/jol/git`, `/.pnpm-store`, `/.idea`, `/Project-Level-Configuration`, `/backups/backup` | 5 |
| R4 | `/opt/jol/backups` → 755 jol:jol — **already converged**; will log CHANGED with identical before/after (cosmetic no-op, justified) | 1 |

**Justified SKIPs (expected, benign):**
- `SKIP /opt/jol/backups/encrypted (absent)` — ENC_DIR does not exist until apply

Any *other* SKIP (e.g., a R1 path reported absent) → investigate before GO.

## STEP 3 — Apply (only after GO; operator executes)

```bash
sudo bash scripts/security/remediate-tier1-baseline.sh \
     | tee /tmp/rem-apply.log
```

The passphrase prompt reads from `/dev/tty` (hidden input) and works through `tee`.
Apply-phase change log: `/var/log/jol-remediation/` (700 root).

### Operator checklist before typing the passphrase

- [ ] Passphrase ≥ 16 chars, high-entropy — **create the Vaultwarden entry first**
      (org vault) so it can be stored immediately; losing it loses the only prod DB backup
- [ ] Private terminal: no screen share, no recording, physically private
- [ ] No session logging — re-verify: `echo $SCRIPT_COMMAND_LOG`, `pgrep -a script`,
      tmux `pipe-pane` off (all verified clean at pre-flight; confirm unchanged)
- [ ] Vaultwarden reachable — confirmed healthy at pre-flight; if container was
      restarted since, re-check `docker ps --filter name=jol-vaultwarden`
- [ ] No other process writing `/opt/jol/backups/` during the run
- [ ] After completion: `docker restart jol-vaultwarden` + health check (R1 changed
      ownership of its data files), then re-run `/home/jol/jol_baseline_audit.sh`
      to capture the post-remediation baseline (before/after evidence pair)

## STOP-IF

Any unexpected `CHANGED`/`DRYRUN` target outside the R1–R4 path list above →
halt, preserve `/tmp/rem-dryrun.log`, escalate to the security owner. Silence is
never consent.
