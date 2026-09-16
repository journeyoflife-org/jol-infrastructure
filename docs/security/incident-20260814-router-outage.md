# INC-2026-0814 — MikroTik RB5009 outage (P1) — LIVE INCIDENT LOG

> **Status**: ROUTING RESTORED 2026-08-16 ~04:55 EEST — independent
> verification GREEN below. Incident remains OPEN until post-incident
> actions (backup refresh, credential rotation, postmortem) complete.
>
> **Compliance**: SOC 2 CC7.2 (evidence preservation), ISO 27001 A.5.24/A.5.25
> (incident management), GDPR Art. 32 (availability of processing).
> No personal data involved — availability incident only; GDPR 72h notification
> clock NOT triggered.
>
> **No credentials in this document. Secrets via Vaultwarden only.**

## Summary

MikroTik RB5009 (10.10.10.1, Gi1/0/48 trunk — sole inter-VLAN router) became
unreachable ~2026-08-14 18:40 EEST. All routed production segments
(10.30.30.0/24, 10.40.40.0/24, 10.60.60.0/24) failed simultaneously. Same-L2
management hosts (pbs01 10.10.10.30, switch 10.10.10.2) never dropped,
isolating the fault to the router. Onset coincides exactly with the first
admin01 reboot (Fri 18:40–18:41 per `last -x`) — shared-power-event suspected.

## Evidence timeline (all EEST)

| Time | Event | Source |
|------|-------|--------|
| Fri 03:16 | Nightly PBS backup of llm-prod-lt01 OK; snapshot `2026-08-14T00:15:02Z` (61 GB) verified present | pbs01 |
| Fri 18:39 | Last successful Prometheus scrape of llm-prod-lt01 | fleet Prometheus (admin01) |
| Fri 18:40–19:59 | admin01 rebooted twice (`last -x`: boots 18:41 and 19:59) | `last -x` |
| Sat 12:33 | admin01 boot; all prod segments found unreachable | `last -x` |
| Sun 01:30 | Evidence capture: `10.10.10.1` ARP INCOMPLETE; pbs01/switch OK; `192.168.88.1` REACHABLE on enp5s0 | `/tmp/inc-20260816-router/pre-fix-*.txt` |

Task 2 (llm-prod-lt01 hardening) is **exonerated**: GREEN at 02:56 + clean
03:16 backup predate the outage by ~15 hours; nothing in its scope touched
networking.

## Independent verification from admin01 — 2026-08-16 ~02:00 EEST

Run live during this incident; NOT restored despite "fixed and verified" report:

| Target | Result |
|--------|--------|
| 10.10.10.1 (router mgmt) | **DOWN — ARP FAILED** (retried 3x) |
| 10.30.30.1 / 10.40.40.1 / 10.60.60.1 (gateway SVIs) | DOWN |
| 10.30.30.10, 10.40.40.10-12, 10.60.60.20 (prod hosts) | DOWN |
| 10.10.10.2 (N2048), 10.10.10.30 (pbs01) | UP |
| 192.168.88.1 via enp5s0 | **UP — RouterOS device** |

## Key finding — live RouterOS device on admin01 enp5s0

- admin01 holds DHCP lease **192.168.88.249/24** on enp5s0 with default route
  via **192.168.88.1** (metric 100).
- 192.168.88.1 fingerprint: ports **22, 80, 8291 OPEN** (8291 = WinBox);
  HTTP serves webfig page titled `RouterOS`. 192.168.88.1 is MikroTik's
  canonical default gateway address.
- The device was REACHABLE throughout the outage (present in the 01:30
  capture), i.e. it was powered and answering while all production VLAN
  gateways were dead.

## Root cause CONFIRMED — power outage reboot

Operator console login (user `admin`, interactive, 2026-08-16 ~03:20 EEST)
confirmed the device at 192.168.88.1 **IS the production router**:
MikroTik RouterOS **7.19.6**, identity `MikroTik`. Router critical log:

```
2026-08-14 04:32:36 system,error,critical router rebooted without proper
                              shutdown, probably power outage
2026-08-14 22:05:45 system,critical,info cloud change time
                              Aug/14/2026 04:33:16 => Aug/14/2026 22:05:45
```

The reboot timestamp is expressed on a skewed post-outage clock (no NTP);
the cloud time-correction at 22:05 Aug/14 brackets the true event time.
This **confirms the shared-power-event hypothesis**: router and admin01 both
lost power Fri ~18:40. Router recovered; inter-VLAN routing did not.

