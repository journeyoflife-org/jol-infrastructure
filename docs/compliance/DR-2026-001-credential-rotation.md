# DR-2026-001 — Credential Rotation: C1 Vaultwarden Exposure (Church Platform)

| | |
|---|---|
| Record ID | DR-2026-001 |
| Trigger | Finding C1, baseline audit 2026-08-14 (`/home/jol/jol-audit-20260814-172550/`); incident INC-20260814-01 |
| Asset | Vaultwarden secrets store — `/home/jol/secrets/vaultwarden` (org credentials incl. PostgreSQL/MongoDB access values consumed by services as `postgresql.env` / `mongodb.env` environment sets) |
| Status | **OPEN — rotation NOT executed; docs-only preparation** |
| Compliance | GDPR Art. 32/33, SOC 2 CC7.2 (incident response), ISO 27001:2022 A.5.24 (incident management planning), ISO 27001:2022 A.8.24 (use of cryptography) |

## 1. C1 exposure-window analysis (evidence from the BEFORE audit)

### Window bounds (filesystem birth times)

| Bound | Timestamp | Source |
|---|---|---|
| Window start | **2026-08-08 23:46:06 +03** | birth of `/home/jol/secrets`, `.../vaultwarden`, `db.sqlite3`, `rsa_key.pem` |
| Window end | **<applied-at> — still OPEN until remediation R1 runs** | `remediate-tier1-baseline.sh` R1 |
| Known minimum duration | ≥ 6 days as of 2026-08-14 | — |

### Who could read during the window

Misconfiguration: dirs `775 jol:jol` (group-traversable), files `644 root:root`
(world-readable). Read access therefore required **no group membership at all** —
any local account qualified. Group context from the BEFORE audit, for completeness:

| Principal | Group memberships (BEFORE audit) | Read capability during window |
|---|---|---|
| `jol` (uid 1000) | `jol`, `sudo`, `adm`, `docker` | Yes — owner-context and world bit |
| `root` | — | Yes |
| `postgres` (shell account) | — | Yes, via world-read bit |
| Any container/process with host fs access | — | Yes, via world-read bit |
| Network/remote | — | **No** — paths are local filesystem only; no share/export exposed them |

Access universe is therefore: 3 local shell accounts + root + host processes,
on a single-admin workstation. No evidence of access by anyone other than the
administrator has been identified (see §3 likelihood assessment).

### What was exposed

- `db.sqlite3` — Vaultwarden store: account metadata, per-user public keys,
  encrypted vault blobs (attachments/ciphers), device/session records
- `rsa_key.pem` — server identity key; alone it cannot decrypt user vaults, but
  combined with the DB it degrades the client-side-encryption guarantee

## 2. Rotation checklist — EXECUTE window (human-only)

Prerequisite: remediation **applied and verified** (`remediation-postapply-20260814.md`
checks 2a/2b PASS). Rotation without containment first would rotate into a still-open leak.

### 2.1 Vaultwarden server key (top priority)

- [ ] Regenerate the server key pair per Vaultwarden procedure (maintenance window; brief outage)
- [ ] Confirm all enrolled clients re-sync; record any that fail
- [ ] New private key lands only in the now-`700` data dir, mode `600`

### 2.2 PostgreSQL credential set (`postgresql.env` values)

Values are referenced by services via environment injection only — no repo copy
exists (verified 2026-08-14: zero repository references). Rotate at the source:

- [ ] In PostgreSQL: create replacement role credential for the app role; keep old role until cutover completes
- [ ] Update the Vaultwarden item holding the `postgresql.env` value set (never a repo file, never shell history)
- [ ] Roll dependent services (restart/redeploy) so they pick up the injected value
- [ ] Verify app connectivity + one authenticated transaction end-to-end
- [ ] Drop the old role; note time in the change log

### 2.3 MongoDB credential set (`mongodb.env` values)

- [ ] Rotate the application user credential in MongoDB (`db.changeUser` equivalent procedure for the deployed version)
- [ ] Update the Vaultwarden item holding the `mongodb.env` value set
- [ ] Roll dependent services; verify connectivity
- [ ] Remove the old credential; note time in the change log

### 2.4 Sweep and close

- [ ] Grep audit for residual copies of old values: shell histories, `/tmp`, editor swap files, CI logs (names/patterns only — never log the values themselves)
- [ ] Re-run `/home/jol/jol_baseline_audit.sh`; confirm no regression
- [ ] Complete §3 assessment with final evidence; close DR-2026-001 with timestamps
- [ ] Change-log entry per SOC 2 CC8.1: window open/close times, rotated credential **names** (never values), executor

## 3. GDPR Art. 33 likelihood-assessment template

Complete at rotation close. Record in this document; retain per Art. 33(5).

### 3.1 Recipients / access universe

| Question | Answer (fill at execution) |
|---|---|
| Who could have accessed? | 3 local shell accounts + root + host processes (see §1); no network path |
| Any evidence of actual access by non-authorized parties? | ☐ none found ☐ evidence found — attach evidence |
| Data categories affected | Vaultwarden account metadata; encrypted vault blobs; server identity key. Special-category (Art. 9) content: **encrypted at application layer**, not plaintext-exposed |

### 3.2 Severity assessment

| Factor | Assessment |
|---|---|
| Volume | Single workstation store; org-scale account set |
| Sensitivity | High context (religious-belief platform) but blobs were client-encrypted; plaintext special-category data NOT in the exposed files |
| Mitigations in place | Client-side encryption of vault contents; local-only access path; single-operator host |

### 3.3 Likelihood of adverse effects

| Scenario | Likelihood |
|---|---|
| Unauthorized party actually read the files | LOW if §3.1 evidence check finds nothing (single-operator host); escalate to HIGH if any access evidence appears |
| Vault content compromise given read access | MEDIUM — requires DB + server key together; user vault keys add a further barrier |

### 3.4 Notification decision

| Condition | Decision |
|---|---|
| No evidence of unauthorized access AND residual risk low after rotation | **No Art. 33 notification.** Document this assessment and the rationale (Art. 33(5) retention). |
| Any evidence of actual unauthorized access | **Notify the supervisory authority within 72 h** of awareness; assess Art. 34 data-subject communication for high-residual-risk cases |
| Assessment cannot conclude within 72 h | Submit preliminary notification, follow up in phases (Art. 33(4)) |

Decision (fill at execution): ☐ no notification, documented ☐ notification filed at <time>

## 4. Tracker

| Task | Owner | Status |
|---|---|---|
| EXECUTE rotation per §2 (DR-2026-001) | Human operator | **OPEN** |
| Apply + verify remediation R1/R2 (precondition) | Human operator | OPEN (INC-20260814-01) |
| Complete Art. 33 assessment §3 | Security owner | OPEN |
