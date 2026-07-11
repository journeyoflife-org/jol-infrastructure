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