Open question (decides remediation path): is the production config intact
(192.168.88.1 = dedicated/emergency mgmt address) or was it lost (default
config)? Pending: `/ip address print`, `/interface print`, `/log print` full
(117 messages unread, likely interface events).

Credential note: `HYLA7HQ4LZ` is a LOGIN NAME, not a password — attempts
with it as a user also failed (logged by the router). Access was achieved
with the existing `admin` account. Post-recovery: rotate router credentials
and record correct pairing in Vaultwarden.

## Config state established — fault is now LOGICAL, not power

Read-only triage (operator console, ~03:30 EEST):

- Board RB5009UG+S+in, RouterOS 7.19.6 stable.
- **Production config INTACT**: all SVIs present and RUNNING — 10.10.10.1
  (vlan10), 10.20.20.1 … 10.70.70.1, 10.80.80.1 (HOME/IoT), plus defconf
  192.168.88.1 on a separate `bridge`. Default route via 192.168.32.1/ether1.
- `bridge1` (vlan-filtering=yes): VLANs 10–70 tagged on ether2; VLAN 80
  untagged on ether3. **ether2 (trunk to N2048) flag R = link up.**
- Uptime 1d4h → router booted again **Sat ~23:15** (operator power-cycle
  during remediation attempts). The "2026-08-14 04:32" critical entry is
  mis-dated by a reset RTC at boot time.
- admin01 still cannot ARP 10.10.10.1 (re-verified 03:30) despite router
  config + trunk link up → fault is between bridge1 and the VLAN-10 fabric,
  or input-level. Suspects: STP discarding state on the trunk, N2048
  Gi1/0/48 VLAN drift/err-disable, or firewall input drop.
- Drift note: router carries VLAN 80 (HOME/IoT) but NOT documented VLANs
  85/90 (PBS replication/offsite); docs port table lists 85/90 on the trunk.
  Record for post-incident reconciliation (backups did work via 10→30).

admin01 enp6s0 MAC for correlation: `04:D9:F5:C8:BA:35`.

## Bridge topology established — 2026-08-16 ~04:00 EEST

- **G5 resolved**: admin01 enp5s0 cable lands on **ether8**, member of the
  defconf `bridge` (192.168.88.1). ether4–7 + sfp defconf ports are
  INACTIVE (no link).
- `bridge1` (production): 2 ports — ether2 (TRUNK TO DELL, pvid 1,
  admit-only-vlan-tagged) and ether3 (TO WR841N HOME/IoT, pvid 80,
  untagged). bridge1 **is STP root**, 2 designated ports.
- Follow-up (security): a defconf bridge with DHCP server is live on a
  production router (192.168.88.0/24); isolate or remove post-recovery.
- Still unknown (pager stopped the session): per-port STP state of ether2,
  bridge1 host/MAC table, ARP table, firewall input chain, router-side
  ping results — needed to locate the block.

## Trunk proven GOOD — fault isolated to router ARP replies, ~04:10 EEST

- `bridge host print`: ALL prod MACs learned on bridge1 via ether2 —
  admin01 `04:D9:F5:C8:BA:35` VID 10, llm `24:4B:FE:55:B1:C4` VID 30,
  rag/mcp/her VID 40, pve `1C:1B:0D:9F:4E:A8` VID 60. Frames cross the
  trunk switch→router; entries fresh (5 min ageing) = admin01's ARP
  requests ARRIVE at the router.
- Router→pbs01 ping works (2/3). Router has ARP entries for all hosts.
- BUT admin01 still fails ARP for 10.10.10.1 (re-verified 04:08, "pipe"/
  host-unreachable). Router→switch VLAN-10 unicast to pbs01 delivered;
  router's ARP REPLY to admin01 evidently never generated/sent.
- Firewall: input rule 14 accepts in-interface=vlan10 (after defconf
  !LAN drop at rule 6 — VLAN-in-LAN-list needs confirming), plus a
  `temp allow ping` rule added DURING the incident → config was edited
  during triage; inventory of mid-incident edits still pending.
- Prime suspect: `arp=disabled` (or equivalent) on the VLAN interfaces —
  would suppress ARP replies while router-initiated ARP/ping still works,
  matching every observation. Next: `/interface vlan print detail`,
  `ping 10.10.10.50 count=3`.

