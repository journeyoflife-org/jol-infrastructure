# CHANGELOG

Production change log for SOC 2 CC8.1 compliance.
All production infrastructure changes must be documented here.

| Timestamp (UTC) | Author | Change | Environment | Ticket |
|-----------------|--------|--------|-------------|--------|
| 2026-08-26T19:00:00Z | @JourneyOfLife | SOPS Gate-0 governance package (docs/tooling ONLY, zero production mutation): ADR-003 amendment DRAFT (SOPS+age git-at-rest, dual identity age-jol/age-jolm per tree segregation, Vaultwarden as key source-of-truth, Shamir M=2/N=3 DR-only, Status PROPOSED — gates 4–8 blocked until Conditions met) at docs/architecture/adr-003-amendment-sops-age.md; scripts/maintenance/git-fleet-sync.sh replaces defective git-bulk-push.sh draft (4 fixes: opt-in staging + secret-path preflight, no commit-failure swallowing, remote-presence aggregation without fleet abort, prod-deploy remote refusal — all verified by controlled /tmp/fleetsync-test harness: preflight BLOCK + push REFUSED + exit=1). Rollback: delete both new files | docs | TBD (CC8.1 issue) |
| 2026-08-11T20:46:00Z | @JourneyOfLife | llm-prod-lt01 model-store backup migrated from admin01 tar.gz to pbs01 (PBS-native client-side-encrypted push, namespace `jol-llm`, retention 7d/4w, restore drill passed); admin01 storage role retired. Deployment runbook, fleet server docs, ansible hardening roles and prod inventory pins added | prod | - |
| _YYYY-MM-DDTHH:MM:SSZ_ | _@username_ | _description_ | _prod_ | _JOL-XXXX_ |
