# terraform_runner — self-hosted Terraform / GitHub Actions runner

Hardened, always-on VM that performs `terraform apply` against the Proxmox
provider, replacing laptop-driven applies. Church tree (`journeyoflife-org`)
only — see **Tree segregation** below.

Ratified design: change record
`docs/compliance/evidence/change-record-tf-runner-proxmox-20260925.md`
(JOL-TFRUNNER-20260925-01).

## Why a dedicated runner (not a laptop)

| Concern | Control implemented here |
|---------|--------------------------|
| State location | Remote backend (self-hosted MinIO); local `state/` is cache only |
| Availability | Always-on VM on the management VLAN |
| Secrets exposure | No long-lived secrets baked in; runtime-injected from Vaultwarden |
| Audit / SOC 2 CC8.1 | Applies come from CI (self-hosted Actions runner) + auditd watches |
| Consistency | Pinned, SHA256-verified terraform/sops; `.terraformrc` plugin cache |
| Disaster recovery | VM-as-code (cloud-init + this role); PBS nightly backup |

## Provisioning sequence

1. **Create the VM on prox01** from the Ubuntu 24.04 cloud-init template
   (2 vCPU / 8 GB / 100 GB, VMID 206, 10.60.60.31, VLAN 60), attaching
   `files/cloud-init-userdata.yaml`:
   ```bash
   # on prox01 — base OS bootstrap only
   qm create 206 --name tf-runner-prod-01 --memory 8192 --cores 2 \
     --net0 virtio,bridge=vmbr0 --ostype l26 --agent enabled=1
   # attach the cloud-init template disk + cicustom user=cloud-init-userdata.yaml
   ```
2. **Harden + install the toolchain** from the control host:
   ```bash
   cd ansible/
   ansible-playbook playbooks/provision-terraform-runner.yml
   ```
3. **Inject runtime secrets** from Vaultwarden (never committed — §0.1):
   - `/opt/terraform-runner/secrets/age.key` — SOPS age private key (`0400 root:root`)
   - `/opt/terraform-runner/secrets/runner.secrets.env` (`0400 root:root`) containing:
     - `GH_JIT_TOKEN` — GitHub token to mint JIT runner configs (ephemeral mode)
     - `PM_API_TOKEN` — least-privilege Proxmox API token secret
     - `PGPASSWORD` — Terraform `pg` state-backend password for role `tfstate`
   The systemd unit loads `runner.secrets.env` via an optional `EnvironmentFile=-`,
   so the unit starts (and the wrapper fails loudly) until secrets are present.

## Toolchain pins (SHA256 verified from official release checksums)

| Tool | Version | Source |
|------|---------|--------|
| Terraform | 1.9.8 | releases.hashicorp.com |
| SOPS | 3.13.3 | github.com/getsops/sops |
| actions-runner | 2.337.0 | github.com/actions/runner |
| bpg/proxmox provider | 0.6.3 | pinned in each config's `required_providers` + committed `.terraform.lock.hcl` |

## Runner modes

- **ephemeral** (default, ratified): `run-ephemeral.sh` mints a JIT runner config
  per job via the GitHub API, runs one job, exits; `Restart=always` produces a
  fresh single-use runner. Requires `GH_JIT_TOKEN`.
- **service**: persistent registration via a one-time `actions_runner_registration_token`
  supplied at deploy time (`no_log`). Fallback only.

## Tree segregation (AGENTS.md §0.2) — hard rule

This runner touches the **church tree only** (`actions_runner_org: journeyoflife-org`,
`terraform_runner_tree: church`). The **marketplace tree** (`jolarca-dev`) MUST use a
**separate runner** defined in `jolarca-infrastructure`, with its own Proxmox API
token, state backend, and audit log. Never co-locate both trees on one runner —
that merges two audit surfaces and violates ISO 27001 A.8.13.

## Dependencies (tracked)

- **PostgreSQL state backend** (`pg` backend) on `tfstate-prod-01`
  (VMID 205, 10.60.60.32:5432) must be provisioned by the `terraform_state_db`
  role and reachable before the first apply. Locking is native Postgres advisory
  locks. The AWS S3 backend in `terraform/bootstrap/` is frozen. MinIO was
  **rejected**: no working lock on Terraform 1.9.x (needs ≥1.10 `use_lockfile` +
  conditional writes) and the MinIO OSS repo was archived 2026-04-25.
- **Least-privilege Proxmox token** scoped to the managed VMID pool — never a
  global `Administrator` token.

## Rollback

```bash
# on the runner VM
systemctl disable --now terraform-runner
rm -f /etc/systemd/system/terraform-runner.service
rm -f /etc/audit/rules.d/jol-terraform-runner.rules && augenrules --load
# then destroy VM 206 on prox01 (qm destroy 206 --purge 1) after a PBS snapshot
```
