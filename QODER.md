# QODER.md

Behavioral guidelines to reduce common LLM coding mistakes when using Qoder in PyCharm. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.
- Prefer PyCharm's built-in refactoring tools (Rename, Extract Method, Move, etc.) over manual text manipulation when the IDE can do it safely.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:

```text
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

---

## Project-Specific Guidelines — jol-infrastructure

This repository changes production infrastructure; every merge is a
change-management record (SOC 2 CC8.1, ISO 27001 A.8.32). The full rules live
in `CONTRIBUTING.md`; these constrain AI-assisted changes:

### Workflow: plan-first

1. **Issue first.** Infrastructure changes require a change request filed via
   `.github/ISSUE_TEMPLATE/infra-change-request.yml`, stating risk level
   (Low/Medium/High/Critical), blast radius, rollback plan, and a ticket
   reference (`JOL-XXXX`) for the audit trail. Changes without these are closed.
2. **Plan before apply.** Terraform changes ship with `terraform plan` output
   (`make plan-dev` / `plan-staging` / `plan-prod`) attached to the PR. Never
   generate or suggest `terraform apply`; production applies run only through
   the manual `Production Apply` workflow with approval.
3. **Small, reviewable diffs.** One concern per PR; squash merge.
4. **CI is a merge gate.** The `Infrastructure Validation` workflow
   (TruffleHog, Checkov, Trivy, OPA policy tests) must be green; branch
   protection enforces this, and CODEOWNERS review is required.

### Change-risk classes

Per `infra-change-request.yml`:

| Class    | Examples                                                          | Gate                                         |
|----------|-------------------------------------------------------------------|----------------------------------------------|
| Low      | Dev-only, docs, comments; no data impact                          | 1 review (CODEOWNERS)                        |
| Medium   | Staging or non-critical production change                         | 1 review + plan attached                     |
| High     | Production data plane, networking, or IAM change                  | devops + security CODEOWNERS + rollback plan |
| Critical | Cross-environment, state migration, or destructive operation      | devops + security CODEOWNERS + change window |

State the risk class for every infrastructure change.

### The two-person rule

Security-sensitive paths (per `.github/CODEOWNERS`, non-exhaustive):
`terraform/bootstrap/`, `terraform/environments/prod/`, `policies/`,
`kubernetes/policies/`, `kubernetes/rbac/`, `.github/workflows/`, `scripts/`,
`llm/infra/`, `llm/config/`, `llm/deploy/`, `llm/scripts/security/`.

- Changes here require review beyond the author; the author never self-approves.
  CODEOWNERS routes these to the `security` team in addition to `devops`.
- Flag the risk class explicitly; never bundle these edits with unrelated changes.
- Solo-era operation: enforcement rides on the automated gates (required CI
  checks, plan-first workflow, CODEOWNERS, branch protection) — a tracked
  deviation, not an exemption.

### Secrets — never in git

- No tokens, keys, PEMs, vault password files, or `.tfstate` — enforced by
  `.gitignore`, pre-commit (TruffleHog verified-secrets scan +
  `detect-private-key`), and the CI TruffleHog job.
- Never print or echo state file contents — state contains secrets.
- Never suggest bypassing pre-commit (`--no-verify`); run `make validate`
  (fmt + lint + opa-test + helm-lint + checkov + trivy) before commit.
- Runtime credentials come from the operator environment or Vaultwarden;
  Ansible secrets are `ansible-vault` encrypted with per-environment
  passwords under dual control — never plaintext, never in `*.tfvars`.

### Policy gates

- Terraform and Kubernetes changes must pass the OPA policies
  (`enforce-no-secrets-in-terraform`, `enforce-no-cluster-admin`,
  `enforce-pod-security`, `enforce-resource-limits` — `make opa-test`),
  tflint, Checkov (`policies/checkov/.checkov.yaml`), and Trivy before being
  proposed as complete.

### Rollback

Every PR must state how to revert it (mandatory field in the PR template).
For Terraform: the inverse plan or restored state version. If you cannot
describe the rollback, the change is not ready.
