# Change Record — Self-hosted Terraform Runner VM (church tree)

| Field | Value |
|-------|-------|
| **Change ID** | JOL-TFRUNNER-20260925-01 |
| **Date** | 2026-09-25 |
| **Author** | @JourneyOfLife |
| **Environment** | prod (infrastructure-as-code; no live mutation applied yet) |
| **Classification** | New capability — CI/CD runner |
| **Compliance** | SOC 2 CC6.1 / CC7.2 / CC8.1 · GDPR Art. 5(1)(f), Art. 32 · ISO 27001 A.8.13, A.8.32 |
| **Status** | DRAFT — artifacts committed; VM creation + secret injection are operator-gated |

## 1. Summary

Introduce a dedicated, always-on Proxmox VM (`tf-runner-prod-01`, VMID 206,
10.60.60.31, VLAN 60, on `prox01`) that runs `terraform apply` against the
Proxmox provider as a **self-hosted GitHub Actions runner**, replacing
laptop-driven applies. Provisioned via cloud-init (base OS) + the new
`terraform_runner` Ansible role (hardening + pinned toolchain + runner).

## 2. Driver — six concerns (operator-raised, architect-validated)

| Concern | Laptop (before) | Dedicated runner VM (after) | Verdict |
|---------|-----------------|-----------------------------|---------|
| State file location | On laptop (theft/loss) | Remote backend (PostgreSQL `pg` backend), backed up, auditable | Real gap closed |
| Availability | Blocked when laptop off | Always-on runner | Closed |
| Secrets exposure | SOPS + cloud creds on daily-use machine | Isolated VM, runtime-injected secrets, auditd-watched | Closed with controls |
| Audit / SOC 2 evidence | Hard to prove who/what/when | Applies come from CI; native Actions audit trail + auditd | Closed |
| Consistency | Drifting tool versions | Pinned + SHA256-verified terraform/sops; plugin cache | Closed |
| Disaster recovery | Rebuild = pain | VM-as-code (cloud-init + role) + PBS snapshot | Closed |

**Architectural refinement**: cloud GitHub Actions runners cannot reach the
Proxmox API (private VLAN 60, deliberately not internet-exposed). "All applies
come from CI" and "Proxmox API stays private" reconcile **only** via a
self-hosted runner on the management VLAN — which is this VM.

## 3. Ratified decisions (operator confirmed 1–5)

1. **Per-tree runners** — one runner per Tier-1 tree. This change delivers the
   **church** runner (`journeyoflife-org`). The **marketplace** runner
   (`jolarca-dev`) is out of scope for this repo and belongs in
   `jolarca-infrastructure` (§0.2 segregation). Via-Vitae folds into whichever
   tree its compliance scope is ratified under.
