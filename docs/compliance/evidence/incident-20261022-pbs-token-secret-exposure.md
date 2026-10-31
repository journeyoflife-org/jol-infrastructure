# Security Incident: PBS Backup Token Secret Exposed in an Agent Session

| Field | Value |
|-------|-------|
| **Incident ID** | INC-20261022-TOKEN-EXPOSURE |
| **Date** | 2026-10-22 |
| **Severity** | **HIGH** — live service-principal credential for the fleet's backup custodian |
| **Classification** | Secret management violation (AGENTS.md §0.1 zero tolerance) |
| **Status** | CONTAINMENT PENDING — rotation + silent re-install required before use |
| **Credential** | `pve-backup@pbs!pve-token` (PBS API token). **Its value is deliberately not recorded here** — writing it into a tracked file would create a second copy. |

## 1. What happened

While executing the hv01 → pbs01 backup onboarding, the operator ran the token rotation
on `pbs01` and pasted the **full command output**, including the one-time `value` field,
into an agent chat session:

```
proxmox-backup-manager user generate-token pve-backup@pbs pve-token --expire 0 --comment "hv01 vzdump push ns jol-hv01"
Result: { "tokenid": "…", "value": "<SECRET — not recorded here>" }
```

This is the same failure class as INC-20260925-PWD-EXPOSURE (prox01 root password), with one
material difference: a PBS token is a **scoped, machine-readable credential accepted directly
by the API on port 8007**, so no password-reuse investigation is needed — but it is also usable
by any workload that can reach that port.

## 2. Exposure surface (measured, not assumed)

| Location | Evidence | Disposition |
|----------|----------|-------------|
| Agent session transcript on disk | `-rw-r--r-- 1 jol jol 298788 … ~/.qoder/cache/projects/jol-infrastructure-d819ad4a/conversation-history/b92c3c8f/b92c3c8f.jsonl` | **World-readable (0644) file containing a live credential.** Any local user/process on the workstation can read it. |
| pbs01 console scrollback | the `root@pbs01` UI/SSH shell that printed it | Cleared by closing the session tab. |
| Operator clipboard | by definition | Volatile. |
| Session context sent to the model provider | inherent to the chat transport | Not recoverable by us; treated as disclosed. |

The value was **never** written into a git-tracked file, and it is not in `pbs01.pw`
(verified `wc -c` = 1, mtime unchanged at 2026-10-21T22:12), so no host config carries it.

## 3. Blast radius if the value is used

- What the token can do (granted 2026-10-22T20:06Z): `DatastorePowerUser` on
  `/datastore/pbs-store/jol-hv01`, `propagate=1` → effective `Datastore.Backup` +
  `Datastore.Prune` (+ implied Read/Verify on groups it owns).
- Reachability of the API it authenticates to: pbs01 `8007/tcp` accepts from
  `10.10.10.0/24`, **`10.60.60.0/24`** (the hypervisor segment — every AI-service VM shares it),
  `10.30.30.10`, and `192.168.88.249/32`.
- Therefore an attacker positioned on any workload on pve-prod-hv01 could **write fake backups into
  the namespace and prune/delete the real ones** — the availability/integrity leg of the
  "delete the backups, then encrypt" sequence. It cannot read or destroy the `jol-llm` namespace
  (different principal), and it is not root, not datastore-wide, and not an admin-plane credential.
- Client-side encryption limits confidentiality impact: the token alone cannot decrypt backup
  content; `/etc/pve/priv/storage/pbs01.enc` on hv01 is not exposed by this incident.

**Compliance:** ISO 27001 A.9.2.4 (password/user ID management), A.8.13 (backup segregation —
the exposed credential is the one the backup data path uses), GDPR Art. 32(1)(a) and Art. 5(1)(f)
(backups contain Art. 9 special-category document data), SOC 2 CC6.1 (logical access), CC6.2,
CC7.2 (detection), AGENTS.md §0.1.

## 4. Containment (do in this order)

1. **Rotate again, and install the new value in the same pipeline so it is never displayed.**
   Run as ONE line from the workstation — this is the point of the shape: `generate-token` output
   goes through `sed` into `ssh … tee`, stdout is consumed, `tee` writes the file and discards its
   own copy, so the secret appears on **no** screen, in **no** shell history (it is generated, not
   typed), and in **no** chat:
   ```bash
   ssh pbs01 'proxmox-backup-manager user delete-token pve-backup@pbs pve-token 2>&1 1>/dev/null;
              proxmox-backup-manager user generate-token pve-backup@pbs pve-token --expire 0
              --comment "hv01 vzdump push ns jol-hv01"' 2>/tmp/gen.err \
     | sed -n 's/.*"value"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
     | ssh pve "sudo tee /etc/pve/priv/storage/pbs01.pw >/dev/null"
   ```
   ⚠ **Corrected against the live host 2026-10-22T20:39Z (the first version of this recipe failed twice):**
   (i) `generate-token` **rejects `--output-format`** in PBS 4.2 (`schema does not allow additional
   properties`), so use the default output; (ii) that output is `"value": "<uuid>"` **with a space**, so the
   `sed` must be space-tolerant; (iii) keep the remote command's **stderr off the pipe** (`2>/tmp/gen.err`
   on the client side), otherwise an error message is fed to `sed` and, if it happens to match, into the file.
   The old, exposed value stops working the instant the `delete-token` runs — which also means a failed
   install leaves the datastore in the **fail-closed** state (no credential, no token), never in an open one.
