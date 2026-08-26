# ADR-003 Amendment — Git-At-Rest Secret Encryption (SOPS + age, Dual Identity)

> **Amends**: `docs/adr/ADR-003-secrets-management.md`
> **Status**: PROPOSED — pending security-team approval (human approval gate;
> this document changes nothing and authorises no implementation).
> **Date**: 2026-08-26
> **Drivers**: Proposed SOPS gates 4–8 rollout across the 28-repo fleet;
> AGENTS.md §0.1 (zero-tolerance secret policy), §0.2 (tree segregation),
> §1 dependency rule 2 (secret flow); GDPR Art. 5(1)(f)/32, SOC 2 CC6.1,
> ISO 27001:2022 A.8.24 (use of cryptography).
> **Prior art**: jol-hub session "Implement SOPS age toolkit" (2026-08-13,
> `jol-hub/scripts/sops-validate.py`); Gate 4–8 prompt pack reviewed
> 2026-08-26 — this amendment is the Gate-0 policy gate those prompts lacked.

## Context

ADR-003 (Accepted) ratified **Vaultwarden + External Secrets Operator** as
the runtime secret store and rejected Sealed Secrets. It governs *runtime*
secret delivery but does not address a pattern the fleet keeps re-encountering:
**configuration files that must live in git and contain secret material**
(ansible host/group vars, compose env templates, CI fixtures, DR documents).
Today that gap is filled by Ansible Vault only, which does not cover the
non-Ansible repos (26 of 28) and produces diffs that cannot be reviewed.

SOPS + age was proposed via a 5-gate rollout (install → identity → Shamir DR
→ recipient publication → round-trip). The review surfaced one blocking
policy conflict and two design defects that this amendment resolves:

1. **Policy conflict**: SOPS is not in the approved stack; deploying it
   fleet-wide without amending ADR-003 would violate change control
   (SOC 2 CC8.1) and ISO 27001 A.5.9 asset-management expectations.
