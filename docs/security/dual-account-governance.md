# Dual-Account Four-Eyes Governance — Compensating Control Record

> **Status**: RATIFIED 2026-08-27 (owner directive) — compensating control;
> residual risk accepted (see §6). Companion CODEOWNERS additions merged in
> the same PR. Classification: governance; no credentials or personal data.

## 1. Purpose

JOL is a single-owner organization: segregation of duties between author and
reviewer is impossible with one identity, which forced owner-admin bypasses
of `REVIEW_REQUIRED` branch protection (precedent: SOPS fleet rollout, issue
#36, 2026-08-27). This record establishes a second, separately-authenticated
GitHub account (`IterVitae`, phone-bound 2FA) as the reviewer identity so
that merges can flow through the normal protected path.

## 2. Control design

| Property | Rule |
|---|---|
| Accounts | `JourneyOfLife` = author/automation (this workstation, `gh` CLI); `IterVitae` = reviewer (phone/web session only) |
| Least privilege | IterVitae: org member, READ base permission, no write/admin by default |
| Channel separation | IterVitae approvals are human-only on the separate device. Its credentials MUST NOT be added to any workstation, `gh` config, CI secret, or Vaultwarden item used by automation |
| Mandatory second signature | CODEOWNERS lists `@IterVitae` on security-sensitive paths (see `.github/CODEOWNERS`); review-required rulesets apply fleet-wide |
| Credential hygiene | No shared passwords between accounts; independent 2FA factors; independent recovery |

## 3. Honest classification

Two accounts operated by one person are **formal four-eyes, not substantive
segregation of duties** (a SOC 2 auditor counts people, not accounts). The
control's value: a distinct auth factor and device, a deliberate human review
act per merge, and a distinct actor in GitHub's audit trail. It supersedes
owner-admin bypass as the default merge path; bypass remains an exception
requiring explicit recorded justification.

## 4. Activation checklist

- [ ] IterVitae org invitation issued (member, read base) and accepted
- [ ] Phone-bound 2FA confirmed on IterVitae (no SMS-only fallback where avoidable)
- [ ] CODEOWNERS entries effective (GitHub ignores reviewers without repo access until the invitation is accepted — enforcement begins automatically at acceptance)
- [ ] First dual-signature merge recorded below as activation evidence

## 5. Operation

1. Author opens PR from the workstation as JourneyOfLife.
2. Reviewer reads the diff on the phone/web as IterVitae; approves or
   requests changes (never rubber-stamps: the review act IS the control).
3. Merge proceeds through normal branch protection. Admin bypass is an
   exception, logged with justification in the PR.
4. Emergency (account lockout): documented owner-admin merge + retroactive
   review note; recorded in Change History.

## 6. Residual risk acceptance

Single-operator dual-account review cannot detect author-side compromise of
both accounts, coercion, or rubber-stamping. Accepted by the owner on the
strength of compensating layers: phone-bound 2FA, credential separation,
immutable CHANGELOG/audit trails, the jol-qoder-history preservation repos,
and periodic Qodana/secret-scan gates. Review at each quarterly tooling
window or upon onboarding any second human.

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-27 | Control ratified; CODEOWNERS second-signature paths added; activation pending org invitation | owner directive 2026-08-27; companion PR |
