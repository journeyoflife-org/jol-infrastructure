# ISO 27001 A.8.32 — Remediation Before/After Evidence Pair

| | |
|---|---|
| Date | 2026-08-14 |
| Purpose | Cryptographically anchored before/after evidence pair for the Tier-1 baseline remediation (`scripts/security/remediate-tier1-baseline.sh`) |
| Compliance | ISO 27001:2022 A.8.32 (change management), A.5.9 (inventory of information and other associated assets), SOC 2 CC4.1 (monitoring of controls/evidence) |
| **Status** | **PROVISIONALLY CERTIFIED — all state checks PASS; AFTER report SHA-256 pending root paste (§2)** |

## 1. Evidence inventory (hash-anchored)

| Artifact | Identity | SHA-256 |
|---|---|---|
| BEFORE audit report | `/home/jol/jol-audit-20260814-172550/report.txt` (2349 lines) | `2e9c574ed0e4b039d4ed33836552d8ddb57de7d3bab63862cf50753d83760503` |
| AFTER audit report | `/home/jol/jol-audit-20260814-181427/report.txt` (dir verified `700 root:root`) | **pending root paste — §6** |
| Apply change log (tee) | `/tmp/rem-apply.log` (4388 bytes; canonical copy in `/var/log/jol-remediation/`, root-only) | `13af6bdf371d6c54452cb4b107856c3f9a1f8b8553449920d6ba6e11834173d6` |

Execution timeline (apply log): R1 at 18:10:20 → passphrase interval → R2/R3/R4 at
18:12:25–26; AFTER audit 18:14:27. Zero `ABORT`, zero `command not found`.

## 2. BEFORE → AFTER delta table

| Item | BEFORE (2026-08-14 17:25) | AFTER (2026-08-14 18:14) | Source of AFTER evidence |
|---|---|---|---|
| Plaintext prod dump | present, `664 jol:jol`, 223922 B | **ABSENT** — encrypted to `encrypted/jol_lt_platform_prod_backup_2026_07_18.dump.20260814-181020.age`, round-trip verified, plaintext removed | fs probe + apply log CHANGED line |
| `/opt/jol/backups/encrypted/` | absent | **present, `700 root:root`** (contents root-verified: expect exactly one `*.age` — §6) | fs probe + apply log |
| `/home/jol/secrets` | `775 jol:jol` | **`700 root:root`** | fs probe (traversal denial itself confirms) |
| `/home/jol/secrets/vaultwarden` | `775 jol:jol` | **`700 root:root`** | apply log CHANGED + fs denial |
| `db.sqlite3*`, `rsa_key.pem` | `644 root:root` | **`600 root:root`** | apply log CHANGED lines (file-level stat now root-only by design) |
| `backup/` residue | 16 loose entries at mount root | **quarantined** in `log-residue-20260221` (`700 root:root`), mount root clean | fs probe + apply log |
| World-writable objects (excl. symlinks, excl. tmp) | 295 | **0** | fs probe (recounted); apply log: `removed o+w on 295 objects` — exact match |
| Group-write top-level dirs (`git`, `.pnpm-store`, `.idea`, `Project-Level-Configuration`, `backups`, `backups/backup`) | `775` | **`755`** | fs probe + apply log |
| `/opt/jol/lost+found` | `750 jol:jol` | `750 jol:jol` (unchanged — not a remediation target; noted for inventory completeness per A.5.9) | fs probe |
| `/opt/jol/data/lost+found` | `700 root:root` | `700 root:root` | fs probe |

## 3. Acceptance criteria — remediation queue

| Criterion | Verdict | Evidence |
|---|---|---|
| Item 1 — C1 Vaultwarden perms hardened | **PASS** | §2 rows 3–5; apply log R1 block |
| Item 2 — C2 dump encrypted, verified, removed | **PASS** | §2 rows 1–2; `(verified round-trip, plaintext removed)` line present |
| Item 3 — LUKS encryption-at-rest | **OPEN (deferred project, RR-05)** | Out of script scope by design |
| Item 4 — world-writable sweep | **PASS** | 295 → 0, exact count match |
| Change log complete (SOC 2 CC8.1) | **PASS** | Apply log: 17 CHANGED lines, pre/post snapshots, hash-anchored above |
| Change log free of secret material | **PASS** | Leak grep: zero `BEGIN`/`password=`; "passphrase" appears only in static NOTE text; high-entropy scan = paths only |
| Backup canonical-dir question (audit §15) | **RESOLVED** | Canonical store = `backups/encrypted/`; `backup/` residue quarantined pending wipe decision |

## 4. Risk register — updated

| ID | Risk | Status |
|---|---|---|
| RR-01 | C1 exposure — containment (perms) | **CLOSED** (this evidence pair). Rotation of exposed-era credentials remains **OPEN** per DR-2026-001 |
| RR-02 | C2 plaintext prod dump | **CLOSED** — encrypted, round-trip verified, plaintext removed |
| RR-03 | Misleading `backup/` residue | **CLOSED** — quarantined; wipe decision still manual |
| RR-04 | World-writable objects | **CLOSED** — 295 → 0 |
| RR-05 | No encryption-at-rest (LUKS) / unencrypted swap | OPEN |
| RR-06 | Mount options lack `nosuid,nodev` | OPEN |
| RR-07 | sudoers (`90-jol-nopass`) unverified | OPEN |
| RR-08 | No service-user separation | OPEN |
| RR-09 | Plaintext `.env`/`.env.local` in working trees (7 files) | OPEN |
| RR-10 | No offsite backup replication to pbs01 | OPEN |
| RR-11 | Prometheus 9090 + Dropbox 17500 on 0.0.0.0 | OPEN |
| RR-12 | Hygiene: `qoder/`, `Project-Level-Configuration/`, `.Trash-1000`, `postgres-ca.crt` dir | OPEN |
| RR-13 | HTTPS git remotes not normalized to SSH | OPEN |
| RR-14 | TruffleHog hook env broken locally | OPEN |
| RR-15 | **NEW** — residual group-write inside repo internals, `.idea`, `logs` (R4 normalized top-level only by design; git-config policy decision pending) | OPEN |

No residual was dropped; RR-05..RR-15 carry forward to the next change cycle.

## 5. Incident addendum — resolution note

INC-20260814-01: the earlier unevidenced claims were superseded by an evidenced run —
apply executed 18:10–18:12 with tee'd change log, AFTER audit 18:14:27, state
independently re-derived from disk by the verifier. The process control introduced
after the incident ("no execution claim accepted without pasted artifact") **worked as
designed** and is retained permanently. Incident status: closed for integrity concern;
C1 credential rotation follow-up continues under DR-2026-001.

## 6. One pending item to finalize certification (root paste)

The AFTER report is `700 root:root` — correctly sealed, but its hash must come from root:

```bash
sudo sha256sum /home/jol/jol-audit-20260814-181427/report.txt
sudo ls -la /opt/jol/backups/encrypted/     # confirm exactly one *.age, 600 root:root
```

On paste, this document flips to **CERTIFIED** and the pair is complete. Marketplace
evidence lives in `jol-m-compliance` — never commingled here.