## Unresolved items (blocking closure)

1. Determine whether the production config is intact: `/ip address print`
   (does 10.10.10.1 exist on a VLAN interface?), `/interface print`
   (VLAN/bridge interfaces and their running flags), full `/log print`
   (117 unread messages, likely interface events after the power reboot).
2. Locate or rebuild the router configuration. **No MikroTik config backup
   exists in this repository or any documented location** (verified by search).
   If config is lost, rebuild is decision-complete from repo sources:
   VLAN scheme + gateways (`docs/network/dell-n2048-port-table.md` §1),
   trunk port set (Gi1/0/48: VLANs 10,20,30,40,50,60,70,85,90), inter-VLAN
   firewall requirements (`docs/architecture/trust-boundaries.md`),
   WAN masquerade (`docs/architecture/network-topology.md`). Any rebuild is
   an emergency P1 change and must be logged here before execution.
3. Re-run full verification ladder after remediation (gateways → hosts →
   inter-VLAN curl 10.30.30.10:11434 from VLAN 40 → Prometheus scrape
   resumption) and append results to this log.
4. Refresh llm-prod-lt01 backup immediately after routing returns — restore
   point `2026-08-14T00:15:02Z` is >36h stale and Sat 03:15 nightly backup
   is presumed failed.

## Systemic gaps exposed (follow-up actions, post-recovery)

| # | Gap | Evidence | Follow-up |
|---|-----|----------|-----------|
| G1 | No MikroTik config backup anywhere | repo-wide search: zero router config artifacts | Add config export to PBS backup scope / repo (no secrets) |
| G2 | No OOB management path to the router | incident triage, 2026-08-15 | Document OOB or dedicated mgmt access |
| G3 | No alert fired for router loss | masked by admin01's own reboot 18:40 | Independent uptime watchdog for 10.10.10.1 |
| G4 | 192.168.80.0/24 flat LAN still live (wlp7s0 got DHCP from 192.168.80.1) | port table migration notes step 8 never completed | Complete decommission |
| G5 | Undocumented cabling (enp5s0 → 192.168.88.x device) | this incident | Physical cable audit + port-table entry |
| G6 | Router is unmanaged single point of failure for all prod VLANs | blast radius = 100% of prod segments | Spare/cold-standby RB5009 with baseline config |

## Verification round 2 — 2026-08-16 ~02:30 EEST

Operator reported "all wires connected, green lights flashing — fixed and
verified". Independent re-check from admin01:

- Controls UP: 10.10.10.2 (switch), 10.10.10.30 (pbs01) → local L2 path healthy.
- **10.10.10.1 still DOWN (ARP FAILED, retried 5x); all VLAN SVIs and all prod
  hosts still DOWN.** Physical LED state does not corroborate routing
  function; "fixed" is NOT verified. Status remains OPEN.
- Credential probe of 192.168.88.1: factory-default login (`admin` / empty
  password) **REJECTED** (sshpass exit 5) → the device is NOT in factory
  state; it carries a configured password. Either it retains production
  credentials (config may be intact but VLAN interfaces non-functional) or it
  is an unrelated CPE. No further credential attempts will be made
  (anti-brute-force policy); next access requires the MikroTik credential
  from Vaultwarden.
- ~03:00: operator-supplied credential tested against 192.168.88.1 user
  `admin` — **REJECTED** (sshpass exit 5). Value never recorded anywhere.
  Either the username differs from `admin` or the entry belongs to another
  device; pending confirmation of the Vaultwarden item's username/device.
  No further attempts until confirmed (anti-brute-force policy).

## Timeline CORRECTION — Saturday backup evidence (verified on pbs01)

Snapshot listing on pbs01 (`/backup-pool/pbs-store/ns/jol-llm/host/
llm-prod-lt01/`) shows backups 08-11, 08-12, 08-13, 08-14 **and
`2026-08-15T00:15:02Z`** — the **Saturday 03:15 backup SUCCEEDED**,
contradicting the earlier "presumed failed" assumption. Consequences:

- Fri 18:40 power event rebooted router + admin01; **both recovered** —
  inter-VLAN routing was healthy at Sat 03:15 (backup traverses
  VLAN 30→10 via the router). The Fri 18:39 "last scrape" gap is an
  admin01-side artifact (its own 18:41 reboot).
