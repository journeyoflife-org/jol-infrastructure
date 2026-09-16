# Fleet VLAN Audit — 2026-08-29

> **Scope**: MikroTik RB5009 (inter-VLAN router) + Dell N2048 (access switch)
> — full VLAN scheme per `dell-n2048-port-table.md` §1.
>
> **Compliance**: SOC 2 Type II (CC7.2 evidence) / GDPR Art. 32 / ISO 27001:2022 A.8.20.
>
> **⚠ NO CREDENTIALS in this document. Vaultwarden only.**
>
> **Evidence**: `docs/compliance/evidence/execution/vlan-audit-20260829/`
> (01 ICMP ladder, 02 service probes, 04a/b/c MikroTik read-only captures).
>
> **Method**: read-only from admin01 (10.10.10.50). Zero configuration changes made.
> N2048 CLI audit BLOCKED (see F2) — switch-side claims marked ⚠ UNVERIFIED.

---

## 0. Executive Summary

| Verdict | Detail |
|---------|--------|
| Router plane | **HEALTHY** — all 8 live SVIs (vlan10–vlan80) answer, uptime 5d16h+, clock correct |
| Inter-VLAN reachability | Gateways of VLAN 10/20/30/50/60/70 reachable; hosts in 30/60/10 reachable |
| **VLAN 40 (AI Services)** | **RESTORED 2026-08-29 ~17:50Z (F1 resolved).** Root cause = Gi1/0/6 **uncabled**; CAT6 patch reinstalled pve nic0 ↔ Gi1/0/6 → 1 Gbps FD, all 3 VMs answering, RAG `/ready` green, MCP stdio gate PASS. Evidence: `…/vlan-audit-20260829/05-f1-resolution.txt` |
| VLAN 85 / 90 | No SVI on the router (10.85.85.1 / 10.90.90.1 dead) — planned segments, not yet routed |
| N2048 switch config | ⚠ UNVERIFIED — supplied admin password rejected (2/2 attempts, then STOPPED per anti-brute-force policy); consistent with the documented 2026-08-08 rotation |
| 10.60.60.10 claim | **REFUTED live** — prox01 answers ICMP at 0.65 ms (see F7) |

**Professional opinion on the "10.60.60.10 returns 100% packet loss" statement**:
it was TRUE during INC-20260823 (2026-08-23→25, routing plane dead) and is
STALE now. The audit that produced it could not have been completed then; it
CAN be completed now — and it surfaced a different, currently-live outage
(F1, VLAN 40 L2 isolation). Any gate report still citing the packet-loss
statement must be re-run against the 2026-08-29 evidence below.

---

## 1. Reachability ladder (2026-08-29 14:37–14:40Z, from admin01)

| Target | Role | Result |
|--------|------|--------|
| 10.10.10.1 | MikroTik VLAN 10 SVI | UP 0.36 ms |
| 10.10.10.2 | N2048 mgmt | UP 0.73 ms |
| 10.10.10.11 | iDRAC prox01 | UP 0.28 ms |
| 10.10.10.30 | pbs01 | UP 0.20 ms |
| 10.20.20.1 | VLAN 20 SVI | UP 0.31 ms |
| 10.30.30.1 / .10 | VLAN 30 SVI / llm-prod-lt01 | UP / UP (Ollama 0.32.6 answers on :11434, SSH banner OK) |
| 10.40.40.1 | VLAN 40 SVI | UP 0.35 ms |
| 10.40.40.10 / .11 / .12 | rag / mcp / her VMs | **100 % loss — router ARP `failed` (F1)** |
| 10.50.50.1 | VLAN 50 SVI | UP 0.36 ms |
| 10.60.60.1 / .10 / .20 | VLAN 60 SVI / prox01 / pve-prod-hv01 | UP / UP 0.65 ms / UP (SSH :22 open) |
| 10.70.70.1 | VLAN 70 SVI | UP 0.37 ms |
| 10.85.85.1 / 10.90.90.1 | VLAN 85/90 gateways | dead — no SVI on router (F4) |
| 192.168.88.1 | router emergency bridge | UP 0.27 ms |