2. **Remote state backend** — dedicated PostgreSQL on `tfstate-prod-01`
   (VMID 205, 10.60.60.32, VLAN 60) using the Terraform `pg` backend with
   **native advisory-lock state locking**. The AWS S3 backend in
   `terraform/bootstrap/` is frozen and never applied. **MinIO was rejected**
   after verification: (a) Terraform 1.9.8 S3 backend has no working lock
   without DynamoDB (which we don't self-host); (b) TF ≥1.10 `use_lockfile`
   requires S3 conditional writes, which MinIO supports only from
   `RELEASE.2024-09-13` onward; (c) MinIO OSS was archived read-only on
   2026-04-25 — a material supply-chain/governance risk for new crown-jewel
   infrastructure. Postgres `pg` backend gives native advisory-lock locking
   with no conditional-write dependency, works with the pinned TF 1.9.8, and
   is actively maintained.
3. **VMID / IP / bridge** — VMID 206 / 10.60.60.31 for the runner, VMID 205 /
   10.60.60.32 for the state DB, both on VLAN 60 on `prox01` (next free after
   the pilot range 200–204; `.30` is reserved for `jol-observ-pilot-lt01` per
   `docs/architecture/jol-pilot-vm-topology.md`).
4. **Sizing** — 2 vCPU / 8 GB / 100 GB (corrected up from the requested
   4 GB / 20 GB — insufficient for three repos + providers + state cache).
5. **Runner driver** — self-hosted GitHub Actions, **ephemeral** (JIT, one job
   per process).

## 4. Artifacts added (this change)

| Path | Purpose |
|------|---------|
| `ansible/roles/terraform_runner/` | New role: defaults, tasks (00–60), handlers, templates, files, README |
| `ansible/roles/terraform_runner/files/cloud-init-userdata.yaml` | Base OS bootstrap for the runner VM |
| `ansible/roles/terraform_state_db/` | New role: Postgres install, TLS (community.crypto), DB+role, pg_hba, UFW, pg_dump backup, auditd |
| `ansible/roles/terraform_state_db/files/cloud-init-userdata.yaml` | Base OS bootstrap for the state DB VM |
| `scripts/provisioning/prox01-create-vm205-tfstate.sh` | Operator runbook: creates VM 205 on prox01 with ZFS encryption + cloud-init |
| `ansible/playbooks/provision-terraform-runner.yml` | Runner hardening + install playbook |
| `ansible/playbooks/provision-terraform-state-db.yml` | State DB hardening + install playbook |
| `inventory/prod/host_vars/tf-runner-prod-01.yml` | Runner host variables (no secrets) |
| `inventory/prod/host_vars/tfstate-prod-01.yml` | State DB host variables (no secrets) |
| `inventory/prod/hosts.yml` | New `tf_runner` + `tf_state_db` groups + host entries (edit) |
| `CHANGELOG.md` | CC8.1 change-log row (edit) |

## 5. Security & compliance controls

- **Least privilege**: unprivileged `terraform` service user (no sudo, password
  locked); Proxmox API token scoped to the managed VMID pool (never `Administrator`).
- **Supply chain**: terraform 1.9.8, SOPS 3.13.3, actions-runner 2.337.0 —
  all SHA256-verified against official release checksums; post-install version
  drift guards.
- **No secrets in git** (§0.1): SOPS age key, Proxmox token secret, MinIO
  credentials, and the GitHub JIT token are runtime-injected into
  `/opt/terraform-runner/secrets/` (`0400 root:root`) from Vaultwarden. The
  systemd unit loads them via an optional `EnvironmentFile=-`.
- **systemd hardening**: `ProtectSystem=strict`, `NoNewPrivileges`, `PrivateTmp`,
  `ProtectKernel*`, `ProtectControlGroups`, `RestrictSUIDSGID`, `LockPersonality`,
  `SystemCallArchitectures=native`, `UMask=0027` (mirrors AGENTS.md §2.3 baseline).
- **Network**: UFW default-deny incoming; SSH + node-exporter from VLAN 60 only;
  egress to GitHub + Proxmox API.
- **Auditability**: auditd watches on secrets, state cache, runner.env, the
  systemd unit, and terraform/sops exec.
- **Ephemeral isolation**: one job per process reduces lateral-movement blast radius.

## 6. Residual risks / tracked follow-ups

| ID | Risk | Mitigation / owner |
|----|------|--------------------|
| R1 | ~~MinIO state backend not yet provisioned~~ | **CLOSED** — replaced by PostgreSQL `pg` backend on `tfstate-prod-01` (VMID 205, 10.60.60.32), provisioned by the `terraform_state_db` role |
| R2 | `GH_JIT_TOKEN` is a long-lived org credential used to mint JIT configs | Store in Vaultwarden; scope to runner management; rotate per `docs/runbooks/secret-rotation.md` |
| R3 | Self-hosted runner job isolation is process-level, not container-level | Consider container-based jobs; ephemeral mode already limits persistence |
| R4 | Marketplace runner duplication drift | Keep role parameterized; mirror into `jolarca-infrastructure` under its own tree |
| R5 | Proxmox provider version pin (0.6.3) must match each config's lock file | Commit `.terraform.lock.hcl`; verify on first `terraform init` |
| R6 | TLS `sslmode=require` encrypts but does not authenticate the server (MITM risk on the VLAN) | Tracked hardening TODO: upgrade to `sslmode=verify-full` once the fleet CA is provisioned |
| R7 | `tfstate` role password is a long-lived credential | Rotate per `docs/runbooks/secret-rotation.md`; stored in Vaultwarden, injected at deploy |

## 7. Verification gates (operator, before declaring operational)

```text
□ VM 205 created on prox01; cloud-init base applied (hostname, TZ, jol-admin)
□ ZFS-native-encrypted dataset created on prox01 for VM 205 disk (at-rest encryption)
□ ansible-playbook playbooks/provision-terraform-state-db.yml -e "terraform_state_db_password=<from Vaultwarden>" → all roles green
□ PostgreSQL 16 running; TLS cert present at /etc/ssl/tfstate/{server.crt,server.key}
□ psql -h 10.60.60.32 -U tfstate -d terraform_state -W → login succeeds; superuser not granted
□ pg_hba.conf: local peer for postgres only; hostssl from 10.60.60.31/32 only; reject-all tail
□ ufw status verbose → default deny incoming; 22/9100 from 10.60.60.0/24; 5432 from 10.60.60.31 only
□ auditctl -l | grep jol_secrets → watches on pg_hba.conf, conf.d/jol-tfstate.conf, TLS key/cert active
□ PBS nightly job on prox01 covers VM 205; qemu-guest-agent responsive
□ AIDE baseline rebuilt after install (investigate diffs first)
□ tfstate-backup.sh manual run → /var/backups/tfstate/terraform_state-*.dump present, 0600 postgres:postgres
---
□ VM 206 created on prox01; cloud-init base applied (hostname, TZ, jol-admin)
□ ansible-playbook playbooks/provision-terraform-runner.yml → all roles green
□ terraform version == 1.9.8 ; sops version == 3.13.3 (drift guards passed)
□ systemctl is-active terraform-runner ; runner visible in GitHub org settings
□ secrets injected: age.key + runner.secrets.env (with PGPASSWORD) present, 0400 root:root
□ auditctl -l | grep jol_secrets → watches active on the runner
□ ufw status verbose on runner → default deny incoming; 22/9100 from 10.60.60.0/24 only
□ terraform init from the runner against the pg backend succeeds (PGPASSWORD set)
□ PBS nightly job on prox01 covers VM 206; qemu-guest-agent responsive
□ AIDE baseline rebuilt after install (investigate diffs first)
```

## 7a. Static verification evidence (authoring-time, reproducible)

Executed 2026-09-25 with the project Ansible venv (`/opt/jol/ansible/env.sh`,
ansible-core 2.21.4) against the repo config. No live mutation.

| Gate | Command | Result |
|------|---------|--------|
| Playbook syntax | `ansible-playbook --syntax-check playbooks/provision-terraform-runner.yml` | **rc=0 PASS** |
| Collections present | `ansible-galaxy collection list` | community.general 13.4.0, community.crypto 3.4.0 |
| YAML lint | `yamllint -c .yamllint.yaml <all new/edited YAML>` | **rc=0** (one accepted cloud-init `#cloud-config` marker warning; non-strict hook passes) |
| YAML parse | `python3 yaml.safe_load` × 14 files | all OK |
| Template render (real Ansible) | `ansible localhost -m template` × 5 templates with merged defaults+host_vars | **0 residual `{{ }}` tokens** — recursive var resolution confirmed |
| Wrapper shell lint | `shellcheck -s bash run-ephemeral.sh` (Ansible-rendered) | **PASS** |
| systemd unit | `systemd-analyze verify terraform-runner.service` | structure valid; only note is the ExecStart binary absent on the authoring host (deployed `0750` at runtime — expected) |
| IDE problems | GetProblems on inventory/playbook/tasks/defaults | No errors |
| Checksums | terraform 1.9.8 / SOPS 3.13.3 / actions-runner 2.337.0 | verified against official release checksum files |

**Still UNVERIFIED (require the live VM / operator):** actual VM creation, runner
registration with GitHub, `terraform init` against the MinIO backend, PBS backup
coverage, AIDE baseline. These are the §7 operator gates.

## 8. Rollback

1. On the runner VM:
   ```bash
   systemctl disable --now terraform-runner
   rm -f /etc/systemd/system/terraform-runner.service
   rm -f /etc/audit/rules.d/jol-terraform-runner.rules && augenrules --load
   ```
2. Remove the `tf_runner` inventory group + host_vars + role (git revert of the
   commit implementing this change).
3. On `prox01`, after a PBS snapshot: `qm destroy 206 --purge 1`.
4. Revoke the Proxmox API token and the GitHub JIT token in Vaultwarden.

No existing production service depends on this VM; rollback is non-disruptive.
