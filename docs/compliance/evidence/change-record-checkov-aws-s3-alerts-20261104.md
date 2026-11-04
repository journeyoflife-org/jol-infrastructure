# Risk Acceptance Record — Eight Open Checkov Alerts on the Frozen AWS S3 Buckets

| Field | Value |
|---|---|
| Register ID | `RA-AWS-S3-20261104-01` |
| Raised | 2026-11-04 |
| Repository | `journeyoflife-org/jol-infrastructure` |
| Scanner | Checkov, uploaded to GitHub code scanning as tool `checkov` (CI version 3.3.19; locally reproduced at 3.3.16) |
| Alerts covered | 8 open: `CKV_AWS_144` ×5, `CKV_AWS_18` ×2, `CKV_AWS_21` ×1 |
| Frameworks touched | SOC 2 CC6.1 / CC6.8, ISO 27001:2022 A.8.24 / A.8.13, GDPR Art. 32(1)(b) |
| **Acceptance status** | **NOT ACCEPTED — awaiting the owner's signature (see the block at the end)** |

## 1. Why this record exists

`policies/checkov/.checkov.yaml` pins `CKV_AWS_18`, `CKV_AWS_19`, `CKV_AWS_21` and `CKV_AWS_144`
in its `check:` list with `soft-fail: false`. The three S3 buckets in `terraform/bootstrap/main.tf`
and `terraform/modules/storage/main.tf` carry `checkov:skip` annotations for logging and
cross-region replication, so the gate is green — but the suppressed findings are still uploaded.

Measured on a clean checkout of `origin/main` at `ae5c7e9`, using the repository's own config:

```
Passed checks: 7, Failed checks: 0, Skipped checks: 8        exit 0
```

and in the SARIF that same run produces:

```
total results: 8
ruleId counts: {'CKV_AWS_18': 2, 'CKV_AWS_144': 5, 'CKV_AWS_21': 1}
entries with suppressions: 8        # kind: "inSource", justification = the annotation text
kind counts: {'<none>': 8}          # SARIF defaults an absent kind to "fail"
```

The 8 SARIF results correspond one-for-one with the 8 open alerts — same rule IDs, same
`terraform/bootstrap/main.tf:77`, `:133` and `terraform/modules/storage/main.tf:27`. **The alerts
are the record of the suppressions, not evidence of missing controls.** All 8 carry
`created_at == updated_at == 2026-09-16T18:08:15Z` and none has ever been closed, despite Checkov
analyses being uploaded against `main` as recently as 2026-10-31.

## 2. What the findings actually are

| Rule | Instances | In-source reason already recorded | Does the control exist in code? |
|---|---|---|---|
| `CKV_AWS_144` S3 cross-region replication | `aws_s3_bucket.terraform_state` dev/staging/prod, `…_logs`, `module.storage.aws_s3_bucket.app_data` | Deferred to the organisational DR strategy; state is protected by versioning, KMS and DynamoDB locking | No replication resource |
| `CKV_AWS_18` S3 server access logging | `aws_s3_bucket.terraform_state_logs`, `module.storage.aws_s3_bucket.app_data` | Log recursion / cost; access tracked via bucket policy and CloudTrail | Logging **is** configured for the 3 state buckets (`aws_s3_bucket_logging` → the logs bucket); only the terminus bucket and `app_data` are unlogged |
| `CKV_AWS_21` S3 versioning | `module.storage.aws_s3_bucket.app_data` | Versioning is a separate `aws_s3_bucket_versioning` resource (AWS provider v4+ form) | **Yes** — `terraform/modules/storage/main.tf:39-46` sets `status = "Enabled"`. Proven load-bearing: deleting the annotation flips the scan to `Failed checks: 1`, because Checkov does not resolve versioning through the `count`-indexed module reference |

## 3. Risk assessment

The material mitigating fact is that **none of these buckets exists, or will exist.**

- `terraform/bootstrap/versions.tf:5-8` and `terraform/modules/versions.tf:6-10`: *"AWS PROVIDER
  FROZEN — JOL runs 100% on-prem (Proxmox). This Terraform code is never applied against AWS."*
- `docs/compliance/evidence/change-record-tf-runner-proxmox-20260925.md:47`: *"The AWS S3 backend
  in `terraform/bootstrap/` is frozen and never applied."* State is on PostgreSQL with native
  advisory locking on `tfstate-prod-01` (VMID 205).
- No `terraform.tfstate` is committed and no `cloud {}` block exists, so no AWS object is under
  management.
- The repository holds one Actions secret (`QODANA_TOKEN`); no `AWS_ROLE_*` exists, and no
  org-level secrets are configured. `prod-apply.yml` preflight fails fast on exactly that.

| | Rating | Reasoning |
|---|---|---|
| Confidentiality / integrity / availability of live data | **None** | No AWS resource exists; there is no data at risk |
| Compliance-evidence accuracy | **Medium** | The alerts assert an unremediated S3 posture. An auditor who does not know the tree is frozen reads them as live control gaps; conversely, *dismissing* them as "not used" without this record would be an unexplained closure of a pinned check |
| Residual risk if the tree is ever applied | **High, and out of scope of this acceptance** | Replication and logging gaps would become real the moment someone runs `terraform apply` with credentials. This record accepts risk **only** for code that is declared never-applied |

## 4. Treatment options for the owner

| Option | Action required | Effect on the alerts | Effect on the gate |
|---|---|---|---|
| **A — de-scope the tree (recommended)** | Accept `docs/adr/ADR-009-descope-frozen-aws-tree.md` and execute its Phase 2 | Expected to close all 8 as the findings leave the scanned surface. No alert in this repository has ever been closed automatically, so this is an expectation of code-scanning behaviour, **not** a measured fact | Policy pack re-scoped to the live on-prem surfaces |
| **B — dismiss with this record** | `PATCH` each of the 8 alerts with `dismissed_reason: "won't fix"` and a link back to `RA-AWS-S3-20261104-01` | Closed, with an auditable justification and a named acceptor | Unchanged; the annotations keep it green |
| **C — do nothing** | None | Stay open and continue to be re-uploaded on every push to `main` that touches a filtered path | Unchanged |

Option B is the only one that leaves the dead code in place *and* the alerts closed, and it is
the option this record was written to support. Option A makes this record unnecessary.

## 5. Acceptance

**No risk has been accepted by the existence of this document.** Dismissing a security finding is
an acceptance of risk, and in this organisation only the owner can accept it; an agent recording
acceptance would be fabricating audit evidence. The block below is deliberately unsigned.

```
Risk accepted by : <OWNER — Gintaras Kazlauskas>
Date             : <pending>
Option chosen    : <A | B | C>
Justification    : <owner's own words; do not copy from §3>
Review by        : <date, or "when terraform/ is deleted">
```

Until that block is completed, the correct statement of the organisation's posture is:
*"8 Checkov best-practice findings are open on never-applied AWS Terraform code; the gate is green
because the findings are suppressed in source; disposition is an outstanding owner decision."*

## 6. Reproducing the measurement

```bash
git archive origin/main | tar -x -C /tmp/verify          # scan a clean checkout, not a dirty tree
cd /tmp/verify
checkov -d terraform/ --framework terraform \
        --config-file policies/checkov/.checkov.yaml \
        --download-external-modules false \
        -c CKV_AWS_21,CKV_AWS_18,CKV_AWS_144 \
        --output sarif --output-file-path /tmp/sarif-out
```

Expect `Failed checks: 0, Skipped checks: 8` and 8 SARIF results, all carrying `suppressions`.
Note that `--output-file-path` is treated as a **directory**; the file inside it is
`results_sarif.sarif`.
