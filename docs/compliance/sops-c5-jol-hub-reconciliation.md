# C5 Reconciliation — jol-hub prior SOPS work vs ADR-003 amendment

> **Status**: RECONCILED 2026-08-26 — closes amendment Condition C5.
> **Basis**: ADR-003 amendment (PR #35, `3dd9fda`) Condition 5; CC8.1 #36.
> **Method**: read-only inspection of jol-hub working tree + compiled-bytecode
> examination (source file lost — see Finding F1). No key material involved.

## 1. Findings

| # | Finding | Evidence |
|---|---|---|
| F1 | `jol-hub/scripts/sops-validate.py` SOURCE IS LOST — only `scripts/__pycache__/sops-validate.cpython-312.pyc` survives (2026-08-13 session era; monorepo refactor churn). The 42 string constants were recovered and archived at session evidence (`/tmp/jol-c5/recovered-constants.txt`) | `find` returns no `*sops*` source; `__pycache__` present |
| F2 | jol-hub `docs/decisions/DECISION-LOG.md` contains NO SOPS decision entry — the toolkit work was never ratified in jol-hub's own audit trail | DECISION-LOG.md D-001..D-005 / O-001..O-007 reviewed |
| F3 | No `.sops.yaml` exists anywhere in the 28-repo fleet; no SOPS-encrypted files tracked | fleet-wide scan 2026-08-26 |
| F4 | The lost validator ALREADY cited "ADR-003 (SOPS + age)" — it anticipated this amendment; its rules are fully compatible (matrix below) | bytecode docstring + pattern constants |
| F5 | `ssss` 0.5-5 present (`ssss-split`/`ssss-combine` in PATH) — D1 tooling satisfied without install | `which ssss-split ssss-combine` |

## 2. Convention compatibility matrix

| Rule | jol-hub validator (F4) | Amendment / this fleet | Verdict |
|---|---|---|---|
| Encrypted root | `secrets/encrypted/` must be genuine SOPS output (`ENC[AES256_GCM` + sops metadata check) | Adoption candidate for Gate 7 creation rules | COMPATIBLE — adopted (R3) |
| `.sops.yaml` content | public `age1...` recipients only; `AGE-SECRET-KEY` = hard error; placeholders warn | Amendment rule 6: private keys never in git | COMPATIBLE |
| Keyring hygiene | `keys.txt` banned from repos; belongs in `$SOPS_AGE_KEY_FILE` on custodian hosts | Amendment rules 2/3 (Vaultwarden SoT + custody plan) | COMPATIBLE |
| Secret patterns | age key, PEM, AKIA, `sk_live_`, `ghp_`/`github_pat_`, `xox[baprs]-`, credential assignments, URL userinfo | fleet-sync preflight uses same family | COMPATIBLE — align (R1) |
| Splitting | not covered | `ssss` (D1, accepted) | ADDITIVE |

## 3. Reconciliation decisions

- **R1**: fleet preflight and any future per-repo validators MUST keep the
  pattern set aligned with the matrix above (single family, no divergence).
- **R2 (open action, jol-hub repo)**: restore `scripts/sops-validate.py` from
  the archived constants + this matrix (bytecode-level fidelity is achievable;
  re-creation owned by jol-hub with a DECISION-LOG entry — fixes F1+F2).
- **R3**: `secrets/encrypted/**` is the fleet convention for Gate 7
  `.sops.yaml` creation rules (per tree, with that tree's recipient only).

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-26 | C5 RECONCILED — all conditions of the ADR-003 amendment now closed; Gate 5 unblocked procedurally (execution still requires owner-present custody actions) | this document; issue #36 |
