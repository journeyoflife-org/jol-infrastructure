# S0 Verification Review — `scripts/security/remediate-tier1-baseline.sh`

| Field | Value |
|---|---|
| Review date | 2026-08-14 |
| Stage | S0 — VERIFY-ONLY (script NOT executed) |
| Artifact under review | `scripts/security/remediate-tier1-baseline.sh` (191 lines, commit `48ee176`-era working copy) |
| Baseline evidence referenced | `/home/jol/jol-audit-20260814-172550/` |
| Compliance | ISO 27001:2022 A.8.32 (change management), SOC 2 CC3.1 (control activities) |
| Overall verdict | **PASS** — gate open, no patch PR required |

## 1. Check results

| # | Check | Method | Verdict |
|---|---|---|---|
| V1 | `shellcheck -S warning` clean | `shellcheck -S warning` → exit 0; also `-x -S warning` (pre-commit equivalent) → exit 0 | **PASS** |
| V2 | Traceability R1–R4, C1–C2 → code | Manual mapping, §2 below; zero coverage gaps | **PASS** |
| V3a | R2 order: encrypt → cmp round-trip → remove | Line-order inspection, §3.1 | **PASS** |
| V3b | ABORT paths retain plaintext | §3.2 | **PASS** |
| V3c | `apply_stat()` idempotent | §3.3 | **PASS** |
| V3d | No `set -x` / xtrace near secret input | `grep -n 'set -x\|set -o xtrace\|xtrace'` → zero hits | **PASS** |
| V3e | Change log never receives secret material | Data-flow inspection, §3.4 | **PASS** |
| V4 | Change-log target: `700` dir / `600` file | L40–41 (dir), L187 (file) | **PASS** |

## 2. Traceability table (requirement → construct → lines)

| Req | Audit finding | Construct | Lines | Notes |
|---|---|---|---|---|
| R1 | C1 (Vaultwarden exposure) | main flow + `apply_stat` | 76–89 | Dirs L78–79; files loop L80–85; operational NOTEs L86–89 |
| R2 | C2 (plaintext prod dump) | main flow + `apply_stat` | 91–130 | Interim hardening L100; encrypt L114; verify L117; remove L118; NOTEs L128–130 |
| R3 | §15 backup-dir ambiguity | main flow | 132–155 | Quarantine L141–144; README L145–151; wipe decision deliberately manual L155 |
| R4 | §4 world-writable objects | main flow + `apply_stat` | 157–177 | Inventory L161–164; sweep L170; group-write normalization L174–177 |
| C1 | — | covered by R1 (L78–85); rotation deferred to human gate (header L23, NOTE L88–89) | — | Correct per AGENTS.md §3 — rotation requires human approval |
| C2 | — | covered by R2 (L96–126); offsite replication to pbs01 deferred (L130) | — | Documented out-of-scope, tracked |
| — | SOC 2 CC8.1 change log | guards `mkdir/chmod` L40–41, `log()` L43, pre-state L68–74, post-state L180–186, `chmod 600` L187 | — | Full before/after evidence chain |
| — | Guard rails | root check L35–38, `age` presence L39, `set -euo pipefail` L27 | — | — |

**Gaps found: none.** Every audited finding maps to executed logic or to an explicitly
documented human-gated follow-up.

## 3. Safety properties — proof by inspection

### 3.1 R2 operation order (PASS)

- L114 `age -p -o "$ENC" "$DUMP"` — encryption first.
- L117 `echo -n "$PASS" | age -d "$ENC" | cmp -s - "$DUMP"` — round-trip decryption
  compared byte-for-byte against the original, inside an `if` condition.
- L118 `rm -f "$DUMP"` — plaintext removal occurs **only inside the `then` branch** of
  a successful comparison. No removal path exists outside it.

### 3.2 ABORT paths retain plaintext (PASS)

- Short input (L110–113): logs `ABORT`, `exit 1` — encryption has not yet been
  attempted, plaintext untouched.
- Round-trip failure (L120–123): logs `ABORT`, `exit 1` — `rm` never reached; message
  states plaintext retained.
- `age` itself failing at L114 under `set -e` also exits before L118, plaintext intact.

### 3.3 `apply_stat()` idempotence (PASS)

- L49: absent path → logged `SKIP`, `return 0` (no failure on re-run).
- L52–55: `DRY_RUN=1` → preview only, `return 0`.
- L56–57: `chmod`/`chown` are state-convergent — re-application with identical target
  values changes nothing observable; before/after values are captured (L51, L58).
- R2 re-run: L96 detects absent dump → `SKIP`; R3 re-run: L135 detects existing
  archive → `SKIP`. Sections are safe to re-execute.

### 3.4 Secret hygiene (PASS)

- No xtrace anywhere (verified by grep); the prompt at L108 writes a literal string to
  `/dev/tty` only; input read with `read -rs` (hidden, no shell history).
- `log()` invocations carry paths, modes, owners, and static notes only — never the
  secret value; only its **length** is tested (L110), never emitted.
- Pre/post snapshots (L70–73, L182–185) use `stat` metadata only — no file contents.
- `WW_LIST` (L161–164) contains paths only.
- `unset PASS` (L124) clears the variable after use.

## 4. Change-log target hardening (PASS)

- L40–41: `mkdir -p /var/log/jol-remediation` + `chmod 700` — root-only directory.
- L187: `chmod 600 "$LOG"` before the final summary lines.

## 5. Observations (non-blocking, no FAIL)

| # | Observation | Severity | Disposition |
|---|---|---|---|
| O1 | If `age` fails mid-write at L114, `set -e` exits leaving an orphaned partial `.age` under `encrypted/`; no explicit ABORT log line for this path (plaintext is still safe) | Info | Add `trap ERR` handler or `|| { log ABORT; exit 1; }` in a future hardening pass |
| O2 | L187 chmod-600 lands after the file briefly exists at default umask perms between L43 and L187; content in that window is non-secret metadata, dir is `700` anyway | Info | Optionally `install -m 600` the log at creation |
| O3 | `find ... || true` (L161–164) masks find errors (e.g., unreadable subtree) | Info | Acceptable: script runs as root; inventory completeness is re-verified by post-run audit |

## 6. Gate decision

All checks **PASS** → no patch PR required. Gate open for the next stage owner;
execution of the script remains subject to the AGENTS.md human-approval gates
(elevated-rights execution) and the mandatory change log.