3a. **⚠ RE-APPLY THE TOKEN'S GRANTS — `delete-token` PRUNES ITS ACL ROWS (learned the hard way).**
   Without this the credential authenticates but sees nothing (`Cannot find datastore 'pbs-store'`):
   ```bash
   ssh pbs01 'proxmox-backup-manager acl update /datastore/pbs-store/jol-hv01 DatastorePowerUser \
                --auth-id "pve-backup@pbs!pve-token" --propagate 1'
   ssh pbs01 "proxmox-backup-manager user permissions 'pve-backup@pbs!pve-token'"   # Backup + Prune expected
   ```
2. **Verify structurally, never by printing the file** — a PBS token value is a UUID, so both
   counts must be `36`, mode must stay `0600`:
   ```bash
   ssh pve "sudo wc -c /etc/pve/priv/storage/pbs01.pw; sudo sh -c \"tr -cd 'A-Za-z0-9-' < /etc/pve/priv/storage/pbs01.pw | wc -c\"; sudo stat -c '%a %U:%G' /etc/pve/priv/storage/pbs01.pw"
   ```
   `0` = the `sed` did not match (rotate again); `37` = a newline got in, which is exactly the
   defect class that produced the earlier 1-byte file.
3. **Confirm the credential works, by effect not by echo:** `ssh pve -t 'sudo pvesm status | grep pbs01'`
   must change `inactive` → `active`.
4. **Do not** put the value in a ticket, chat, commit, or this file.

## 5. Detection during the exposure window (~20:06Z → rotation)

Measured 2026-10-22T20:27Z:

| Probe | Result | Interpretation |
|-------|--------|----------------|
| `ss -tn state established "( sport = :8007 )"` | three connections, **all** from `10.60.60.20` (hv01 storage polls) | No unexpected peer. |
| `proxmox-backup-manager task list --all` | only scheduled `aptupdate`/`prunejob`/llm `backup`+`prune` and the operator `termproxy` sessions | No foreign `backup`/`prune`/`verify` task in the window. |
| `fail2ban-client status sshd` | 0 failed / 0 banned | No SSH brute force on pbs01. |
| `journalctl -u proxmox-backup --since "20:00" \| grep -iE "authenticat\|401\|token"` | **empty** | ⚠ **This is NOT a clean bill of health.** Known `401 Unauthorized` events from hv01 occurred in the same window and do not appear in that unit's journal, so the query cannot detect token misuse. Recorded as a detection gap, not as evidence of no use. |

⚠ **Open detection gap:** PBS API authentication events for token use are not in a queryable place
on pbs01, and the audit trail is **local-only** (`auditd` plugins all `active = no`, proven earlier
the same day), so we cannot positively prove non-use — only that the obvious signals are quiet.
Needed: API-access logging confirmed for the datastore/reader endpoints plus off-host shipping.

## 6. Preventive measures

1. **Rule (this incident's actual cause):** command *output* is as much a secret as command input.
   `generate-token` prints a one-time value → it must be **piped to its destination, never screen-printed,
   never pasted into a chat/ticket**. Adopted in `docs/runbooks/hv01-storage-backup-reconfiguration.md`
   and `docs/servers/pbs01.md` step 3 as the standard form.
2. Runbooks must show the pipeline form (step 4.1 above) instead of "copy the printed secret",
   removing the human step that creates the copy.
3. Add a watchdog gate on pbs01: alert on any `backup`/`prune` task by
   `pve-backup@pbs!pve-token` outside the 02:00–03:59 window — the least-privilege namespace still
   allows that principal to delete, so time-window anomaly is the practical detector.
4. Close the two systemic gaps already logged for this host, which this incident makes urgent:
   off-host audit shipping (local-only trail) and API auth logging.
5. Credential custody is still broken independently of this incident: the Vaultwarden vault showed
   *"No items in the vault"*, so pbs01 `root` and the hv01 `root` passwords are held only in the
   operator's memory. Store them (never their values in chat) as part of closing this incident.

## 7. Verification gates

- [x] Token re-rotated (exposed value invalidated) — `user delete-token` executed 2026-10-22T20:38Z
- [x] New value installed via the no-print pipeline; `pbs01.pw` = 36 valid chars (37 bytes with the newline
      the plugin tolerates), mode `600 root:www-data` — verified structurally, never by printing the file
- [x] Token grants **re-applied** after rotation (see 3a) and read back as Backup + Prune
- [x] `pvesm status | grep pbs01` → **`pbs01 pbs active`** (2026-10-22T20:39Z)
- [x] Backups actually landed and the restore drill passed — evidence
      `pbs01-admin-ssh-20261022.txt` §17e–§17f
- [x] Console session that printed the value ended
- [ ] CHANGELOG rows + this record committed with the CC8.1 issue
- [ ] pbs01 + hv01 `root` credentials and this token placed in Vaultwarden
- [ ] Watchdog time-window gate for the token implemented
- [ ] Negative-encryption test (restore without the key MUST fail) still outstanding

## 8. Rollback

Not applicable — rotation is irreversible by design. If the new value is lost, repeat step 4.1
(the old value is invalid either way). If the install pipeline writes a bad file, `pvesm status`
stays `inactive` and the datastore is simply unusable — no backup is written with a broken
credential, and the pre-existing namespace ACLs are unaffected.

## 9. References

- AGENTS.md §0.1 (secret management), §0.3 (change control), §0.4 (verification rule)
- `docs/compliance/evidence/incident-20260925-prox01-root-password-exposure.md` — precedent, same class
- `docs/compliance/evidence/pbs01-admin-ssh-20261022.txt` §14–§16 — grant/rotation context
- `docs/runbooks/hv01-storage-backup-reconfiguration.md` §3 steps 3–5, §4 rollback
- `docs/servers/pbs01.md` §Pending onboarding (token + ACL history)
- ISO 27001:2022 A.9.2.4, A.8.13; GDPR Art. 32(1)(a), Art. 5(1)(f), Art. 9; SOC 2 CC6.1, CC6.2, CC7.2