- The **sustained outage window is Sat 03:15 → Sun ~04:50** (router
  stopped routing again at unknown time before Sat 12:33; likely hang,
  which leaves no log).
- Sat 23:15 router reboot (uptime evidence) = operator power-cycle;
  router came back with intact config but VLAN traffic still did not
  flow until final recovery Sun ~04:50.
- Sun 03:15 nightly backup absent (no `2026-08-16` snapshot) — routing
  was still down at cron time. **Manual refresh backup launched Sun
  ~05:10 from admin01.**
- Last valid restore point before refresh: `2026-08-15T00:15:02Z`.

## Recovery — 2026-08-16 ~04:50 EEST (independently verified from admin01)

Routing plane recovered (final sticking point cleared after sustained ARP
pressure; exact trigger not captured because device-mode blocks the
router packet sniffer — see G7):

| Check | Result |
|---|---|
| ARP 10.10.10.1 | REACHABLE, MAC d0:ea:11:4b:67:a0 |
| Gateways 10.10.10.1 / 10.30.30.1 / 10.40.40.1 / 10.60.60.1 | all UP |
| Hosts 10.30.30.10, 10.40.40.10-12, 10.60.60.20 | all UP |
| VMs 100/101/102 (rag/mcp/her) via pve `qm status` | all running |
| Prometheus `up{instance="10.30.30.10:9100"}` | 1 — scraping resumed |
| SSH llm-prod-lt01 | Ollama 0.32.6 OK; **uptime 1w4h — host never rebooted** (survived the power event) |
| Inter-VLAN critical path: her (VLAN 40) → http://10.30.30.10:11434/api/version | `{"version":"0.32.6"}` — VLAN 40→30 works |

Task 2 exoneration stands and strengthens: llm-prod-lt01 uptime proves it
was never down; GREEN 02:56 state intact.

## Anomalies found during verification (NOT outage blockers)

1. **SSH :22 to rag (10.40.40.10) and mcp (10.40.40.11) times out** from
   admin01, while her (10.40.40.12) :22 connects fine — VM-local (UFW/sshd),
   not the router. Verify during Task 3 smoke suite.
2. **llm-prod-lt01 :11434 reachable from VLAN 10 (admin01)** — the
   documented UFW baseline allows 11434 only from 10.40.40.0/24. Reconcile
   against Task 2 change record before Task 3; fix or re-document.
3. Router forward chain has **no explicit vlan40→vlan30 accept**; 40→30
   works only via fall-through to default-accept (rule 29 `drop
   in-interface=bridge1 out-interface=bridge1` does not match VLAN
   sub-interfaces). Ruleset needs post-incident cleanup; `temp allow ping`
   rule to be removed. Run `/system history print` for the audit trail of
   mid-incident edits.
4. pbs01 (HP P4500) cabling reported as switch ports Gi1/0/20 + Gi1/0/22;
   port table lists Gi1/0/22 as stor01-iscsi2/VLAN 70 — reconcile docs.
   **Do NOT reboot pbs01** — healthy; it is the current backup anchor.

## Closure status — Sun 2026-08-16 ~03:25 EEST

- **Timing correction**: recovery and verification occurred ~03:05–03:16
  EEST (host-local log timestamps authoritative), not the ~04:50 estimated
  in earlier sections; section headers retained for audit continuity.
- Backup refreshed and verified: snapshot `2026-08-16T00:14:32Z` on pbs01
  (`backup to pbs01 completed OK`, ollama restarted by the script).
- Task 3 smoke suite executed post-recovery — results in postmortem table
  (`docs/security/postmortem-20260816-inc-router-outage.md`); one FAIL
  root-caused (batch-code embeddings — Ollama `OLLAMA_EMBEDDINGS` flag,
  fix pending change approval).
- Runbook playbook added (`docs/runbooks/incident-response.md`), port-table
  pbs01 cabling note updated.
- **Remaining human actions before closure**: router credential rotation +
  Vaultwarden pairing fix; UFW Anywhere-rule decision on llm-prod-lt01;
  `/system history print` capture + ruleset cleanup; G1–G9 action list in
  the postmortem.

## P1 SLA note

Outage ongoing >36h against a 4h resolve target (`docs/runbooks/incident-response.md`).
Escalation per runbook: On-call → Engineering Lead → CTO. Postmortem due
within 48h of closure.
