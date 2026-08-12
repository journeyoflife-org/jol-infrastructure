# CHANGELOG

Production change log for SOC 2 CC8.1 compliance.
All production infrastructure changes must be documented here.

| Timestamp (UTC) | Author | Change | Environment | Ticket |
|-----------------|--------|--------|-------------|--------|
| 2026-08-11T20:46:00Z | @JourneyOfLife | llm-prod-lt01 model-store backup migrated from admin01 tar.gz to pbs01 (PBS-native client-side-encrypted push, namespace `jol-llm`, retention 7d/4w, restore drill passed); admin01 storage role retired. Deployment runbook, fleet server docs, ansible hardening roles and prod inventory pins added | prod | - |
| _YYYY-MM-DDTHH:MM:SSZ_ | _@username_ | _description_ | _prod_ | _JOL-XXXX_ |
