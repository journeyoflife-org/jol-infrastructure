#!/usr/bin/env bash
# =============================================================================
# prox01-create-vm205-tfstate.sh — Create Terraform state DB VM on prox01
# =============================================================================
# Change Record: JOL-TFRUNNER-20260925-01 (R1 resolution)
# VM: tfstate-prod-01 (VMID 205, 10.60.60.32, VLAN 60, 2 vCPU / 4 GB / 40 GB)
# Purpose: Dedicated PostgreSQL for Terraform `pg` state backend
#
# PREREQUISITES:
#   - SSH/console access to prox01 (10.60.60.10) as root
#   - jol-admin SSH public key (extract from existing host or provide manually)
#   - Cloud-init userdata file (from repo: ansible/roles/terraform_state_db/files/cloud-init-userdata.yaml)
#   - ZFS storage configured on prox01 (local-zfs or custom ZFS storage)
#
# USAGE:
#   1. Copy this script + cloud-init-userdata.yaml to prox01
#   2. Make executable: chmod +x prox01-create-vm205-tfstate.sh
#   3. Run as root: ./prox01-create-vm205-tfstate.sh
#
# VERIFICATION:
#   - VM 205 running
#   - Cloud-init completed (hostname, TZ, jol-admin user)
#   - SSH accessible via jol-admin key
#   - IP 10.60.60.32 reachable
#   - PostgreSQL NOT yet installed (Ansible role installs it next)
#
# ROLLBACK:
#   qm stop 205 && qm destroy 205 --purge
#   zfs destroy rpool/data/vm-205-disk-0  # if manually created
#   rm /etc/pve/priv/zfs/vm-205.key  # encryption key
#   rm /var/lib/vz/snippets/tfstate-prod-01-userdata.yaml  # cloud-init
# =============================================================================

set -euo pipefail

# --- Configuration ---
VMID=205
VM_NAME="tfstate-prod-01"
MEMORY=4096  # MB
CORES=2
DISK_SIZE=40  # GB
IP_ADDR="10.60.60.32/24"
GATEWAY="10.60.60.1"
VLAN_TAG=60
BRIDGE="vmbr0"
STORAGE="local-zfs"  # Adjust if using custom ZFS storage name
ENCRYPTION_KEY_FILE="/etc/pve/priv/zfs/vm-${VMID}.key"
CLOUD_INIT_USERDATA="/var/lib/vz/snippets/${VM_NAME}-userdata.yaml"

# --- Preflight checks ---
echo "=== Preflight checks ==="

# Check if VM already exists
if qm status ${VMID} &>/dev/null; then
    echo "ERROR: VM ${VMID} already exists. Use 'qm destroy ${VMID} --purge' to remove it first."
    exit 1
fi

# Check if cloud-init userdata exists
if [ ! -f "${CLOUD_INIT_USERDATA}" ]; then
    echo "ERROR: Cloud-init userdata not found at ${CLOUD_INIT_USERDATA}"
    echo "Copy ansible/roles/terraform_state_db/files/cloud-init-userdata.yaml to prox01"
    exit 1
fi

# Check if jol-admin SSH key file exists
if [ ! -f "/tmp/jol-admin.pub" ]; then
    echo "ERROR: jol-admin SSH public key not found at /tmp/jol-admin.pub"
    echo "Extract from existing host: cat /home/jol-admin/.ssh/authorized_keys > /tmp/jol-admin.pub"
    echo "Or provide the key manually"
    exit 1
fi

# Check ZFS storage
if ! pvesm status | grep -q "^${STORAGE}"; then
    echo "ERROR: ZFS storage '${STORAGE}' not found. Adjust STORAGE variable or configure storage."
    exit 1
fi

echo "✓ Preflight checks passed"
echo

# --- Generate ZFS encryption key ---
echo "=== Generating ZFS encryption key ==="
mkdir -p "$(dirname "${ENCRYPTION_KEY_FILE}")"
openssl rand -hex 32 > "${ENCRYPTION_KEY_FILE}"
chmod 600 "${ENCRYPTION_KEY_FILE}"
echo "✓ Encryption key generated: ${ENCRYPTION_KEY_FILE}"
echo "⚠ BACKUP THIS KEY SECURELY — if lost, the VM disk is unrecoverable"
echo

# --- Create VM ---
echo "=== Creating VM ${VMID} (${VM_NAME}) ==="

qm create ${VMID} \
    --name "${VM_NAME}" \
    --memory ${MEMORY} \
    --cores ${CORES} \
    --net0 "virtio,bridge=${BRIDGE},tag=${VLAN_TAG}" \
    --ostype l26 \
    --agent enabled=1 \
    --scsi0 "${STORAGE}:${DISK_SIZE}" \
    --ipconfig0 "ip=${IP_ADDR},gw=${GATEWAY}" \
    --cicustom "user=local:snippets/${VM_NAME}-userdata.yaml" \
    --sshkeys /tmp/jol-admin.pub \
    --start 1

echo "✓ VM ${VMID} created and started"
echo

# --- Verification ---
echo "=== Verification (wait ~60s for cloud-init) ==="
sleep 60

# Check VM status
if ! qm status ${VMID} | grep -q "status: running"; then
    echo "ERROR: VM ${VMID} is not running"
    exit 1
fi
echo "✓ VM ${VMID} is running"

# Check cloud-init completion
if ! qm agent ${VMID} ping &>/dev/null; then
    echo "WARNING: QEMU guest agent not responding yet (cloud-init may still be running)"
    echo "Wait a bit longer and check manually: qm agent ${VMID} ping"
else
    echo "✓ QEMU guest agent responding"
fi

# Check network reachability
if ping -c 3 -W 2 10.60.60.32 &>/dev/null; then
    echo "✓ VM reachable at 10.60.60.32"
else
    echo "WARNING: VM not yet reachable at 10.60.60.32 (may still be booting)"
    echo "Check manually: ping 10.60.60.32"
fi

echo
echo "=== Next steps ==="
echo "1. SSH to the VM: ssh jol-admin@10.60.60.32"
echo "2. Run the Ansible role to install PostgreSQL:"
echo "   cd /opt/jol/repos/jol-infrastructure/ansible"
echo "   ansible-playbook playbooks/provision-terraform-state-db.yml \\"
echo "     -e 'terraform_state_db_password=<from Vaultwarden>'"
echo
echo "=== Rollback (if needed) ==="
echo "qm stop ${VMID} && qm destroy ${VMID} --purge"
echo "rm ${ENCRYPTION_KEY_FILE}"
echo "rm ${CLOUD_INIT_USERDATA}"
echo
echo "✓ VM ${VMID} (${VM_NAME}) creation complete"
