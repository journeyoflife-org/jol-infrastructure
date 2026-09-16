# INC-20260823 — MikroTik RB5009 routing outage (P1) — LIVE INCIDENT LOG

> **Status**: OPEN — fault confirmed LOGICAL (router powered, all links up,
> inter-VLAN routing dead). Remediation plan below; human-credential console
> access is the next gate.
> **Severity**: P1 — all routed production segments unreachable
> (15 min ack / 4 h resolve target per `docs/runbooks/incident-response.md`;
> INC-2026-0814 precedent exceeded 36 h — treat the SLA seriously).
> **GDPR**: availability incident only — no personal-data compromise
> indicator; 72 h notification clock NOT triggered (re-assess if facts change).
> **Compliance**: SOC 2 CC7.2 evidence preservation; ISO 27001:2022
> A.5.24/A.5.25 incident management; GDPR Art. 32 availability.
> **No credentials in this document. Vaultwarden only.**

## Confirmed state (fixed & verified, 2026-08-23)

**Remote probe from admin01** (evidence:
`docs/compliance/evidence/execution/p0/prox01-reachability-probe-20260823-2026.txt`):

| Target | Result |
|--------|--------|
| 192.168.88.1 (router emergency mgmt, ether8 bridge) | **UP, 0.3 ms** — router powered & running |
| 10.10.10.11 (iDRAC, VLAN 10 local) | UP — local L2 fabric healthy |
| 10.60.60.1 / .10 / .20 (VLAN 60) | No route to host |
| 10.40.40.10 (VLAN 40) | No route to host |

**Physical inspection** (operator, 2026-08-24 ~00:10 EEST):

| Port | Observed | Meaning |
|------|----------|---------|
| ether1 (WAN → CPE 192.168.32.1) | green + blinking | link up, traffic flowing |
| ether2 (trunk → N2048 Gi1/0/48) | green + blinking | trunk link up |
| ether8 (admin01 mgmt) | green | emergency path live |

