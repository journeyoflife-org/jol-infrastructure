# ADR-005: GitOps Workflow

## Status
Accepted

## Context
Infrastructure changes must be auditable, reviewable, and rollbackable.
Manual changes (clickops) are incompatible with SOC 2 change management controls.

## Decision
Adopt a GitOps workflow:
1. All infrastructure changes via Pull Request
2. Automated validation (checkov, tfsec, OPA) on PR
3. Terraform plan posted as PR comment for review
4. Production applies via manual `workflow_dispatch` with approval
5. CHANGELOG.md updated for all production changes

## Consequences
- **Positive**: Full audit trail in git history (SOC 2 CC8.1)
- **Positive**: Peer review required for all changes
- **Positive**: Automated policy enforcement prevents insecure configs
- **Negative**: Slower iteration for urgent fixes (mitigated by emergency process)

## Alternatives Considered
1. ArgoCD for continuous reconciliation — deferred (evaluate at scale)
2. Atlantis — rejected (preferring GitHub Actions native)
3. Manual apply — rejected (no audit trail)

## Compliance
- SOC 2 CC8.1: Change management — all changes tracked and reviewed
- ISO 27001 A.12.1.2: Change management procedures
