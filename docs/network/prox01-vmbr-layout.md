# prox01 — Bridge (vmbr) Layout for JOL Pilot Lithuania

> **Status**: DRAFT — DMZ VLAN ID/subnet pending ADR-004 amendment; switch
> port change pending execution window.
> **Date**: 2026-08-23
> **Compliance**: SOC 2 Type II / GDPR (EU 2016/679) / ISO 27001:2022.
> **Inputs**: `docs/architecture/jol-pilot-vm-topology.md` (Step 1),
> `docs/servers/prox01.md`, `docs/network/dell-n2048-port-table.md`,
> `docs/servers/pve-prod-hv01.md` (design pattern), AGENTS.md §1 rule 3.
> **⚠️ NO CREDENTIALS in this document** — see `docs/architecture/secret-flow.md`.

## 1. Physical NIC inventory (verified: `docs/servers/prox01.md` Network table)

| NIC | Hardware | Switch port | State | Usable for bridges? |
|-----|----------|-------------|-------|---------------------|
| nic1 (MAC 24:6e:96:cb:ff:cd) | I350 1G copper | Gi1/0/11 (VLAN 60, access, in provisioning) | Active — carries vmbr0 / 10.60.60.10 | ✅ Yes (primary) |
| nic0 (MAC 24:6e:96:cb:ff:cc) | I350 1G copper | Gi1/0/10 (cabled, un-addressed) | Reserved for bond (runbook Phase 5 #4) | ❌ Not until bond exists |
| nic2 / nic3 | X520 10G SFP+ | — | Dark — no fiber on site | ❌ No |

**Constraint**: exactly ONE usable physical port exists today. The
pve-prod-hv01 pattern (one bridge per NIC: vmbr0=nic1/VLAN 60,
vmbr1=nic0/VLAN 40) is therefore **not directly reproducible** on prox01 —
nic0 is contractually reserved for the future active-backup bond, and
assigning it to a second VLAN now would burn the bond path and contradict
the provisioning runbook.

## 2. Recommended layout — single VLAN-aware trunk bridge

| Bridge | Interface | VLAN Mode | Native VLAN | Tagged VLANs | CIDR (per VLAN) | Gateway (per VLAN) | Connected VMs |
|--------|-----------|-----------|-------------|--------------|-----------------|--------------------|---------------|
| vmbr0 | nic1 → Gi1/0/11 (trunk) | vlan-aware | 60 (mgmt) | 40, 45 | 60→10.60.60.0/24 · 40→10.40.40.0/24 · 45→10.45.45.0/24 (proposed) | 60→10.60.60.1 · 40→10.40.40.1 (MikroTik) · 45→10.45.45.1 (MikroTik SVI, to be created) | 200/201/202 (tag 40); 203 dual-homed (net0 tag 45, net1 tag 40); 204 (native 60); host IP 10.60.60.10 native 60 |
| **(no vmbr30)** | — | — | — | — | — | — | **EXCLUDED — VLAN 30 is the air-gapped LLM segment; app→Ollama traffic is ROUTED via MikroTik only (rag-prod-lt01 precedent), never bridged on prox01** |

VLAN 45 status: ⚠ UNVERIFIED — manual check required: ADR-004 amendment
must approve VLAN ID + subnet before configuration.

**VM 203 dual-homing**: two vNICs on the SAME physical bridge but different
VLAN tags (net0 = 45/DMZ, net1 = 40/backend). There is **no bridged L2 path
between DMZ and backend** — the guest runs as a proxy that terminates on
the DMZ side and originates new connections toward the backend; every
cross-VLAN flow is enforced at MikroTik L3 (see
`docs/security/jol-pilot-firewall-matrix.md` §3). Dual-homing itself is a
tracked architecture decision (ADR-00y, §5).

**Explicit exclusions** (deliberate, not omissions):
- **No VLAN 30 on prox01.** VLAN 30 (10.30.30.0/24) is the air-gapped LLM
  segment; llm-prod-lt01 is bare metal on Gi1/0/4. Pilot app → Ollama
  (10.30.30.10:11434) is **routed** via the MikroTik inter-VLAN firewall —
  the exact precedent rag-prod-lt01 uses (`docs/architecture/trust-boundaries.md`
  Data Flows). No bridge on prox01 may carry VLAN 30.
- **No VLAN 50.** Already allocated to Marketplace (market01.lt) — the
  Church-platform pilot must not share the marketplace audit surface
  (AGENTS.md §0.2 tree segregation).
- **No host IP on tagged VLANs** — the hypervisor is addressable only on
  VLAN 60 (mgmt), matching the hv01 hardening baseline.

### PVE `/etc/network/interfaces` sketch (apply via change control)

```
auto vmbr0
iface vmbr0 inet manual
    bridge-ports nic1
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 40 45

iface vmbr0.60 inet static
    address 10.60.60.10/24
    gateway 10.60.60.1
    # native VLAN — host management only
```

> ⚠ UNVERIFIED — manual check required: PVE interface names on the R640
> (`ip -br link` after install). `nic1` maps to whichever I350 MAC ends in
> `:cd`; confirm before applying.

## 3. Required N2048 switch change (Gi1/0/11: access → trunk)

Gi1/0/11 is a **Ready/in-provisioning** port — per port table §10 no formal
CR applies (CRs cover active production ports only), but the change is
recorded in the change log regardless.

```
interface gigabitethernet 1/0/11
switchport mode general
switchport general allowed vlan add 40,45 tagged
switchport general pvid 60
description "PROX01-vmbr0-trunk-VLAN60native+40+45"
exit
```

**Port-security interaction** (⚠ UNVERIFIED — manual check required: N2048
firmware 6.7.1.24 behaviour with multiple MACs on a general-mode port):
the fleet standard is `maximum 1 / violation shutdown` per access port;
trunking ≥5 VM MACs through one port requires either raising the limit for
this port or exempting it, with the compensating control being hypervisor-side
MAC filtering + the MikroTik inter-VLAN firewall. Decide and record before
execution — do NOT silently disable port-security.

**VLAN creation**: VLAN 45 does not exist in the scheme yet — create it in
the same window (`vlan 45 / name DMZ-PILOT`) together with the MikroTik SVI
+ firewall rules, all gated on the ADR-004 amendment.

## 4. Alternatives considered (rejected)

| Option | Description | Rejection reason |
|--------|-------------|------------------|
| B — mirror hv01 exactly (vmbr1 on nic0 for VLAN 40) | One bridge per NIC | Consumes the bond-candidate port; still needs a trunk for the DMZ VLAN; two-port MAC-flap risk if misconfigured (port table §12 correction history) |
| C — wait for the bond | active-backup nic0+nic1 first | Correct end-state, but blocks the pilot on a non-blocking dependency; single-link risk is accepted and documented for the pilot phase |
| D — ingress on VLAN 50 | Reuse Marketplace segment | Violates Church/Marketplace audit-surface segregation (AGENTS.md §0.2) |

## 5. ADR / cross-repo impact (AGENTS.md §1 rule 3)

- **ADR-004 amendment REQUIRED** — new DMZ segment + DMZ→VLAN 40 trust
  boundary crossing. Blocking for VM 203. The amendment defines the
  segment AND its permitted flows (ingress→app is the only 45→40 pair).
- **ADR-00x (tracked)** — Bitrix connector egress to the Internet
  (40→WAN, FQDN allowlist). Generic VLAN 40→WAN masquerade precedent
  exists (`docs/architecture/network-topology.md` flow 2), but an
  allowlisted SaaS egress path carrying Art. 9-adjacent sync data gets
  its own documented decision.
- **ADR-00y (tracked)** — ingress dual-homing design, the cross-VLAN
  monitoring flows (observ 10.60.60.30 → pilot guests :9100, mgmt→guest
  direction — fleet scrape precedent exists but is ratified explicitly for
  the pilot), and the log-push direction question: guest→Loki push
  (40/45→60) inverts the fleet pattern; decide push vs pull and record it.
- VLAN 40 → VLAN 30 (app→Ollama, if pilot uses LLM): existing precedent
  (rag-prod-lt01), MikroTik rule already permits 10.40.40.0/24 →
  10.30.30.10:11434 — no new ADR, but the pilot source IPs must be added
  to that rule's scope check.
- Downstream repos: `jol-bitrix24-integration` (egress contract for VM 202),
  `jol-core`/`jol-backend-platform` (app port contract behind ingress).

## Verification checklist

- [ ] ADR-004 amendment merged approving VLAN ID + subnet for pilot DMZ
- [ ] `ip -br link` on prox01 confirms NIC→name mapping (record above)
- [ ] Gi1/0/11 trunk applied; `show interface gi1/0/11 switchport` shows general mode, pvid 60, tagged 40+DMZ
- [ ] Port-security decision recorded for the trunk port
- [ ] Each pilot VM reaches its own gateway; hypervisor reachable only on 10.60.60.10
- [ ] `docs/servers/prox01.md` Network table updated with final bridge layout

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-23 | Initial vmbr layout (DRAFT) — single vlan-aware trunk on nic1; VLAN 30 excluded; DMZ VLAN 45 proposed | this document; port table §3, §10 |
| 2026-08-23 | Ratified-spec reconciliation: consolidated trunk table with explicit no-vmbr30 exclusion row; VM 203 dual-homing note; ADR-00x (Bitrix egress) + ADR-00y (dual-homing/log-push direction) registered | Step 2 ratified task spec |
| 2026-08-23 | Ratified-spec iteration: ADR-00y scope extended to explicitly ratify the monitoring pull-scrape flow (60→40/45) | Step 2 ratified task spec (final) |