Router ARP table corroborates: `10.40.40.10/11/12 … vlan40 failed`;
every other trunk-side neighbor resolves.

---

## 2. MikroTik RB5009 — read-only capture (auth OK, credentials per operator)

- **Identity/resource**: RB5009UG+S+, RouterOS **7.19.6 stable**, uptime
  5d16h48m ⇒ last boot ≈ **2026-08-24 ~00:57 EEST** (see F6 on the timeline
  discrepancy). CPU 0 %, 878 MiB free RAM.
- **Clock**: 2026-08-29 17:44 Europe/Vilnius, DST active — **correct now**,
  but NTP client `enabled: no` (F5) ⇒ will drift again after any reboot.
- **SVIs**: vlan10 MGMT, vlan20 WORK, vlan30 LLM, vlan40 BACKEND, vlan50
  MARKET, vlan60 PROXMOX, vlan70 STORAGE, **vlan80 HOME/IoT** + defconf
  bridge 192.168.88.1/24 + WAN 192.168.32.2/24 (dynamic). All `R`.
  **No vlan85 / vlan90 SVI.**
- **Trunk**: ether2 (D0:EA:11:4B:67:A0) is `RS`, bridge1 member, VLANs
  10–70 tagged on ether2; vlan80 untagged via ether3 (WR841N home/IoT).
  ⇒ **The INC-20260823 "MOVE TRUNK to Gi1/0/1" action was never executed**;
  the trunk still runs ether2 ↔ Gi1/0/48 and is currently passing traffic.
- **Firewall** (30 rules): defconf base + custom inter-VLAN matrix:
  vlan10 full forward access; vlan20 → 30/40/50/60; vlan60 → vlan70 and
  vlan10:8007 (PBS); vlan40 → vlan70; vlan70 sourced traffic dropped;
  bridge1→bridge1 default drop. Rule 1 "temp allow ping" (input ICMP) is a
  leftover; rule 16 "INPUT: default drop" is **disabled (X)** (F3).
- **Services**: ftp 21, ssh 22, **telnet 23**, www 80, winbox 8291, api 8728,
  api-ssl 8729 — **no REMOTE address restriction on any of them** ⇒ reachable
  from every LAN VLAN (F3). www-ssl disabled.
- **History**: `/system history print` EMPTY — no config edits since boot.

## 3. Dell N2048 — ⚠ UNVERIFIED (F2)

