# Dell N2048 — Corrected Port Table & Hostname Registry

> **Source of truth alignment**: This document is reconciled against
> `inventory/prod/hosts.yml`, `docs/servers/*.md`, and `docs/architecture/network-topology.md`.
>
> **Compliance**: SOC 2 Type II / GDPR (EU 2016/679) / ISO 27001:2022
>
> **Last verified**: 2026-07-31 (post-configuration audit)
>
> **Configuration applied**: 2026-07-31 — see `n2048-config-2026-07-31.txt`
>
> **⚠️ NO CREDENTIALS in this document. Use the secrets manager (see `docs/architecture/secret-flow.md`).**
>
> **Known limitation**: BPDU Guard not configurable via CLI on firmware 6.7.1.24.
> Enable via web UI (http://10.10.10.2) or upgrade firmware. Port-security
> (violation=shutdown) is the primary MAC-level control.

---

## 1. VLAN Scheme (Target Architecture)

| VLAN | Subnet | Purpose | Gateway |
|------|--------|---------|---------|
| 10 | 10.10.10.0/24 | Management (switch, iDRAC, storage mgmt, admin) | 10.10.10.1 |
| 20 | 10.20.20.0/24 | Workstations (dev/test) | 10.20.20.1 |
| 30 | 10.30.30.0/24 | GPU / LLM inference | 10.30.30.1 |
| 40 | 10.40.40.0/24 | AI Services (RAG, MCP, Hermes VMs) | 10.40.40.1 |
| 50 | 10.50.50.0/24 | Marketplace | 10.50.50.1 |
| 60 | 10.60.60.0/24 | Proxmox hypervisors (management NICs) | 10.60.60.1 |
| 70 | 10.70.70.0/24 | iSCSI storage fabric | 10.70.70.1 |
| 85 | 10.85.85.0/24 | PBS backup replication | 10.85.85.1 |
| 90 | 10.90.90.0/24 | Offsite / DR (Journey of Life PBS) | 10.90.90.1 |

**Routing**: MikroTik RB5009 (Gi1/0/48 trunk) performs inter-VLAN routing.

---

## 2. Port Table — Active / Confirmed

These ports are verified against the repository source of truth.
**Configuration applied and saved 2026-07-31.**

| Port | Hostname | Description | VLAN | Mode | IP | Status |
|------|----------|-------------|------|------|----|--------|
| Gi1/0/4 | llm-prod-lt01 | LLM bare-metal (2026-08 rebuild: new board/CPU, 1 TB M.2 NVMe, headless) | 30 | access | 10.30.30.10 | **Active** (2026-08-08: commissioned — see Notes on Gi1/0/4) |
| Gi1/0/5 | pve-prod-hv01 | Proxmox VE 9.2 hypervisor (GA-AX370, nic1) | 60 | access | 10.60.60.20 | **Active** (vmbr0 migrated 2026-07-31) |
| Gi1/0/6 | pve-prod-hv01 (nic0) | Proxmox VM traffic (Killer E2500) → vmbr1 | 40 | access | — | **Active** (2026-08-08: VLAN 50 drift corrected to 40; VMs reachable — see Notes on Gi1/0/6) |
| Gi1/0/47 | admin01 | Ubuntu admin workstation | 10 | access | 10.10.10.50 | **Active** |
| Gi1/0/48 | — | MikroTik RB5009 ether2 — uplink/router (STP root) | 10,20,30,40,50,60,70,85,90 | trunk | — | **Active** |

### Notes on Gi1/0/4 (llm-prod-lt01)

- **Observed 2026-08-05**: 10.30.30.10 unreachable from admin01 while
  10.10.10.2 (switch) and 10.30.30.1 (MikroTik VLAN 30 gateway) were
  reachable — fault isolated to the host/port (link Down, not err-disabled).
- **2026-08-07 investigation**: after the board swap the NIC had carrier and
  the static config was correct, but the host could not reach its own gateway
  (10.30.30.1) — it sat on the wrong L2 segment. Decision: full rebuild on
  new bare-metal (new CPU, 1 TB M.2 NVMe, Ubuntu 24.04 LTS) instead of further
  debugging the old board. Server doc: `docs/servers/llm-prod-lt01.md`.
- **Port-security (action at commissioning)**: the new NIC has a new MAC and
  Gi1/0/4 runs `port-security maximum 1 / violation shutdown` with the stale
  sticky MAC. Clear or re-learn the sticky MAC before first link-up, or the
  port will violation-shutdown.
- **Canonical netplan**: single static file — 10.30.30.10/24, gateway
  10.30.30.1; remove the cloud-init network config (50-cloud-init.yaml) so no
  DHCP override can be merged in (present on the old host).
- **Commissioning verification**: llm → `ping 10.30.30.1`; rag →
  `ping 10.30.30.10`; `curl http://10.30.30.10:11434/api/tags`; RAG `/ready`
  shows ollama up. Diagnostics: `scripts/network/diagnose-gi104.sh`.
- Port changes on this active production port require a change request
  (`.github/ISSUE_TEMPLATE/infra-change-request.yml`).
- **2026-08-08**: port-security parent cleared and port bounced; port stayed
  **Down** — the new NIC MAC `244B.FE55.B1C4` was learned on Gi1/0/3
  (VLAN 20): the llm cable is physically plugged in the wrong port.
  Pending action: move cable Gi1/0/3 → Gi1/0/4, verify MAC on VLAN 30,
  then re-arm port-security (`maximum 1 / violation shutdown`).
- **Commissioned 2026-08-08**: cable moved Gi1/0/3 → Gi1/0/4; port Up,
  `244B.FE55.B1C4` learned on VLAN 30; port-security re-armed
  (`maximum 1 / violation shutdown`); config saved. Service gates green
  (Ollama :11434 from VLAN 40) — see `docs/servers/llm-prod-lt01.md`.
  Change request: issue #26.

### Notes on Gi1/0/5 (pve-prod-hv01)

- **Hardware**: GA-AX370-GAMING 5, AMD Ryzen 7 3700X, 64 GB DDR4 (non-ECC),
  **two onboard NICs** (nic0 + nic1), no IPMI/BMC.
- **NIC mapping** (verified 2026-07-31):
  - `nic1` (MAC 1C:1B:0D:9F:4E:A8) → Gi1/0/5, VLAN 60 — **vmbr0 management** (10.60.60.20/24)
  - `nic0` (MAC 1C:1B:0D:9F:4E:A6) → Gi1/0/6, VLAN 40 — **vmbr1 VM traffic** (RAG/MCP/Hermes)
- **IP**: 10.60.60.20/24 (VLAN 60, gateway 10.60.60.1). Migration completed 2026-07-31.
- **vmbr1**: bridge-ports nic0, no host IP. VMs use MikroTik 10.40.40.1 as gateway.
- **VMs hosted** (all on vmbr1, direct L2 to VLAN 40, 10.40.40.0/24):

| VMID | Hostname | IP | Role |
|------|----------|----|------|
| 100 | rag-prod-lt01 | 10.40.40.10 | RAG / vector DB / embeddings |
| 101 | mcp-prod-lt01 | 10.40.40.11 | MCP server / tool registry |
| 102 | her-prod-lt01 | 10.40.40.12 | Hermes agent orchestration |

- **Dual NIC**: vmbr0 uses nic1 (Gi1/0/5, VLAN 60) for management.
  vmbr1 uses nic0 (Gi1/0/6, VLAN 40) for VM traffic — direct L2, no NAT.
  VMs route via MikroTik 10.40.40.1 (inter-VLAN firewall enforced).

### Notes on Gi1/0/6 (pve-prod-hv01 nic0 — vmbr1)

- **Drift found 2026-08-08**: running config still `switchport access vlan 50`
  with description "MARKET-market01", although D5 (2026-07-31) resolved the
  attached device as pve-prod-hv01 nic0 and the 2026-07-31 MAC audit shows
  `1C1B.0D9F.4EA6` learned on VLAN 50. The intended VLAN 40 assignment was
  never applied — VM traffic (rag/mcp/her) never reached the AI Services
  segment; rag-prod-lt01 was unreachable from admin01.
- **Fix (2026-08-08 window)**: `description PVE-PROD-HV01-vmbr1-VM-traffic`,
  `switchport access vlan 40`. Hypervisor management (Gi1/0/5, VLAN 60) is
  unaffected; expect a brief VM traffic blip. Change request: issue #26.
- **Verification**: `show mac address-table` shows `1C1B.0D9F.4EA6` on
  VLAN 40; admin01 → `ping 10.40.40.10` answers.
- **Root cause #2 found the same day**: even with Gi1/0/6 on VLAN 40, VMs
  stayed silent — vmbr1 on pve-prod-hv01 had drifted to an isolated NAT
  bridge (`bridge-ports none`, hypervisor squatting 10.40.40.1, iptables
  MASQUERADE). Restored to the documented L2 bridge (nic0 enslaved, NAT
  rule and host IP removed; backup at `/etc/network/interfaces.bak-20260808`).
- **Result (2026-08-08)**: 10.40.40.10/11/12 all answer from admin01
  (rtt 0.5–2.2 ms). Port-security armed (`maximum 1 / violation
  shutdown`, verified in running config 2026-08-08); running config
  saved 2026-08-08.

### Notes on Gi1/0/10 / Gi1/0/11 (prox01 — Dell R640 Node 1)

- **Hardware**: Dell PowerEdge R640, Service Tag JBJ1BW2, iDRAC9 on
  Gi1/0/40 (10.10.10.11). Provisioning started 2026-08-06:
  `docs/runbooks/proxmox-r640-provisioning.md`, server doc
  `docs/servers/prox01.md`.
- **Gi1/0/11** = primary Proxmox NIC (vmbr0, 10.60.60.10/24).
- **Gi1/0/10** = second NIC, same subnet: keep **un-addressed** until a
  bond is configured (active-backup preferred; LACP requires a port-channel
  on the N2048). Assigning 10.60.60.10 to both ports simultaneously causes
  MAC-flapping and port-security violations.
- **iSCSI (Gi1/0/23, 10.70.70.20)** deferred until open decision D6 is
  closed.

---

## 3. Port Table — Ready (Cabled, Configuration Pending)

| Port | Hostname | Description | VLAN | Mode | IP | Status |
|------|----------|-------------|------|------|----|--------|
| Gi1/0/2 | — | Work PC #1 (ROG VIII Hero) | 20 | access | DHCP / 10.20.20.x | Ready |
| Gi1/0/3 | — | Work PC #2 (ROG VIII Hero) | 20 | access | DHCP / 10.20.20.x | Ready |
| Gi1/0/10 | prox01-mgmt | R640 Node 1 — secondary NIC (spare/failover, bond candidate) | 60 | access | — | In provisioning (2026-08-06) |
| Gi1/0/11 | prox01 | R640 Node 1 — primary Proxmox NIC | 60 | access | 10.60.60.10 | In provisioning (2026-08-06) |
| Gi1/0/12 | prox02 | R640 Node 2 — Proxmox NIC | 60 | access | 10.60.60.11 | Ready |
| Gi1/0/13 | prox03 | R640 Node 3 — Proxmox NIC | 60 | access | 10.60.60.12 | Ready |
| Gi1/0/20 | stor01-mgmt | HP P4500 — management NIC | 10 | access | 10.10.10.30 | Ready |
| Gi1/0/40 | idrac-prox01 | R640 Node 1 — iDRAC | 10 | access | 10.10.10.11 | **Active** (iDRAC reachable, 2026-08-06) |
| Gi1/0/41 | idrac-prox02 | R640 Node 2 — iDRAC | 10 | access | 10.10.10.12 | Ready |
| Gi1/0/42 | idrac-prox03 | R640 Node 3 — iDRAC | 10 | access | 10.10.10.13 | Ready |

---

## 4. Port Table — Configure Now (Action Required)

| Port | Hostname | Description | VLAN | Mode | IP | Action |
|------|----------|-------------|------|------|----|--------|
| Gi1/0/21 | stor01-iscsi1 | HP P4500 — iSCSI NIC #1 | 70 | access | 10.70.70.10 | Assign VLAN 70, set IP |
| Gi1/0/22 | stor01-iscsi2 | HP P4500 — iSCSI NIC #2 | 70 | access | 10.70.70.11 | Assign VLAN 70, set IP |
| Gi1/0/23 | prox01-iscsi | R640 Node 1 — iSCSI NIC | 70 | access | 10.70.70.20 | Assign VLAN 70 |
| Gi1/0/24 | prox02-iscsi | R640 Node 2 — iSCSI NIC | 70 | access | 10.70.70.21 | Assign VLAN 70 |
| Gi1/0/25 | prox03-iscsi | R640 Node 3 — iSCSI NIC | 70 | access | 10.70.70.22 | Assign VLAN 70 |

---

## 5. Port Table — Future (Arriving 4–8 Weeks)

| Port | Hostname | Description | VLAN | Mode | IP |
|------|----------|-------------|------|------|----|
| Gi1/0/14 | prox04.lt | Dell R740 #1 — Proxmox NIC | 60 | access | 10.60.60.13 |
| Gi1/0/15 | prox05.lv | Dell R740 #2 — Proxmox NIC | 60 | access | 10.60.60.14 |
| Gi1/0/16 | prox06.ee | Dell R740 #3 — Proxmox NIC | 60 | access | 10.60.60.15 |
| Gi1/0/17 | pbs02 | Dell R740 PBS — backup NIC | 85 | access | 10.85.85.11 |
| Gi1/0/18 | pbs-jol01 | Dell R740 Journey of Life PBS | 90 | access | 10.90.90.10 |
| Gi1/0/26 | — | Dell R740 #1 — iSCSI NIC | 70 | access | 10.70.70.30 |
| Gi1/0/27 | — | Dell R740 #2 — iSCSI NIC | 70 | access | 10.70.70.31 |
| Gi1/0/28 | — | Dell R740 #3 — iSCSI NIC | 70 | access | 10.70.70.32 |
| Gi1/0/29 | — | Dell R740 PBS — replication NIC | 85 | access | 10.85.85.12 |
| Gi1/0/30 | — | Dell R740 JOL PBS — offsite NIC | 90 | access | 10.90.90.11 |
| Gi1/0/43 | idrac-r740-lt1 | Dell R740 #1 — iDRAC | 10 | access | 10.10.10.21 |
| Gi1/0/44 | idrac-r740-lv1 | Dell R740 #2 — iDRAC | 10 | access | 10.10.10.22 |
| Gi1/0/45 | idrac-r740-ee1 | Dell R740 #3 — iDRAC | 10 | access | 10.10.10.23 |
| Gi1/0/46 | idrac-pbs01 | Dell R740 PBS — iDRAC | 10 | access | 10.10.10.24 |

---

## 6. Port Table — Spare / Unused

| Ports | Status |
|-------|--------|
| Gi1/0/1 | Shutdown — reserved future LAG (was old MikroTik trunk, link down) |
| Gi1/0/7 | Shutdown — parked pending D4 decision |
| Gi1/0/8, Gi1/0/9 | Shutdown — spare |
| Gi1/0/14 – Gi1/0/18 | Shutdown — future R740 (arriving 4–8 wks) |
| Gi1/0/26 – Gi1/0/39 | Shutdown — future/unused |
| Gi1/0/43 – Gi1/0/46 | Shutdown — future iDRAC (R740) |
| Te1/0/1, Te1/0/2 | Spare 10G uplinks |

---

## 7. Ports — HP P4500 (Identified, Link Down)

During the 2026-07-31 audit, Gi1/0/19 and Gi1/0/20 were confirmed as HP P4500
PBS management NICs (not "unknown devices"). They are configured on VLAN 10
but have no link (device not yet cabled or powered).

| Port | Hostname | Description | VLAN | Status |
|------|----------|-------------|------|--------|
| Gi1/0/19 | stor01-mgmt | HP P4500 PBS mgmt NIC 0 | 10 | Configured, link down |
| Gi1/0/20 | stor01-mgmt | HP P4500 PBS mgmt NIC 1 | 10 | Configured, link down |

> **Note**: The original port table listed these as "unknown devices". Physical
> audit confirmed they are labelled HP P4500 connections. No incident action required.

---

## 8. Open Decisions (Blocking Configuration)

| # | Question | Impact | Decision Owner |
|---|----------|--------|----------------|
| D1 | ~~Is pve-prod-hv01 migrating from 192.168.80.0/24 to VLAN 60 (10.60.60.20)?~~ | **DONE** — vmbr0 migrated 2026-07-31 | jol-admin |
| D2 | ~~Will a second NIC be added?~~ | **RESOLVED** — second NIC (nic0) exists onboard, cabled to Gi1/0/6, available as spare | jol-admin |
| D3 | Is there a separate physical MCP server (GA-AX370) distinct from pve-prod-hv01? | Original table listed "mcp01" on Gi1/0/5 as bare-metal. Repo says MCP is a VM (VMID 101). | jol-admin |
| D4 | Is "rag01" on Gi1/0/7 a NEW bare-metal machine, or confusion with rag-prod-lt01 (VM)? | If new: needs hostname (e.g., rag-prod-lt02), VLAN decision, Ubuntu 24.04 (NOT 22.04). | jol-admin |
| D5 | ~~Where does marketplace (market01.lt) connect?~~ | **RESOLVED** — Gi1/0/6 device was pve-prod-hv01 nic0 (MAC 1C:1B:0D:9F:4E:A6), not market01. market01.lt location TBD. | jol-admin |
| D6 | HP P4500 PBS backup traffic: separate NIC on VLAN 85, or via mgmt NIC (VLAN 10)? | Affects port assignment and backup network isolation. | jol-admin |

---

## 9. Corrected Hostname Registry

### Production (Confirmed in Repository)

| Hostname | IP | VLAN | Role | Hardware | Site |
|----------|----|------|------|----------|------|
| llm-prod-lt01 | 10.30.30.10 | 30 | GPU/LLM inference (Ollama) | bare-metal (2026-08 rebuild: Ryzen 9 3950X, 1 TB M.2 NVMe, headless) | On-site |
| pve-prod-hv01 | 10.60.60.20 | 60 | Proxmox VE 9.2 hypervisor | GA-AX370, Ryzen 7 3700X | On-site |
| rag-prod-lt01 | 10.40.40.10 | 40 | RAG / vector DB (VM 100) | Virtual (pve-prod-hv01) | On-site |
| mcp-prod-lt01 | 10.40.40.11 | 40 | MCP server (VM 101) | Virtual (pve-prod-hv01) | On-site |
| her-prod-lt01 | 10.40.40.12 | 40 | Hermes agent (VM 102) | Virtual (pve-prod-hv01) | On-site |

### Infrastructure

| Hostname | IP | VLAN | Role | Site |
|----------|----|------|------|------|
| sw01-mgmt | 10.10.10.2 | 10 | Dell N2048 switch management | On-site |
| admin01 | 10.10.10.50 | 10 | Ubuntu admin workstation | On-site |
| stor01-mgmt | 10.10.10.30 | 10 | HP P4500 management NIC | On-site |
| stor01-iscsi1 | 10.70.70.10 | 70 | HP P4500 iSCSI target #1 | On-site |
| stor01-iscsi2 | 10.70.70.11 | 70 | HP P4500 iSCSI target #2 | On-site |
| idrac-prox01 | 10.10.10.11 | 10 | R640 Node 1 iDRAC | On-site |
| idrac-prox02 | 10.10.10.12 | 10 | R640 Node 2 iDRAC | On-site |
| idrac-prox03 | 10.10.10.13 | 10 | R640 Node 3 iDRAC | On-site |
| idrac-r740-lt1 | 10.10.10.21 | 10 | R740 #1 iDRAC | Lithuania |
| idrac-r740-lv1 | 10.10.10.22 | 10 | R740 #2 iDRAC | Latvia |
| idrac-r740-ee1 | 10.10.10.23 | 10 | R740 #3 iDRAC | Estonia |
| idrac-pbs01 | 10.10.10.24 | 10 | R740 PBS iDRAC | On-site |

### Compute (Planned / Arriving)

| Hostname | IP | VLAN | Role | Site |
|----------|----|------|------|------|
| prox01 | 10.60.60.10 | 60 | R640 Node 1 Proxmox VE | On-site |
| prox02 | 10.60.60.11 | 60 | R640 Node 2 Proxmox VE | On-site |
| prox03 | 10.60.60.12 | 60 | R640 Node 3 Proxmox VE | On-site |
| prox04.lt | 10.60.60.13 | 60 | R740 #1 Proxmox VE | Lithuania |
| prox05.lv | 10.60.60.14 | 60 | R740 #2 Proxmox VE | Latvia |
| prox06.ee | 10.60.60.15 | 60 | R740 #3 Proxmox VE | Estonia |

### Backup / DR

| Hostname | IP | VLAN | Role | Site |
|----------|----|------|------|------|
| pbs01 | 10.10.10.30 | 10 | HP P4500 PBS Pilot (PBS 4.2) | On-site |
| pbs02 | 10.85.85.11 | 85 | R740 PBS (PBS 4.2) | On-site |
| pbs-jol01 | 10.90.90.10 | 90 | R740 Journey of Life PBS (offsite) | On-site |

### Marketplace (Planned)

| Hostname | IP | VLAN | Role | Site |
|----------|----|------|------|------|
| market01.lt | 10.50.50.10 | 50 | Marketplace (SABERTOOTH) | Lithuania |
| market01.lv | 10.50.50.11 | 50 | R740 #2 Marketplace VM | Latvia |
| market01.ee | 10.50.50.12 | 50 | R740 #3 Marketplace VM | Estonia |

---

## 10. Compliance & Security Notes

### Mandatory Before Any Port Configuration

| # | Action | Standard | Status |
|---|--------|----------|--------|
| 1 | Rotate HP P4500 management credentials (previously exposed in plaintext) | SOC 2 CC6.1, GDPR Art. 32, ISO 27001 A.10.1.2 | **PENDING** |
| 2 | Remove SNMP rw community "dellslaptazodis" from N2048 | SOC 2 CC6.1, ISO 27001 A.8.20 | **DONE** (2026-08-08, issue #26: rw community removed, replaced with read-only community; new value in secrets manager; admin password rotated same window) |
| 3 | Disable VLAN 1 as a data VLAN on all access ports | CIS Benchmark, NIST 800-53 AC-3 | **DONE** (all ports assigned to non-default VLANs) |
| 4 | Enable port-security (MAC sticky, max 1 MAC per access port) | ISO 27001 A.8.20 | **DONE** (globally enabled, per-port configured) |
| 5 | Enable 802.1X / NAC if supported by N2048 firmware | SOC 2 CC6.1 | Deferred (firmware limitation) |
| 6 | Configure spanning-tree BPDU guard on all access ports | Availability (SOC 2 A1.1) | **BLOCKED** (not available via CLI on 6.7.1.24) |
| 7 | Log all switch config changes to centralised logging | SOC 2 CC7.2, ISO 27001 A.8.15 | **PENDING** |

### Ongoing Controls

- **No credentials in documentation** — use secrets manager only.
- **All production changes** require: ticket → branch → review → CI → merge → deploy.
- **Port changes** to active production ports (Gi1/0/4, Gi1/0/5, Gi1/0/47, Gi1/0/48)
  require a formal change request (`.github/ISSUE_TEMPLATE/infra-change-request.yml`).
- **Unknown devices**: any unrecognised MAC on a production VLAN triggers incident
  response (`docs/runbooks/incident-response.md`).

---

## 11. Migration Notes (Current → Target)

### pve-prod-hv01 Network Migration — COMPLETED 2026-07-31

**Previous state** (decommissioned):
- vmbr0: 192.168.80.106/24 (flat management LAN, gateway 192.168.80.1)

**Current state** (active):
- vmbr0: 10.60.60.20/24 on VLAN 60 (gateway 10.60.60.1 via MikroTik) — bridge-ports nic1
- vmbr1: bridge-ports nic0 (VLAN 40 access, Gi1/0/6) — VM traffic, no host IP
- Admin access: SSH key-only via 10.60.60.20
- Gi1/0/5: UP, 1000 Full, VLAN 60, MAC 1C1B.0D9F.4EA8

**Completed steps**:
1. ✅ Gi1/0/5 configured as VLAN 60 access port on N2048.
2. ✅ MikroTik: VLAN 60 SVI, gateway 10.60.60.1 (verified reachable).
3. ✅ vmbr0 reconfigured to 10.60.60.20/24 (bridge-ports nic1).
4. ✅ Update Ansible inventory (`inventory/prod/hosts.yml`) — pbs01 added, ProxyJump removed.
5. ✅ Remove `ansible_ssh_common_args` ProxyJump for VMs (direct routing via MikroTik).
6. ⬜ Verify VM connectivity, backup jobs, monitoring.
7. ⬜ Update `/etc/hosts`, DNS records for migrated hosts.
8. ⬜ Decommission 192.168.80.0/24 once all devices migrated.

### HP P4500 Migration

**Current**: 192.168.80.x (management LAN).
**Target**: Management NIC → 10.10.10.30 (VLAN 10); iSCSI NICs → 10.70.70.10/11 (VLAN 70).

---

## 12. Corrections Applied (vs. Original Document)

| Issue | Original | Corrected | Reason |
|-------|----------|-----------|--------|
| Gi1/0/5 device | "MCP Server (GA-AX370) — mcp01, VLAN 40" | pve-prod-hv01, VLAN 60 | GA-AX370 IS the hypervisor; MCP is a VM on it |
| Gi1/0/5 IP | 10.40.40.10 (conflicts with rag-prod-lt01) | 10.60.60.20 | Hypervisor mgmt on Proxmox VLAN |
| Gi1/0/6 | Two conflicting assignments | **Unassigned pending D5** | Cannot verify physical device |
| Gi1/0/7 | "RAG Machine, Ubuntu 22, VLAN 30" | **Unassigned pending D4** | rag-prod-lt01 is a VM; Ubuntu 22 non-compliant |
| Gi1/0/10 | "Storage 10.70.70.10 VLAN 70" (recommended) | R640 Node 1 mgmt, VLAN 60 | Storage is on Gi1/0/21-22, not Gi1/0/10 |
| Gi1/0/47 | "Move to VLAN 20, 10.20.20.10" | Keep VLAN 10, 10.10.10.50 | Admin workstation manages VLAN 10 devices |
| Proxmox MGMT section | Two-NIC config (I211 + Killer E2500) | **Restored** — two NICs confirmed (nic0 + nic1) | Physical audit 2026-07-31 confirmed dual NIC |
| admin01 IP | 10.10.10.50 AND 10.20.20.10 (contradictory) | 10.10.10.50 | Consistent with hostname registry |
| Gi1/0/10 IP | Same IP as Gi1/0/11 (10.60.60.10 on both ports) | — (spare/failover, bond candidate) | Duplicate IP on two ports of one host causes MAC-flapping; address via bond only |
| mcp01 IP | 10.40.40.10 | 10.40.40.11 (mcp-prod-lt01) | 10.40.40.10 = rag-prod-lt01 |
| Credentials | "Administrator / lexx.lexx." in table | **REMOVED** | SOC 2 CC6.1, GDPR Art. 32 violation |
| 10.40.10.10 | Proxmox MGMT IP | **Removed** | Matches no VLAN scheme |

---

## Appendix: Dell N2048 Configuration Commands (Reference)

```
! === VLAN Creation ===
configure
vlan 10
name MGMT
vlan 20
name WORKSTATIONS
vlan 30
name GPU-LLM
vlan 40
name AI-SERVICES
vlan 50
name MARKETPLACE
vlan 60
name PROXMOX
vlan 70
name ISCSI
vlan 85
name PBS-BACKUP
vlan 90
name OFFSITE-DR
exit

! === Access Port Template ===
interface gigabitethernet 1/0/PORT
switchport mode access
switchport access vlan VLAN_ID
spanning-tree bpduguard enable
switchport port-security
switchport port-security maximum 1
switchport port-security violation shutdown
description "HOSTNAME - ROLE"
exit

! === Trunk Port (MikroTik) ===
interface gigabitethernet 1/0/48
switchport mode trunk
switchport trunk allowed vlan 10,20,30,40,50,60,70,85,90
description "MikroTik RB5009 - ALL VLANs"
exit

! === Shutdown Unknown Devices ===
interface gigabitethernet 1/0/19
shutdown
description "INCIDENT - unknown device VLAN 1"
exit
interface gigabitethernet 1/0/20
shutdown
description "INCIDENT - unknown MAC 246E.96CB.FFCD"
exit

! === Disable VLAN 1 on access ports ===
! (Applied per-port via 'switchport access vlan X' above)
! Ensure no port remains in VLAN 1 by default
```

> **Note**: Commands are reference only. Apply via change-control process.
> Test in maintenance window. Never configure production ports without an
> approved change request.
