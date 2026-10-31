# terraform_state_db — dedicated PostgreSQL for the Terraform `pg` state backend

Single-purpose VM (`tfstate-prod-01`, VMID 205, 10.60.60.32, VLAN 60 on
`prox01`) hosting the Terraform state database. Ratified design: change record
`docs/compliance/evidence/change-record-tf-runner-proxmox-20260925.md`
(JOL-TFRUNNER-20260925-01, decision 2).

## Why PostgreSQL (not MinIO)

| Factor | PostgreSQL `pg` backend | MinIO S3 backend (rejected) |
|--------|-------------------------|-----------------------------|
| State locking | Native advisory locks (auto-release on session abort) | Requires TF ≥ 1.10 `use_lockfile` + conditional writes; TF 1.9.8 has no lock |
| Upstream status | Actively maintained | OSS repo archived 2026-04-25 (supply-chain risk) |
| Runner TF version | Works with pinned TF 1.9.8 | Requires bumping TF to ≥ 1.10 |

## Provisioning sequence

1. **Create the VM on prox01** from the Ubuntu 24.04 cloud-init template
   (2 vCPU / 4 GB / 40 GB, VMID 205, 10.60.60.32, VLAN 60), attaching
   `files/cloud-init-userdata.yaml`. Operator must also create a
   **ZFS-native-encrypted dataset** on prox01 for the VM disk (at-rest
   encryption — documented in the change record).
2. **Harden + install PostgreSQL**:
   ```bash
   cd ansible/
   ansible-playbook playbooks/provision-terraform-state-db.yml \
     -e "terraform_state_db_password=<from Vaultwarden>"
   ```
3. **Inject the runner-side secret** — add `PGPASSWORD=<same-password>` to
   `/opt/terraform-runner/secrets/runner.secrets.env` (0400 root:root) on the
   runner VM. The runner's `terraform init` will then reach the state DB.

## Security controls

- **TLS in transit**: self-signed cert at `/etc/ssl/tfstate/`, `sslmode=require`
  on the runner. Full chain verification (`sslmode=verify-full`) is a tracked
  hardening TODO requiring the fleet CA.
- **Network**: UFW default-deny; 5432/tcp allowed from the runner IP
  (10.60.60.31) only.
- **Authentication**: scram-sha-256; `pg_hba.conf` is first-match with a
  reject-all tail.
- **Least privilege**: `tfstate` role owns only the `terraform_state` DB;
  no superuser, no create-db, no create-role.
- **auditd**: watches on `pg_hba.conf`, the conf.d drop-in, TLS key/cert, and
  the backup directory.
- **Backup**: PBS VM backup (RPO 24h) + nightly `pg_dump` (logical, 14-day
  retention) at `/var/backups/tfstate/`.

## Rollback

```bash
# on the state DB VM
systemctl disable --now postgresql
apt purge postgresql-16 postgresql-client-16
# then destroy VM 205 on prox01 (qm destroy 205 --purge 1) after a PBS snapshot
```

The runner role continues to work (no state backend reachable → `terraform init`
fails fast); revert the runner defaults to point at the previous backend if
needed.
