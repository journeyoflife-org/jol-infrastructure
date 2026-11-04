# ADR-009: De-scope the Frozen AWS Terraform Tree

## Status

**Proposed — owner decision required.** Nothing in this repository has been deleted on the
strength of this record. Phase 1 (below) is implemented by the pull request that carries this
ADR; Phase 2 is not.

Proposes to supersede, in part, the AWS-specific decisions still marked **Accepted** in
`docs/adr/README.md`: ADR-001 (state backend S3 + DynamoDB), ADR-002 (Kubernetes distribution
EKS), ADR-004 (3-tier VPC segmentation) and ADR-006 (CloudWatch metrics). Those four rows were
never re-statused when the platform pivoted to Proxmox, so the register currently advertises
architecture the organisation has abandoned. Correcting the register is part of Phase 2 and is
also owner-gated, because flipping an ADR to `Superseded` is a change to an accepted decision.

## Context

`terraform/` is 51 files and 2,612 lines. Measured on `origin/main` at `ae5c7e9` (2026-11-04):

| Fact | Measurement |
|---|---|
| Providers declared | `hashicorp/aws` in **every** `versions.tf`; `tls` alongside it. No `proxmox`, `google`, `azurerm` or `hetzner` provider anywhere under `terraform/` |
| Resource types | 39 declarations, all `aws_*`: EKS cluster + node group, VPC/subnets/NAT/IGW/route tables/network ACLs/flow logs, IAM roles/policies/OIDC provider, S3 (3 buckets + 12 companion resources), KMS (3 keys + 3 aliases), DynamoDB, CloudWatch (2 log groups, 2 alarms, 1 dashboard), SNS, EBS |
| Freeze statement | `terraform/bootstrap/versions.tf:5-8` and `terraform/modules/versions.tf:6-10`: *"AWS PROVIDER FROZEN — JOL runs 100% on-prem (Proxmox). This Terraform code is never applied against AWS. The provider constraint is kept for structural completeness only."* |
| Ratified elsewhere | `docs/compliance/evidence/change-record-tf-runner-proxmox-20260925.md:47`: *"The AWS S3 backend in `terraform/bootstrap/` is frozen and never applied."* State now lives on PostgreSQL (`pg` backend) on `tfstate-prod-01` (VMID 205) per decision R1 in the same record |
| Canonical IaC home | `jol-repo-template/docs/superpowers/specs/2026-09-25-jol-iac-library-design.md` and the companion plan record ADR-004 of that effort: *"jol-iac is canonical IaC home; `jol-infrastructure/terraform` + `helm` are legacy; **non-destructive** (no migration/deletion here; separate change-controlled effort)"* — this ADR is that separate effort |
| AWS credentials | The repository has exactly one Actions secret, `QODANA_TOKEN`. No `AWS_ROLE_DEV` / `AWS_ROLE_STAGING` / `AWS_ROLE_PROD` exist, and no org-level secrets are configured. `.github/workflows/prod-apply.yml` preflight fails fast on that condition by design |
| State | No `terraform.tfstate` is committed and no `cloud {}` block exists. `terraform/environments/*/backend.tf` name S3 buckets (`jol-terraform-state-dev`, `…-staging`, `…-prod`) that were never created, so `terraform init` against a real backend cannot succeed today |
| Apply history | `prod-apply.yml` has produced 4 runs in total (2026-09-20) — **all failures**, none past preflight |
| Cost still being paid | `terraform-plan.yml` runs on every Dependabot PR that touches `terraform/**`: runs 73/74/75 (2026-10-31, the `hashicorp/aws` 6.70.0 bumps) are **failure**, while runs 70/71/72 (the `tls` 4.4.2 bumps) are success. Three open PRs (#121, #122, #123) can therefore never go green |
| Compliance noise | Checkov on clean `main` reports `Passed 23, Failed 0, Skipped 8`, exit 0. The 8 skips are uploaded to GitHub as SARIF `results` carrying `suppressions:[{kind:"inSource"}]` with **no `kind` field**, which SARIF defaults to `fail` — so the 8 findings persist as open code-scanning alerts even though the gate is green. Zero of the 8 have ever been closed |

The live platform is not affected by any of this: Proxmox VMs are provisioned by Ansible
(`ansible/`, `inventory/`), the LLM estate by `llm/`, and the on-prem Kubernetes by `kubernetes/`
and `helm/`, neither of which references AWS (grep for `eks|aws` over those trees returns nothing).

## Decision (proposed)

Retire the AWS tree in two phases, ordered so that the part with **provably nil blast radius**
happens first and the part with a real dependency graph is taken only on an explicit owner yes.

### Phase 1 — detach live automation from the frozen tree (implemented by this PR)

Touches no `.tf` file, so every scanner, policy pack and Makefile target keeps working unchanged.

1. `.github/dependabot.yml`: drop the four `package-ecosystem: "terraform"` entries pointing at
   `/terraform/bootstrap` and `/terraform/environments/{dev,staging,prod}`. Dependabot is being
   asked to maintain a dependency graph for code that is declared never-applied, and the result is
   provably-red pull requests.
2. Delete `scripts/bootstrap/02-bootstrap-state.sh` and `scripts/bootstrap/03-bootstrap-cluster.sh`.
   These are the only two places where the AWS tree is *executable*: both `cd` into it and run
   `terraform apply`, and unlike `prod-apply.yml` they have no credential fail-fast — an operator
   following the README is invited to type `yes` at an interactive prompt against an AWS account the
   organisation does not run. Nothing else calls them: the only references in the repository are
   `README.md` and each script's own "next step" echo.
3. `README.md` Quick Start: remove steps 3, 4 and 5, which invoke the deleted scripts and
   `make plan-dev`, and point at the on-prem path instead.

Reversible by `git revert`; no state, resource or credential is involved.

### Phase 2 — delete the tree (owner-gated, NOT implemented here)

`git rm -r terraform/` is **not** a small diff, because 16 surfaces treat that directory as live.
They must move in the same change or CI turns red on the next push:

| # | Surface | What must change |
|---|---|---|
| 1 | `terraform/` | 51 files, 2,612 lines deleted |
| 2 | `.github/workflows/infra-validate.yml` | `paths: - "terraform/**"` trigger; `checkov-scan` `directory: terraform/`; `trivy-scan` `scan-ref: 'terraform/'` — both jobs error on a missing directory |
| 3 | `.github/workflows/terraform-plan.yml` | whole workflow is AWS-only (`paths: terraform/**`, matrix over the three environments, `working-directory: terraform/environments/…`) |
| 4 | `.github/workflows/prod-apply.yml` | `terraform-apply` job and the `terraform` / `all` `component` choices; also decide the fate of `kubernetes-apply`, which assumes an EKS OIDC role |
| 5 | `.github/dependabot.yml` | already done in Phase 1 |
| 6 | `.pre-commit-config.yaml` | `terraform_fmt`, `terraform_validate`, `terraform_checkov`, `terraform_tfsec` hooks |
| 7 | `Makefile` | `fmt`, `lint-terraform`, `checkov`, `trivy`, `plan-dev`, `plan-staging`, `plan-prod` |
| 8 | `policies/checkov/.checkov.yaml` | 10 of the 13 pinned checks are `CKV_AWS_*`; with no AWS resources the pack is inert and the `check:` list must be re-scoped, not silently emptied |
| 9 | `policies/checkov/README.md`, `policies/tfsec/README.md`, `.tfsec/ignored-checks.yml` | AWS-specific guidance and ignores |
| 10 | `scripts/utils/generate-terraform-docs.sh`, `scripts/utils/tf-cost-estimate.sh` | operate on `terraform/` |
| 11 | `scripts/maintenance/terraform-state-rename-jolarca.sh` | references `terraform/environments/` |
| 12 | `docs/adr/ADR-001`, `ADR-002`, `ADR-004`, `ADR-006` + `docs/adr/README.md` | re-status to Superseded (owner act) |
| 13 | `docs/runbooks/create-vm205-tfstate-prod-01.md`, `docs/runbooks/disaster-recovery.md` | cite the AWS backend |
| 14 | `docs/dev-setup/tool-versions.md`, `docs/dev-setup/qoder-setup.md`, `CONTRIBUTING.md`, `QODER.md`, `AGENTS.md` | document Terraform/AWS as the workflow |
| 15 | `README.md` architecture diagram (Dev/Staging/Prod VPC + EKS) and the "Controls Implemented" table | the diagram depicts an AWS topology that does not exist; the SOC 2 CC6.1 / ISO A.8.7 / GDPR Art. 32 rows are currently evidenced by AWS resources that are never applied |
| 16 | `ansible/roles/terraform_runner/*` | comments only; the runner itself is live and Proxmox-facing, so it stays |

Phase 2 acceptance criteria before any merge:

- [ ] Owner has accepted the descope in writing on this ADR (Status → Accepted).
- [ ] `make lint` and `make validate` green with `terraform/` absent.
- [ ] `checkov` and `trivy` re-scoped and still exit 0 on the remaining surfaces (`kubernetes/`, `helm/`).
- [ ] A push to `main` after the deletion produces a Checkov SARIF analysis with **0 results**, and the
      8 open alerts are observed to close. No alert in this repository has ever been closed
      automatically, so this is an expectation of code-scanning behaviour, not a measured fact here.
- [ ] `docs/compliance` and the README control table no longer claim AWS resources as implemented controls.

## Consequences

**Positive.** The repository stops generating pull requests that cannot pass, stops scanning
never-applied code as though it were the production topology, and stops presenting four
superseded AWS decisions as current architecture. The 8 open alerts have a real route to closure.

**Negative / accepted.** The AWS design record leaves the working tree. It is not lost — Phase 2
should note the last commit that carried it (`ae5c7e9` and earlier) so the blueprint stays
recoverable — but a reader of `main` will no longer find the EKS/VPC design there. If the
organisation ever does deploy to AWS, the tree is resurrected from history rather than edited
in place, which is the correct posture for a design that was deliberately abandoned.

**Risk if Phase 2 is declined.** Then the only honest route to closing the 8 alerts is the
risk-acceptance record at
`docs/compliance/evidence/change-record-checkov-aws-s3-alerts-20261104.md`, and the failing
Dependabot churn stops at Phase 1 rather than at the root cause.

## Alternatives considered

1. **Leave everything as it is.** Rejected: it keeps three permanently-red pull requests open,
   keeps a README Quick Start that instructs an operator to run `terraform apply` against a
   non-existent AWS account, and leaves four ADRs misrepresenting the architecture.
2. **One bulk PR deleting `terraform/` plus all 16 surfaces.** Rejected on change-control grounds:
   a ~2,600-line deletion entangled with CI, policy packs and compliance documentation is not
   reviewable in one pass, and `jol-control`'s own discipline treats a diff of that size as unsafe.
3. **Move `terraform/` to an `archive/` directory excluded from scanning.** Rejected: it preserves
   the dead code while hiding it from the gate, which reads to an auditor as relocation of the
   finding rather than disposition of it.
4. **Add more `checkov:skip` annotations, or move the checks to `skip-check:`.** Rejected: the
   annotations already exist and already make the gate green; measured above, they cannot close the
   alerts, and emptying the `check:` list would weaken the policy pack for the live on-prem code.
