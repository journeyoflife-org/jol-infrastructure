#!/bin/bash
# Provision VM 207 (tf-runner-prod-01) on prox01
# Terraform runner VM - 2 vCPU, 4 GB RAM, 40 GB disk
# VLAN 60, IP 10.60.60.33
#
# Usage: Run as root on prox01
# Prerequisites:
#   - cloud-init userdata at /var/lib/vz/snippets/tf-runner-prod-01-userdata.yaml
#   - jol-admin SSH public key at /tmp/jol-admin.pub
#   - local-zfs storage configured

set -euo pipefail

VMID=207
VM_NAME="tf-runner-prod-01"
CORES=2
MEMORY=4096
DISK_SIZE=40
STORAGE="local-zfs"
BRIDGE="vmbr0"
VLAN_TAG=60
IP_ADDR="10.60.60.33/24"
GATEWAY="10.60.60.1"

echo "=== Preflight checks ==="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

# Check if VM already exists
if qm status ${VMID} &>/dev/null; then
    echo "ERROR: VM ${VMID} already exists"
    qm status ${VMID}
    exit 1
fi

# Check if cloud-init userdata exists
if [[ ! -f "/var/lib/vz/snippets/${VM_NAME}-userdata.yaml" ]]; then
    echo "ERROR: cloud-init userdata not found at /var/lib/vz/snippets/${VM_NAME}-userdata.yaml"
    echo "Copy from: ansible/roles/terraform_runner/files/cloud-init-userdata.yaml"
    exit 1
fi

# Check if SSH key exists
if [[ ! -f "/tmp/jol-admin.pub" ]]; then
    echo "ERROR: jol-admin SSH public key not found at /tmp/jol-admin.pub"
    echo "Extract from existing host: cat /home/jol-admin/.ssh/authorized_keys > /tmp/jol-admin.pub"
    exit 1
fi

# Check if storage exists
if ! pvesm status | grep -q "^${STORAGE}"; then
    echo "ERROR: Storage '${STORAGE}' not found"
    pvesm status
    exit 1
fi

echo " Preflight checks passed"

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

echo " VM created and started"

echo "=== Verification ==="
sleep 5

# Check VM status
echo "VM status:"
qm status ${VMID}

# Check config
echo -e "\nVM config (key settings):"
qm config ${VMID} | grep -E "^(name|memory|cores|net0|scsi0|ipconfig0|cicustom):"

# Wait for cloud-init
echo -e "\nWaiting 60 seconds for cloud-init to complete..."
sleep 60

# Try QEMU agent
echo -e "\nQEMU agent check:"
if qm agent ${VMID} ping 2>/dev/null; then
    echo " QEMU guest agent is running"
else
    echo " QEMU guest agent not yet responding (may still be initializing)"
fi

echo -e "\n=== Next steps ==="
echo "1. Wait ~60 seconds for cloud-init to finish"
echo "2. Test SSH: ssh jol-admin@${IP_ADDR%/*}"
echo "3. Run Ansible playbook: ansible/playbooks/provision-terraform-runner.yml"
echo "4. Verify GitHub Actions runner registration"

echo -e "\n=== VM ${VMID} creation complete ==="
