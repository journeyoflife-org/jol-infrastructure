# Operator Guide: Create VM 205 (tfstate-prod-01) on prox01

## Overview

This guide creates the Terraform state database VM (`tfstate-prod-01`) on the prox01 hypervisor. The VM hosts a dedicated PostgreSQL instance for the Terraform `pg` backend with native advisory-lock state locking.

**Change Record**: JOL-TFRUNNER-20260925-01 (R1 resolution)

## Prerequisites

1. **SSH/console access to prox01** (10.60.60.10) as root
   - Note: Fleet SSH keys are not authorized on prox01 (provisioning gap from 2026-08-29)
   - Use direct console access or SSH with root credentials

2. **jol-admin SSH public key**
   - Extract from an existing host: `cat /home/jol-admin/.ssh/authorized_keys > /tmp/jol-admin.pub`
   - Or provide the key manually

3. **Cloud-init userdata file**
   - Located in repo: `ansible/roles/terraform_state_db/files/cloud-init-userdata.yaml`
   - Copy to prox01: `/var/lib/vz/snippets/tfstate-prod-01-userdata.yaml`

4. **ZFS storage configured** on prox01
   - Default: `local-zfs` (boot mirror rpool)
   - Or custom ZFS storage (adjust `STORAGE` variable in script)

## Execution Steps

### Step 1: Copy files to prox01

```bash
# From your workstation (with SSH access to prox01)
scp ansible/roles/terraform_state_db/files/cloud-init-userdata.yaml \
    root@10.60.60.10:/var/lib/vz/snippets/tfstate-prod-01-userdata.yaml

scp scripts/provisioning/prox01-create-vm205-tfstate.sh \
    root@10.60.60.10:/tmp/

# Extract jol-admin SSH key from an existing host (e.g., rag-prod-lt01)
ssh -o ProxyJump=root@10.60.60.20 jol-admin@10.40.40.10 \
    'cat ~/.ssh/authorized_keys' > /tmp/jol-admin.pub
scp /tmp/jol-admin.pub root@10.60.60.10:/tmp/
```

### Step 2: SSH to prox01 and run the script

```bash
ssh root@10.60.60.10
chmod +x /tmp/prox01-create-vm205-tfstate.sh
/tmp/prox01-create-vm205-tfstate.sh
```

