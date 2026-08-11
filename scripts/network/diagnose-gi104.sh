#!/usr/bin/env bash
# =============================================================================
# diagnose-gi104.sh — Read-only diagnostics for llm-prod-lt01 (Gi1/0/4, VLAN 30)
#
# Symptom: 10.30.30.10 unreachable while 10.10.10.2 (switch) and 10.30.30.1
# (MikroTik VLAN 30 gateway) are reachable — fault isolated to host/port.
# Suspected cause after hardware swap (Ryzen 7 -> Ryzen 9 3950X):
#   physical link down on host side (observed 2026-08-05), port-security
#   violation shutdown (err-disabled), or missing host IP config.
#
# Usage: python3 scripts/network/n2048-cli.py will prompt for the switch
# password. Run from the admin workstation (admin01, 10.10.10.50).
#
# Compliance: SOC 2 CC7.2 — save output as evidence:
#   ./diagnose-gi104.sh 2>&1 | tee /tmp/gi104-diag-$(date +%F).txt
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$REPO_ROOT/scripts/network/n2048-cli.py"

echo "== Step 1: reachability checks (local) =="
for ip in 10.30.30.10 10.10.10.2 10.30.30.1; do
    if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
        echo "  $ip: REACHABLE"
    else
        echo "  $ip: UNREACHABLE"
    fi
done

echo "== Step 2: switch-side port state (read-only) =="
python3 "$CLI" --commands \
    "show interfaces status gi1/0/4" \
    "show interfaces status err-disabled" \
    "show interfaces switchport gi1/0/4" \
    "show mac-address-table vlan 30" \
    "show mac-address-table address 244b.fe55.b1c5"

echo
echo "== Interpretation =="
echo "  - err-disabled listed                 -> port-security violation (MAC changed);"
echo "      fix: scripts/network/n2048-cli.py --config 'interface gigabitethernet 1/0/4' shutdown 'no shutdown' exit"
echo "  - admin up, link Down, not err-disabled -> PHYSICAL:"
echo "      host power / NIC LEDs / cable / onboard LAN enabled in UEFI"
echo "  - link Up: compare MAC learned on Gi1/0/4 (vlan 30 table) with the ROG's"
echo "      NIC MACs ('ip -br link' on the ROG). Wrong port -> move the cable to the"
echo "      intended ROG NIC, then configure netplan on llm-prod-lt01"
echo "      (static 10.30.30.10/24, gateway 10.30.30.1)."
echo "  - 'show mac-address-table address 244b.fe55.b1c5' shows which switch port"
echo "      the ROG enp4s0 cable is REALLY plugged into (observed 2026-08-06:"
echo "      Gi1/0/4 Down, VLAN 30 empty -> cable crossed to another port/device)."