Two auth attempts with the operator-supplied password both failed
(`Permission denied`). Per the 2-attempt anti-brute-force policy
(INC-20260823 runbook; INC-2026-0814 burned attempts on a wrong pairing)
**no further attempts were made**. This is consistent with the documented
2026-08-08 admin-password rotation (issue #26). The switch itself is UP
(10.10.10.2 answers, 0.73 ms). The following switch-side facts are therefore
EXPECTED from documentation but **not live-verified**:

- Gi1/0/6 state — **critical for F1 root cause** (access vlan 40,
  port-security `maximum 1 / violation shutdown` armed 2026-08-08; a
  violation-shutdown or cable fault there exactly explains nic0 NO-CARRIER).
- Trunk status on Gi1/0/48 (and whether Gi1/0/1 was ever re-armed).
- VLAN database: 2026-07-31 running-config carried phantom VLANs 13–16 and
  vlan80, and no vlan90 (F4).

## 4. pve-prod-hv01 (via SSH key, jol-admin@10.60.60.20)

- `qm list`: **100 rag-prod-lt01, 101 mcp-prod-lt01, 102 her-prod-lt01 — all RUNNING.**
- `ip -br link`: nic1 UP (vmbr0, VLAN 60 — healthy); **nic0 DOWN, NO-CARRIER**
  (vmbr1 bridge-ports nic0 — config correct per `/etc/network/interfaces`).
- `ethtool nic0`: Link detected: no. Host uptime 22 days (no reboot since).

---

## 5. Findings

| # | Sev | Finding | Standard |
|---|-----|---------|----------|
| **F1** | ~~HIGH~~ **RESOLVED 2026-08-29** | VLAN 40 was isolated at L2: **Gi1/0/6 had no cable at all** (operator physical inspection). Fix: CAT6 patch pve nic0 (Killer E2500, `1c:1b:0d:9f:4e:a6`, driver `alx`) ↔ Gi1/0/6. Verified: nic0 LOWER_UP 1000 FD; 10.40.40.10/11/12 0 % loss; RAG `/health`+`/ready` green (qdrant/minio/ollama up); jol-git-server stdio handshake + tools/list OK (mcp 1.29.0); router ARP vlan40 `failed` → `reachable`. **No switch config was needed; port-security accepted the documented MAC.** Follow-up: cable-management/labelling so Gi1/0/6 cannot silently come unplugged again | SOC 2 A1.1, GDPR Art. 32 availability |
| **F2** | **HIGH (credential hygiene)** | Supplied MikroTik password **still valid** ⇒ never rotated or re-set after prior exposure (it also appeared in plaintext outside Vaultwarden). Supplied N2048 password rejected ⇒ confirm the rotated value lives in Vaultwarden; operator knowledge has drifted | SOC 2 CC6.1, GDPR Art. 32, ISO A.10.1.2 |
| **F3** | MEDIUM | Router mgmt plane over-exposed: telnet+ftp enabled; winbox/api/www/ssh have no REMOTE restriction (any LAN VLAN can reach them); input default-drop rule disabled; "temp allow ping" leftover | SOC 2 CC6.1, CIS |
| **F4** | MEDIUM | VLAN scheme drift: vlan80 HOME-IoT live but absent from port-table §1; VLAN 85/90 gateways not on the router; switch (2026-07-31) had phantom VLANs 13–16 and no vlan90 | doc-as-truth, ADR-004 |
| **F5** | MEDIUM | NTP client disabled on the router (INC-2026-0814 G8; queued-unfixed in INC-20260823). Clock correct only by manual set | SOC 2 CC7.2, NIST 800-53 AU-8 |
| **F6** | LOW | INC-20260823 never formally closed: uptime implies boot 2026-08-24 ~00:57 EEST but the timeline labels the graceful reboot 2026-08-25 00:54 EEST (24 h clock-confusion mislabel); trunk-move action ended unexecuted; recovery path undocumented | SOC 2 CC7.2 evidence integrity |
| **F7** | LOW | The "10.60.60.10 100 % packet loss" statement is stale — refuted by today's ladder (0.65 ms). It was true only during INC-20260823 | verification rule §0.4 |
| **F8** | ~~HIGH~~ **RESOLVED 2026-08-29** | pve nic1 ↔ Gi1/0/5 (VLAN 60 hypervisor mgmt) was stuck at 100 Mb/s (dmesg SmartSpeed downgrade = degraded cable). **Fix**: operator-made CAT6 patch (CAT6 plugs) installed; verified: 1000 Mb/s FD re-negotiated, NO new SmartSpeed event, ethtool error/CRC/drop counters ALL ZERO, ICMP 20/20, sustained 765 Mbit/s (100 MB scp, VLAN 60→10 routed path, incl. SSH overhead). Port PHY exonerated — fault was the cable | SOC 2 A1.1 |
| **F9** | MEDIUM | Cable walk completed 2026-08-29 (operator): pbs01 LAN1 CAT6 / LAN2 CAT5 (Gi1/0/22, VLAN 70 iSCSI) — **RESOLVED 2026-08-29**: CAT6 installed, verified nic1 1000 FD + 0 errors + live with 10.70.70.10; drift corrected: active VLAN 70 NIC physically sits on Gi1/0/22, Gi1/0/21 is NOT cabled (port-table updated); prox01 Gi1/0/11 CAT6 (healthy); prox01 iDRAC Gi1/0/40 CAT5 — **RESOLVED 2026-08-29**: CAT6 installed, verified ICMP 15/15 @1/s (0 % loss; the 55 % loss at 5/s is iDRAC ICMP rate-limiting, not cable), SSH+Redfish 8/8 HTTP 200 stable; llm-prod-lt01 Gi1/0/4 CAT5 — **RESOLVED 2026-08-29**: operator-made CAT6 installed, verified 1000 FD + zero error counters + Ollama/SSH gates green. Gi1/0/48↔ether2 trunk installed-cable identity still ambiguous (INC-20260823). **Order issued: 9× CAT6 + 1× CAT6a (trunk)**; R740-fleet cables deferred to hardware arrival | doc-as-truth |

---

## 6. Remediation plan (change-controlled per AGENTS §0.3)

> Every step: GitHub Issue (`.github/ISSUE_TEMPLATE/infra-change-request.yml`)
> + rollback line + CHANGELOG row. Wave 1 executed as a physical restoration
> of documented cabling (no config mutation); Waves 2–3 NOT executed.

### Wave 1 — restore VLAN 40 (P1) — ✅ EXECUTED & VERIFIED 2026-08-29 ~17:50Z

Executed branch: **physical — port was uncabled** (operator on-site). CAT6
patch installed pve nic0 ↔ Gi1/0/6. Full verification ladder PASSED
(evidence `05-f1-resolution.txt`):

```text
pve:     ip -br link nic0              → LOWER_UP, 1000Mb/s Full, Link detected: yes   ✔
admin01: ping 10.40.40.10/.11/.12      → 0 % loss                                      ✔
admin01: curl RAG /health && /ready    → healthy; qdrant/minio/ollama up               ✔
MCP:     stdio initialize+tools/list via qm guest exec 101 → jol-git-server 1.29.0     ✔
router:  /ip arp print                 → vlan40 entries reachable (was: failed)        ✔
switch:  port-security accepted MAC 1C1B.0D9F.4EA6 (no config change needed)           ✔
```

Remaining from this wave: **cable labelling/strain relief** on Gi1/0/5–Gi1/0/6
(prevent silent recurrence) — physical housekeeping, no change request needed.

### Wave 2 — credential + mgmt-plane hardening (P2, logged changes)

1. **Rotate MikroTik admin password** (exposed value must die); new value →
   Vaultwarden only. Verify the N2048 item pairing while there.
2. Router services: `/ip service disable telnet,ftp,www`; set
   `address=10.10.10.0/24,192.168.88.0/24` on ssh/winbox/api(-ssl);
   delete rule 1 ("temp allow ping"); re-enable input default-drop (rule 16)
   AFTER confirming rules 2–15 cover all needed input paths.
   Rollback: per-rule re-enable from the captured `/ip firewall filter print`.
3. Enable NTP: servers `lt.pool.ntp.org,pool.ntp.org`,
   `time-zone-name=Europe/Vilnius`; verify `status: synchronized`.

### Wave 3 — documentation & closure (P3)

1. Close INC-20260823: append corrected timeline (real reboot ≈ 2026-08-24
   00:57 EEST), actual recovery path, postmortem per runbook Step 7.
2. Reconcile `dell-n2048-port-table.md` §1: decide vlan80 (document or
   remove), add VLAN 85/90 SVIs when the backup/DR segments are cabled
   (pbs02 / pbs-jol01), remove phantom 13–16 from the switch during the
   next console window.
3. G6 escalation unchanged: second router outage + today's VLAN 40 isolation
   both reinforce the cold-standby RB5009 condition for pilot go-live.

---

## 7. What this audit did NOT do

- No configuration change on any device (read-only by design).
- No switch CLI capture — blocked at auth (F2); switch-side state of
  Gi1/0/6, Gi1/0/48 and the VLAN DB remains ⚠ UNVERIFIED.
- No `qm guest exec` gates on the VLAN 40 VMs — impossible while F1 stands.