The script will:
1. Run preflight checks (VM doesn't exist, files present, storage available)
2. Generate a ZFS encryption key at `/etc/pve/priv/zfs/vm-205.key`
3. Create VM 205 with encrypted disk, cloud-init, and SSH key injection
4. Start the VM and wait ~60s for cloud-init
5. Verify VM is running and reachable

### Step 3: Verify the VM

```bash
# On prox01
qm status 205                    # Should show: status: running
qm agent 205 ping                # Should succeed after cloud-init completes
ping -c 3 10.60.60.32            # Should be reachable

# From your workstation
ssh jol-admin@10.60.60.32        # Should succeed with jol-admin key
hostname                          # Should show: tfstate-prod-01
```

### Step 4: Install PostgreSQL via Ansible

From your workstation:

```bash
cd /opt/jol/repos/jol-infrastructure/ansible
ansible-playbook playbooks/provision-terraform-state-db.yml \
  -e "terraform_state_db_password=<from Vaultwarden>"
```

The playbook will:
- Install PostgreSQL 16
- Generate self-signed TLS certificate
- Create `terraform_state` database + `tfstate` role
- Harden pg_hba.conf (scram-sha-256, hostssl from runner only)
- Configure UFW (5432 from runner 10.60.60.31 only)
- Set up nightly pg_dump backup
- Configure auditd watches

### Step 5: Inject runner-side secret

On the runner VM (tf-runner-prod-01, 10.60.60.31):

```bash
ssh jol-admin@10.60.60.31
sudo tee -a /opt/terraform-runner/secrets/runner.secrets.env <<EOF
PGPASSWORD=<same-password-from-Vaultwarden>
EOF
sudo chmod 0400 /opt/terraform-runner/secrets/runner.secrets.env
sudo chown root:root /opt/terraform-runner/secrets/runner.secrets.env
```

### Step 6: Verify Terraform can reach the state backend

On the runner VM:

```bash
ssh jol-admin@10.60.60.31
cd /opt/jol/repos/jol-infrastructure/terraform/environments/proxmox  # (when created)
terraform init
# Should succeed: "Terraform has been successfully initialized!"
```

## Security Controls

- **ZFS encryption at rest**: VM disk encrypted with key at `/etc/pve/priv/zfs/vm-205.key`
  - ⚠ **BACKUP THIS KEY SECURELY** — if lost, the VM disk is unrecoverable
  - Store in Vaultwarden or secure offline backup
- **TLS in transit**: PostgreSQL uses self-signed cert (sslmode=require)
  - Tracked TODO: upgrade to sslmode=verify-full with fleet CA
- **Network isolation**: UFW default-deny; 5432/tcp from runner (10.60.60.31) only
- **Authentication**: scram-sha-256; pg_hba.conf first-match with reject-all tail
- **Least privilege**: `tfstate` role owns only `terraform_state` DB; no superuser
- **auditd**: watches on pg_hba.conf, postgresql.conf, TLS key/cert, backup dir
- **Backup**: PBS VM backup (RPO 24h) + nightly pg_dump (14-day retention)

## Rollback

If something goes wrong:

```bash
# On prox01
qm stop 205
qm destroy 205 --purge
rm /etc/pve/priv/zfs/vm-205.key
rm /var/lib/vz/snippets/tfstate-prod-01-userdata.yaml
```

The runner VM (tf-runner-prod-01) will continue to work; `terraform init` will fail fast (no state backend reachable). Revert the runner defaults to point at the previous backend if needed.

## Troubleshooting

### VM not starting
- Check prox01 logs: `journalctl -u pvedaemon -u pveproxy`
- Check VM config: `qm config 205`
- Verify ZFS storage: `pvesm status`

### Cloud-init not completing
- Check cloud-init logs on VM: `cat /var/log/cloud-init-output.log`
- Verify QEMU guest agent: `qm agent 205 ping`
- Check VM console via Proxmox web UI

### SSH key not injected
- Verify key file: `cat /tmp/jol-admin.pub`
- Check VM config: `qm config 205 | grep sshkeys`
- Re-inject manually: `qm set 205 --sshkeys /tmp/jol-admin.pub`

### Network unreachable
- Verify IP config: `qm config 205 | grep ipconfig`
- Check VLAN tag: `qm config 205 | grep net0`
- Verify bridge: `ip link show vmbr0`
- Check UFW on prox01: `ufw status`

### PostgreSQL installation fails
- Check Ansible output for errors
- Verify runner can reach state DB: `ssh jol-admin@10.60.60.32 'sudo -u postgres psql -c "SELECT 1"'`
- Check pg_hba.conf: `cat /etc/postgresql/16/main/pg_hba.conf`
- Check TLS cert: `ls -la /etc/ssl/tfstate/`

## References

- Change record: `docs/compliance/evidence/change-record-tf-runner-proxmox-20260925.md`
- Terraform state DB role: `ansible/roles/terraform_state_db/`
- Terraform runner role: `ansible/roles/terraform_runner/`
- Cloud-init userdata: `ansible/roles/terraform_state_db/files/cloud-init-userdata.yaml`
- Proxmox VM topology: `docs/architecture/jol-pilot-vm-topology.md`
- prox01 bridge layout: `docs/network/prox01-vmbr-layout.md`

## Compliance Notes

- **§0.3 Change Control**: This VM creation is documented in JOL-TFRUNNER-20260925-01
- **§0.4 Verification**: All verification gates must pass before declaring operational
- **AGENTS.md §0.1**: No secrets in git; password injected from Vaultwarden at deploy
- **AGENTS.md §0.2**: Church tree only; marketplace uses separate runner in jolarca-infrastructure
- **SOC 2 CC6.1**: State backend uses TLS + scram-sha-256 + least-privilege role
- **SOC 2 CC7.2**: auditd watches on config + TLS material; nightly backup with 14-day retention
- **GDPR Art. 32**: Encryption at rest (ZFS) + in transit (TLS) for state data
