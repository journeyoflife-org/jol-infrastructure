# Post-Apply Verification — `remediate-tier1-baseline.sh`

| Field | Value |
|---|---|
| Date | 2026-08-14 |
| Mode | HUMAN-EXECUTES + AGENT-VERIFIES (all checks read-only, run as user `jol`) |
| Claimed state | Apply run completed with exit 0 |
| **Verified state** | **Apply was NOT executed. Zero R1–R4 effects present on disk.** |
| **Verdict** | **FAIL — incident record drafted (SOC 2 CC7.2); NO auto-fix per gate** |

## 1. Verification checks

| # | Check | Expected (post-apply) | Observed | Verdict |
|---|---|---|---|---|
| 1 | Change log: CHANGED lines for C1/C2/R3/R4 + round-trip cmp line | Present | `/var/log/jol-remediation` exists but is `700 root:root` — unreadable as `jol`; no `/tmp/rem-apply.log`. Directory birth/mtime `2026-08-14 17:37:54` = **a single run moment**, consistent with one dry-run only. No observable CHANGED effects anywhere on disk | **FAIL** |
| 2a | `/home/jol/secrets`, `.../vaultwarden` = `700 root:root` | 700 root:root | **`775 jol:jol` (unchanged)** | **FAIL** |
| 2b | `db.sqlite3*`, `rsa_key.pem` = `600` | 600 | **`644 root:root` (unchanged)** | **FAIL** |
| 2c | Plaintext dump ABSENT | absent | **PRESENT** — `664 jol:jol`, 223922 bytes | **FAIL** |
| 2d | `/opt/jol/backups/encrypted` = 700, exactly one `*.age` | exists | **directory does not exist; zero `*.age` files** | **FAIL** |
| 2e | `log-residue-20260221` = 700 | exists | **absent; backup mount residue unorganized** | **FAIL** |
| 3 | `find /opt/jol -xdev -perm -0002 ! -path '*/tmp/*'` → zero | 0 | **3365 hits incl. symlinks; 295 excl. symlinks — identical to pre-remediation baseline** | **FAIL** |
| 4 | Change-log leak grep (secret values, `BEGIN`, `password=`) | zero | Log unreadable as `jol` — moot given checks 1–3, but unresolved until root reviews the log | **INDETERMINATE** |

Additional: `jol-vaultwarden` Up (healthy) — container never restarted, consistent with
R1 never having run.

## 2. Incident record (SOC 2 CC7.2)

| Field | Value |
|---|---|
| ID | INC-20260814-01 |
| Classification | **Change-management integrity anomaly** — NOT a new data-exposure incident |
| Severity | Medium |
| What happened | A post-apply verification was requested on the premise that the remediation script ran to exit 0. Forensic state shows only ONE script execution moment (17:37:54, per `/var/log/jol-remediation` birth+mtime) and **zero applied effects** — the only run consistent with that evidence is the `DRY_RUN=1` pass. The apply step never executed (or ran on a different host). |
| Data impact | **None new.** The pre-existing C1 (Vaultwarden `644/775`) and C2 (plaintext prod dump `664`) exposures **continue unchanged** — they remain the open findings from audit 2026-08-14. |
| Root cause hypothesis | Process gap: apply step skipped or claimed without execution evidence. No `/tmp/rem-apply.log`, no state delta. |
| Containment | Nothing to contain (nothing executed). No auto-fix performed, per gate. |
| Required human actions | 1. As root, inspect the true change log: `sudo ls -la /var/log/jol-remediation && sudo cat /var/log/jol-remediation/remediation-*.log` — confirm it contains only DRYRUN lines.<br>2. Corroborate: `sudo journalctl _COMM=sudo --since "2026-08-14 17:00"` to enumerate every sudo invocation.<br>3. If confirmed never-applied: re-follow `remediation-gono-go-20260814.md` STEP 3 (checklist included) — the GO analysis remains valid since state is unchanged.<br>4. If the log shows ANY unexpected content: preserve it and escalate before re-running. |
| Corrective action | Execution claims for Tier-1 changes require attached evidence (tee'd log or change-log excerpt) — add to AGENTS.md §4 practice going forward. |
| Lessons learned | Verify-by-state, not by-report: every post-change gate must re-derive state from disk, as this pass did. |

## 3. STOP disposition

Gate condition met (mismatch) → **STOP**. No re-execution, no permission changes, no
script edits by the agent. Awaiting human confirmation of the root-side log review
above before any further stage.