**Conclusion**: not power, not cabling — **logical fault in the routing
plane**. Identical signature to INC-2026-0814 ("Config state established —
fault is now LOGICAL, not power"), where the trunk was GOOD and the router's
own ARP/forwarding state was stuck after an unclean power event.

**Second occurrence**: this is the second total-loss of the single RB5009
(G6, first: INC-2026-0814). Directly strengthens the ADR-004 amendment
condition: no pilot DMZ go-live without the cold-standby router baseline.

## Remediation plan (in order; deviations require logged justification)

### Step 1 — Preserve evidence (do FIRST, before any console work)

```bash
mkdir -p /tmp/inc-20260823-router
date; last -x | head -5; ip neigh
for t in 10.10.10.1 10.30.30.1 10.40.40.1 10.60.60.1 10.60.60.10 10.40.40.10; do
  ping -c 2 -W 2 $t; done > /tmp/inc-20260823-router/pre-fix-ladder.txt 2>&1
```
Never delete anything; this directory joins the incident evidence.

### Step 2 — Console access (HUMAN GATE)

- Path: admin01 → **192.168.88.1** (SSH 22 / webfig 80 / WinBox 8291).
- Credentials: **Vaultwarden only**. Anti-brute-force: max 2 attempts;
  if rejected, STOP and verify the Vaultwarden item's username/device
  (INC-2026-0814 burned attempts on a wrong pairing — every failure is
  logged by the router).
- Record in this log: who logged in, when, from where.

### Step 3 — Read-only triage on the router (exact playbook order)

```
/system resource print        → uptime = when it last rebooted (power event?)
/log print                    → "rebooted without proper shutdown" = power event
/ip address print             → SVIs present? (10.10.10.1 … 10.60.60.1)
/interface print              → ether2/trunk R-flag?
/interface bridge host print  → host MACs learned via ether2? (fresh 5-min ageing = requests arrive)
/ip arp print                 → ARP table state
```

### Step 4 — Interpretation branch (decides the fix)

| Finding | Diagnosis | Fix |
|---------|-----------|-----|
| SVIs MISSING | Config lost | Rebuild from `docs/network/dell-n2048-port-table.md` §1 + `docs/architecture/trust-boundaries.md` — logged EMERGENCY change first |
| SVIs present + trunk R + MACs learned, but no ARP replies/forwarding | **Stuck forwarding state** (INC-2026-0814 pattern — most likely today) | Step 5 |

### Step 5 — Remediation (verified prior art, gentlest first)

1. **Sustained ARP/ICMP pressure**: ping all SVIs from admin01
   continuously (`for i in $(seq 1 300); do for t in 10.10.10.1 10.30.30.1
   10.40.40.1 10.60.60.1; do ping -c1 -W1 $t >/dev/null; done; sleep 1; done`)
   — this is what finally cleared INC-2026-0814. Log start/stop times.
2. **If still dead after ≥10 min**: bounce the bridge port as a LOGGED
   change (HUMAN approval): `/interface bridge port set [find interface=ether2]
   disabled=yes` → 10 s → `disabled=no`.
3. **Only if 1–2 fail**: power-cycle the router as a logged change
   (last resort; config is intact per Step 3 or already rebuilt).

### Step 6 — Verification ladder (run in full; evidence captured)

| # | Check | Expected |
|---|-------|----------|
| 1 | `ping 10.10.10.1` + all SVIs (.30/.40/.60 gateways) | reachable |
| 2 | `ping 10.60.60.20`, `10.60.60.10`, `10.30.30.10`, `10.40.40.10-12` | reachable |
| 3 | SSH smoke: `ssh pve hostname` | answers |
| 4 | Inter-VLAN critical path: `curl -sf http://10.30.30.10:11434/api/version` from a VLAN 40 host | version JSON |
| 5 | Missed nightly backups? Check pbs01 for today's snapshots; refresh manually if absent | snapshot present |
| 6 | **Phase 0 D1 unblocked**: run `lscpu`, `free -h`, `ip -br link` on prox01; racadm via interactive iDRAC | capacity baseline promoted from DRAFT |

### Step 7 — Post-incident (mandatory)

- [ ] Rotate any credential used in the console session; fix Vaultwarden pairing
- [ ] `/system history print` captured (audit of mid-incident edits); remove any temp rules
- [ ] Postmortem within 48 h of closure (`docs/security/postmortem-<date>-…`)
- [ ] G1 (router config export to PBS/repo) + G6 (cold-standby RB5009) escalated — second occurrence makes both blocking for pilot go-live (ADR-004 amendment conditions)
- [ ] Append closure evidence to this log; CHANGELOG row on close

## Prohibited during this incident

- Rebooting or cable-tugging BEFORE Step 3 triage (destroys fault state)
- Credential guessing beyond the 2-attempt cap
- Declaring "fixed" on LED state alone — INC-2026-0814 round 2 proved LEDs
  do not corroborate routing; only the Step 6 ladder closes the incident

## Timeline (Europe/Vilnius time — EEST (UTC+3) in summer; raw evidence files keep UTC `Z` stamps)

| Time (EEST) | Event | Source |
|-------------|-------|--------|
| 2026-08-23 ~23:25 | Outage detected during Phase 0 execution — VLAN 60/40 unreachable, VLAN 10 alive | admin01 probe (evidence ref above) |
| 2026-08-24 ~00:10 | Physical inspection: ether1/ether2/ether8 all green — logical fault confirmed | operator report |
| 2026-08-23 23:53 | Scope check closes the diagnosis per runbook step 2: controls UP (switch 10.10.10.2, pbs01 10.10.10.30), router SVI 10.10.10.1 ARP **FAILED**, all other SVIs dead, emergency bridge 192.168.88.1 UP → **router fault, ARP-reply suppression signature (INC-2026-0814 match)**. Next gate: console triage (Step 3) | `/tmp/inc-20260823-router/scope-check-205356.txt` |
| 2026-08-23 23:57 | Step 5.1 remediation RUNNING (operator-approved): sustained ARP/ICMP pressure on 10.10.10.1 + SVIs 30/40/60, 1 req/s each, START 20:57:51Z; output in persistent terminal `qoder-pty-662f4371` (first attempt PID 447453 died with parent shell — restarted). Any REPLY line = recovery signal | `/tmp/inc-20260823-router/arp-pressure-205751.log` (terminal capture) |
| 2026-08-24 ~00:10 (window 1) | Pressure window 1 (600 s) completed with **0 REPLY** lines; SVIs still DOWN, ARP INCOMPLETE; window 2 (1200 s) started | pressure window 2 log in terminal capture |
| 2026-08-24 ~00:20 | **Step 3 console triage via 192.168.88.1 (Vaultwarden-gated, operator session)**: RouterOS 7.19.6 stable; uptime 3d11h ⇒ last reboot was the 2026-08-20 00:42 power event — **no reboot at current outage onset**; memory 885 MiB free, cpu-load 1%; ALL SVIs present (vlan10–vlan80 + defconf bridge + WAN 192.168.32.2/24 dynamic on ether1); all VLAN interfaces `R` (running) with `arp=enabled` on `bridge1`; no critical log entries since 2026-08-20. **RULES OUT both the SVI-missing branch and the `arp=disabled` branch** (INC-2026-0814 prime suspect). Confirmed signature: soft lock of the VLAN forwarding/ARP-reply plane while the defconf bridge plane stays alive. Next: bridge port/VLAN-table + ARP-table read-only evidence, then ether2 bridge-port bounce (APPROVAL-GATED) | operator console paste in this session |
| 2026-08-24 ~00:30 | **Deep triage (read-only)**: `/ip arp print` — entries reachable ONLY via direct ports (defconf bridge 192.168.88.249, vlan80/ether3 10.80.80.199, WAN 192.168.32.1); ALL trunk-side neighbors failed/stale — incl. admin01 10.10.10.50 **failed** despite active ARP pressure ⇒ router not learning/refreshing via ether2. `/interface bridge port print` — ether2 active member of bridge1 (admit-only-vlan-tagged, pvid 1, HW-offload). `/interface bridge vlan print` — VLANs 10–70 tagged on ether2 + bridge1 CPU member; VLAN 80 via ether3; table intact. Firewall input chain accepts ICMP + vlan10, default-drop DISABLED (X) — exonerated. **Fault localized: ether2 trunk RX/forwarding path into bridge1.** Matches INC-2026-0814 postmortem contributing root cause (stuck L2/L3 forwarding state after unclean power events). Next: `/interface bridge host print` confirmation, then ether2 bridge-port bounce (runbook-documented remediation, approval-gated) | operator console paste in this session |
| 2026-08-24 ~00:35 | **Bridge host table**: host MACs ARE learned via ether2 (VID 10/30/40/60 entries dynamic) ⇒ L2 RX path alive; fault refined to L3 ARP-reply/forwarding plane only. `/system history print` **EMPTY** ⇒ no config changes since the 2026-08-20 reboot — human-caused drift fully ruled out | operator console paste |
| 2026-08-24 ~00:40 | **ether2 bridge-port bounce EXECUTED** (runbook step 5 logged emergency change: `disabled=yes` → `disabled=no`, operator console). Post-bounce verification from admin01: all SVIs + prod hosts still DOWN, ARP INCOMPLETE, pressure window 2 shows 0 REPLY ⇒ **INEFFECTIVE**. Next escalations: (a) confirm port re-enabled + link (`/interface bridge port print`, `/interface ethernet monitor ether2 once`); (b) N2048-side Gi1/0/48 bounce; (c) router power-cycle (last resort, INC-2026-0814 precedent) | this session + admin01 probe |
| 2026-08-25 00:25 | **PHYSICAL CABLE REPLACEMENT (operator, on-site)**: trunk cable Gi1/0/48 ↔ ether2 replaced with a CAT5 patch. Effect: INSTANTANEOUS recovery — all 4 SVIs (10.10.10.1/10.30.30.1/10.40.40.1/10.60.60.1) answered ARP pressure at 21:25:43–44Z ⇒ original cable/PHY layer was (co-)responsible; the link re-negotiation also cleared any stuck port state. BUT link flapped back DOWN by ~21:26 (last lone REPLY 21:25:59Z; all probes DOWN at 21:28:44Z). Suspect: replacement cable is CAT5, **below the 1000BASE-T spec (requires CAT5e+)** — link negotiates then collapses. Next: LED inspection both ends; replace with CAT5e/CAT6 patch | pressure log `arp-pressure-210703.log` + admin01 probes |
| 2026-08-25 00:34 | CAT6 patch installed (operator). Verification: all SVIs + prod hosts still DOWN, no new REPLY lines since 21:25:59Z ⇒ 3 cable variants now cycled (original / CAT5 → 15 s of traffic / CAT6 → nothing) — cabling progressively exonerated, suspicion shifts to the switch port Gi1/0/48 PHY or persistent stuck state. Next: `/interface ethernet monitor ether2 once` to classify (no-link / bad negotiation / link-ok); then switch-port change or router power-cycle per result | admin01 probe this session |
| 2026-08-25 ~00:45 | **N2048-side Gi1/0/48 bounce EXECUTED** (Option B: physical unplug 15 s / replug, operator on-site; logged emergency change). Verification 21:47:23Z: no new REPLY lines, all SVIs + prod hosts DOWN ⇒ **INEFFECTIVE**. Exhausted so far: ARP pressure (2 windows), router-side ether2 bridge-port bounce, 3× cable (original/CAT5/CAT6), switch-side port bounce. PHY confirmed healthy on both ends (link-ok 1 Gbps full-duplex ×2). **REMAINING ESCALATION: RB5009 power-cycle** (INC-2026-0814 precedent; awaiting explicit operator approval) | admin01 probe this session |
| 2026-08-25 ~00:50 | **RB5009 REBOOT APPROVED by operator** — method: graceful `/system reboot` from console (NOT power-pull; avoids a second unclean-shutdown event). Reboot-watch loop started from admin01 (4 SVIs, 1 req/s, 15 min window). Post-boot verification ladder queued: gateways → prod hosts → ARP state → router `/log print` boot record | this session |
| 2026-08-25 00:54–01:01 | **RB5009 REBOOT EXECUTED** (graceful `/system reboot`, operator console, confirmation `y`, session closed cleanly). Post-boot probe 22:01:31Z: emergency bridge 192.168.88.1 UP (router booted) BUT all 4 SVIs + all prod hosts still DOWN ⇒ clean reboot did NOT restore the routing plane. Diagnosis shift: fault likely OUTSIDE the router software — prime suspect: N2048 Gi1/0/48 RX path (pre-reboot evidence: router learned host MACs via ether2 = switch→router OK, but ARP replies never arrived = router→switch dead; cable ×3 + port bounces + clean reboot all ineffective). Next gate: post-boot console (`arp print` / `bridge host print` — does admin01 appear?) ⇒ if confirmed, MOVE TRUNK off Gi1/0/48 (spare copper port or SFP+ trunk — RB5009 sfp-sfpplus1 + N2048 Te1/0/1 candidates) | admin01 probe this session |
| 2026-08-25 ~01:03 | **Post-boot console (operator)**: uptime 7m51s (clean boot confirmed, NTP synced, no critical events); bridge host table re-learnt all trunk MACs within minutes (frames DO reach the router); **`10.60.60.20` flipped stale→reachable between two ARP prints = the trunk carried live two-way VLAN 60 traffic briefly after boot**. Yet admin01 probes 22:05–22:06Z: all SVIs DOWN again. ⇒ FAULT IS **INTERMITTENT**, correlated with link (re-)negotiation events (CAT5-swap burst 21:25:43Z, post-reboot burst) — signature of a failing PHY/port that works for seconds after negotiation then dies. Detached watch loop restarted (PID 513737, survives shell reclaim). Next evidence: router ether2 error counters + N2048 Gi1/0/48 error counters; remediation = MOVE TRUNK to a spare port | operator console paste + admin01 probes |
| 2026-08-25 ~01:10 | **Router clock fault FOUND (operator report: "the time is not right")**: boot-time SNTP line displays Aug/24 00:56 EEST but correct Lithuania time at boot was Aug/25 00:5x ⇒ router DATE is 24 h behind (hour/minute/offset correct) — INC-2026-0814 postmortem G8 pattern (router time unreliability after power events). Fix pending in console: `time-zone-name=Europe/Vilnius` + correct date/time (logged change); verify SNTP client. Timeline converted to Europe/Vilnius (EEST) with this entry | this session |
| 2026-08-25 ~01:16 | **ether2 counters (post-reboot ~22 min)**: RX 835 pkt / 66 KB vs ~5,300+ ARP pressure requests sent + 8-VLAN broadcast background ⇒ **~85 %+ of trunk frames never reach the router** — switch-port RX-path degradation confirmed numerically. **Clock**: timezone Europe/Vilnius correct but date still 24 h behind; `/system ntp client print` EMPTY ⇒ NTP client never enabled (INC-2026-0814 G8 unfixed) — fix queued: enable NTP (lt.pool.ntp.org/pool.ntp.org) + manual date if needed. **Next: MOVE TRUNK to Gi1/0/1** (old MikroTik trunk, spare per port table §6) — pre-check issued (`show running-config interface Gi1/0/1`) | operator console paste this session |