2. **Segregation defect (rejected as proposed)**: the proposal used ONE age
   identity for all 28 repos across both Tier-1 trees. That merges the
   Church Platform (GDPR Art. 9, PCI-DSS donations) and Marketplace
   (PCI-DSS payments, KYC/AML, VAT OSS) scopes into a single cryptographic
   root of trust — prohibited by AGENTS.md §0.2 (same reasoning as the
   ADR-004 amendment's VLAN-50 rejection).
3. **DR contradiction (rejected as proposed)**: the proposal destroyed the
   operational identity after Shamir splitting (Gate 6) yet required it for
   the round-trip test (Gate 8). Correct pattern: operational identity
   persists in hardened storage; Shamir shares are DR redundancy only.

## Decision

Amend ADR-003 to admit **SOPS (pinned) + age** as an approved
**git-at-rest** encryption mechanism, under the following binding rules.
Vaultwarden + ESO remains the **sole runtime secret store** — this amendment
adds defence-in-depth for committed files only, and must never be read as
authorising secret VALUES to be committed in plaintext or as a substitute
for ADR-003 runtime flows.

1. **Dual identity (segregation)**: exactly TWO age identities —
   `age-jol` for `/opt/jol/**` repos and `age-jolm` for `/opt/jol-m/**`
   repos. No `.sops.yaml` may list recipients of both trees. Cross-tree
   recipients constitute a segregation incident (AGENTS.md §0.2;
   ISO 27001 A.8.13 lineage).
2. **Source of truth**: each private identity is stored in Vaultwarden
   (encrypted attachment, access-audited) as the authoritative copy. The
   workstation working copy (e.g. `/opt/jol/.sops/age-jol.txt`, `600`,
   dir `700`) is a derived cache and never the sole copy.
3. **DR custody**: each identity is additionally split Shamir **M=2/N=3**
   (tooling: `ssss` or equivalent — SOPS itself has no splitting feature);
   share custody log records locations only, never material. DR rehearsal
   (reconstruct from 2 shares, verify public key, decrypt a fixture) is a
   go/no-go gate before recipient publication and repeats quarterly.
4. **Tooling pins**: `sops` version + published SHA256, and `age` version,
   recorded in `docs/dev-setup/tool-versions.md` (fleet convention) and
   re-verified on every install; binary checksum verification before first
   execution is mandatory.
5. **Rollout**: recipients published via security-reviewed PR per tree
   (`jol-security` for the church tree, `jol-m-compliance` for the
   marketplace tree); `.sops.yaml` creation rules restricted to explicit
   patterns (`*.enc.yaml`, `secrets/**`); encrypt/decrypt round-trip gate
   must pass per tree before fleet enablement.
6. **Prohibitions**: private keys in git, CI logs, or CLI arguments
   (AGENTS.md §0.1); wildcard `safe.directory`; single shared identity;
   SOPS for runtime cluster secrets (ESO owns that surface).

## Conditions (must hold before Gate 4 execution)

- [ ] This amendment APPROVED via security-reviewed PR (CODEOWNERS gate on
      `docs/adr/`) — human approval, evidence linked in Change History
- [ ] CC8.1 GitHub Issue filed with rollback plan (one issue covers Gates 4–8
      as a single change series; each gate links back to it)
- [ ] DPIA trigger re-check recorded in `docs/compliance/dpia-trigger-check.md`:
      SOPS processes encryption keys adjacent to Art. 9 data — trigger score
      already ≥3 YES ⇒ existing pilot DPIA scope covers it; confirm and note
- [ ] Two-identity custody plan (HSM/safe/off-site locations) decided and
      logged BEFORE key generation — custody cannot be retrofitted
- [ ] Reconciled with jol-hub prior SOPS work (`jol-hub/scripts/sops-validate.py`,
      DECISION-LOG) to avoid divergent tooling conventions

## Rollback

Entirely additive until Gate 5. Rollback ladder:
1. Pre-Gate 7: delete working identities + Vaultwarden items; zero git
   impact (no `.sops.yaml` merged yet).
2. Post-Gate 7: revert recipient PRs per tree; encrypted files remain
   decryptable while identities exist — schedule re-encryption or removal.
3. Post-Gate 8: fleet disable = revert `.sops.yaml` creation rules; runtime
   secrets are untouched at every stage (Vaultwarden/ESO unaffected).

## Compliance

- **SOC 2**: CC6.1 (logical access — dual custody, Vaultwarden audit log),
  CC8.1 (change control — conditions above), CC6.6 (boundary: segregation
  enforced cryptographically)
- **GDPR**: Art. 5(1)(f) integrity/confidentiality, Art. 25 (by-design
  segregation of Art. 9 tree), Art. 32 (encryption as a security measure)
- **ISO 27001:2022**: A.8.24 (use of cryptography — documented key
  management), A.8.13 (segregation of environments), A.5.9 (asset inventory
  of key material)
- **PCI-DSS**: Req. 3.6 family (key management documentation and custody) —
  satisfied by per-tree key registers + custody log

## Alternatives Considered

1. **Status quo (Ansible Vault only)** — rejected: covers 2/28 repos'
   workflows; unreadable diffs; no per-file granularity for non-Ansible repos.
2. **Single fleet-wide identity (as proposed)** — rejected: merges two
   PCI-DSS scopes + two DPIAs into one root of trust (AGENTS.md §0.2).
3. **Git-crypt** — rejected: whole-repo binary encryption defeats review;
   weaker audit story than SOPS YAML/JSON-native partial encryption.
4. **Sealed Secrets** — rejected already in ADR-003 (no rotation support);
   additionally Kubernetes-only.
5. **HashiCorp Vault transit for git-at-rest** — rejected: rejected in
   ADR-003 for operational complexity; disproportionate for file-level use.

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-26 | Amendment drafted — PROPOSED, not approved; no gates may execute until Conditions are met | Gate 4–8 prompt review (this conversation); fleet scan: age 1.1.1 present, sops absent, 0 `.sops.yaml` fleet-wide |
