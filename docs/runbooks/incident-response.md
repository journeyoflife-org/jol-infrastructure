# Runbook: Incident Response

## Severity Levels

| Level | Response Time | Escalation | Example |
|-------|--------------|------------|---------|
| P1 — Critical | 15 min ack, 4h resolve | On-call → Engineering Lead → CTO | Production outage, data breach |
| P2 — High | 1h ack, 24h resolve | On-call → Engineering Lead | Degraded service, single pod crash |
| P3 — Medium | 4h ack, 72h resolve | Engineering team | Intermittent errors, high latency |

## GDPR 72-Hour Notification Clock
For data breaches involving personal data:
1. **T+0**: Incident detected, DPO notified immediately
2. **T+1h**: Initial assessment — is personal data affected?
3. **T+24h**: Detailed impact assessment
4. **T+72h MAX**: Notify supervisory authority (mandatory under GDPR Art.33)
5. **T+7d**: Full incident report and remediation plan

## Response Procedure

### 1. Detect & Acknowledge
- Alert received via PagerDuty / Slack
- Acknowledge within SLA
- Create incident channel: `#inc-{date}-{brief}`

### 2. Assess & Classify
- Determine severity (P1/P2/P3)
- Identify blast radius
- Check if personal data is involved (GDPR trigger)

### 3. Contain
- Isolate affected services
- Enable enhanced logging
- Preserve evidence (do NOT delete anything)

### 4. Remediate
- Apply fix
- Verify service health
- Monitor for recurrence (30 min minimum)

### 5. Post-Incident
- Write postmortem within 48h
- Update runbooks with lessons learned
- Schedule follow-up in 1 week

## Known Playbooks

### Host unreachable after hardware/NIC change (port-security err-disable)

Applies when a host on an access port becomes unreachable after a board/NIC
swap (e.g. llm-prod-lt01 Gi1/0/4, 2026-08). Symptom: gateway and switch mgmt
pingable, host not. Note: in the 2026-08 incident the port was NOT
err-disabled — it was a host-side physical link fault (step 4).

1. Confirm scope from admin01: `ping 10.30.30.1` (gateway) and `ping 10.10.10.2`
   (switch) reachable, host IP not.
2. Diagnose (read-only): `scripts/network/diagnose-gi104.sh` — save output as
   evidence (SOC 2 CC7.2).
3. If `show interfaces status err-disabled` lists the port: raise a change
   request, then re-enable:
   `scripts/network/n2048-cli.py --config "interface gigabitethernet 1/0/4" shutdown "no shutdown" exit`
   (commands after `--config` are positional, or use `--config --commands ...`;
   remove any stale secured MAC on the interface first).
4. If admin up but link down and NOT err-disabled (physical, as in the
   2026-08 incident): check host power, NIC LEDs, cable, onboard LAN enabled
   in UEFI. No switch change needed.
5. On the host: verify static IP config matches the port table
   (netplan; NIC name may have changed after the swap).
6. Verify: `ping <host IP>` from admin01, then SSH key-only access.
