# Postmortem — INC-2026-0814: MikroTik RB5009 inter-VLAN routing outage (P1)

> **Compliance**: SOC 2 CC7.2/CC7.3, ISO 27001 A.5.24–A.5.27, GDPR Art. 32
> (availability). Availability incident only — no personal data involved,
> GDPR 72h notification clock not triggered.
> Full evidence trail: `docs/security/incident-20260814-router-outage.md`.
> No credentials in this document.

## Summary

| Field | Value |
|---|---|
| Severity | P1 (full prod-segment outage) |
| Impact window | Sat 2026-08-15 ~03:15 → Sun 2026-08-16 ~03:05 EEST (~24 h); observed-from-admin01 since Sat 12:33 |
| Blast radius | All routed segments: 10.30/10.40/10.60 (and 20/50/70) — LLM, RAG/MCP/Hermes, Proxmox mgmt unreachable |
| Not impacted | VLAN 10 local fabric (switch, pbs01, admin01↔pbs01), VMs kept running, llm-prod-lt01 never rebooted (uptime 1w4h verified) |
| Root cause (primary) | Router stopped routing between Sat 03:15 and Sat 12:33 — no log of the event (silent hang); preceded by a Fri 18:40 power-outage reboot from which it had recovered (Sat 03:15 backup succeeded) |
| Root cause (contributing) | After the Sat 23:15 operator power-cycle the router ran with intact config and trunk link up, yet did not pass VLAN traffic until ~Sun 03:05 (stuck L2/L3 forwarding state after repeated unclean power events) |
| Data loss | None. Restore point refreshed Sun ~03:14 EEST (`2026-08-16T00:14:32Z`, verified on pbs01) |

## Timeline (EEST)

| Time | Event |
|---|---|
| Fri 18:40 | Power event: router logs `rebooted without proper shutdown, probably power outage`; admin01 reboots 18:40–19:59 (2x) |
| Fri→Sat 03:15 | Nightly PBS backup of llm-prod-lt01 succeeds → routing healthy at this point |
| Sat 03:15→12:33 | Router stops routing (silent; no log) |
| Sat 12:33 | admin01 boots; outage discovered |
| Sat 23:15 | Operator power-cycle of router (uptime evidence); boots with intact config but VLAN traffic still blocked |
| Sun 00:30–03:00 | Systematic triage: fault isolated to router (controls pbs01/switch up); router console access established (192.168.88.1 emergency path via ether8 defconf bridge) |
| Sun ~03:05 | Routing restored; independently verified (gateways, hosts, VMs, Prometheus, inter-VLAN 40→30) |
| Sun ~03:14 | Manual backup refresh executed and verified (incident follow-up) |

## What worked

- Evidence-first triage: control hosts (pbs01, switch) isolated the fault in minutes; Task 2 was exonerated early and correctly.
- Router console showed config fully intact (all SVIs, trunk, bridge VLAN filtering) — avoided an unnecessary config rebuild.
- Bridge host table + router ARP table + local tcpdump pinpointed the stuck forwarding state without a packet sniffer (device-mode blocks it).
- Emergency mgmt path (defconf bridge on ether8, 192.168.88.0/24) existed and enabled recovery — must now be documented properly.

## What failed (systemic gaps → actions)

| # | Gap | Action | Priority |
|---|---|---|---|
| G1 | No MikroTik config backup anywhere | Add `/export` (secrets scrubbed) + `/system backup` to PBS backup scope; store encrypted snapshot off-box | High |
| G2 | No documented OOB/emergency access to the router | Document the 192.168.88.1/ether8 emergency path (or dedicated mgmt VLAN access) in the runbook + port table | High |
| G3 | No alert fired for router loss (masked by admin01 reboot) | Independent watchdog for 10.10.10.1 (e.g., pbs01 cron → alert on 3 misses) | High |
| G4 | Legacy 192.168.80.0/24 flat LAN still live (WiFi DHCP) | Complete decommission (port-table migration step 8) | Medium |
| G5 | Undocumented cabling (admin01 enp5s0 → router ether8) | Cable audit; label + port-table entry | Medium |
| G6 | Router = unmanaged SPOF for 100% of prod segments | Cold-standby RB5009 with baseline config + UPS on router power | High |
| G7 | device-mode blocks the packet sniffer, hampering diagnosis | Review device-mode allowed-features; enable sniffer for authorized triage | Medium |
| G8 | Router NTP unreliable after power loss (skewed forensic timestamps) | Configure NTP servers on the router; verify time sync post-reboot | Medium |
| G9 | Repeated unclean power events precede the stuck state | UPS coverage for rack network gear; investigate Sat-morning power quality | High |

## Security findings raised during verification (tracked separately)

1. llm-prod-lt01 UFW carries two `Anywhere ALLOW` rules for 10.10.10.0/24 and
   10.60.60.0/24, exposing 11434/4000 beyond the documented baseline
   (11434/4000 from 10.40.40.0/24 only). Decision required: remove the
   Anywhere rules or re-document the mgmt exemption.
2. Router credential passed through the incident session → rotate and fix the
   Vaultwarden pairing (login `HYLA7HQ4LZ` vs user `admin`).
3. `temp allow ping` rule on the router and mid-incident edits → capture
   `/system history print` and clean the ruleset (missing explicit 40→30
   accept; rule 29 ineffective against VLAN sub-interfaces).

## Post-outage verification (Task 3 smoke suite, Sun ~03:20 EEST)

| Item | Result |
|---|---|
| Gateways + all prod hosts + VMs 100/101/102 | GREEN |
| Prometheus scrape llm-prod-lt01 | up=1 |
| LiteLLM gateway :4000 from VLAN 40 — `/health/liveliness`, aliases private/tools/reason-offline/embed/batch-code/frontier | GREEN (aliases listed) |
| Alias inference private / reason-offline / tools | 200 OK, tokens generated (tools: thinking-consumed budget — tune params) |
| `/v1/embeddings` model=embed | GREEN (768-d) |
| `/v1/embeddings` model=batch-code | **FAIL → root-caused**: Ollama lacks `OLLAMA_EMBEDDINGS=true`; fix pending change approval |
| Cross-segment UFW from 10.40.40.0/24: 11434 ✓, 4000 ✓, 9100 blocked ✓ | GREEN (+ mgmt-VLAN drift flagged above) |
| RAG `/health` + `/ready` (qdrant/minio/ollama up) | GREEN |
| MCP units (git/jira/compliance/docs) | 4/4 active (via documented ProxyJump path) |
| Post-test `ollama ps` | clean (test models loaded, scheduled unload) |
| Backup refresh | `2026-08-16T00:14:32Z` verified on pbs01 |

## Closing notes

P1 SLA (4 h resolve) was exceeded (~24 h observed outage). Contributing:
no OOB access, no config backup, no watchdog, sniffer blocked, and a
misleading initial hypothesis (host-side) corrected by control-host triage.
Runbook playbook added: `docs/runbooks/incident-response.md` →
"Router (inter-VLAN) outage".
