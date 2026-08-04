# llm/ — Bare-metal LLM host (llm-prod-lt01)

Deployment and operations stack for the air-gapped, self-hosted LLM
platform, migrated from `jol-llm/infra` (see jol-llm CHANGELOG).
This is the **only** place where llm-prod-lt01 infrastructure changes
happen; jol-llm retains documentation, model registry, security
artifacts, and tests.

## Layout

| Path | Purpose |
|---|---|
| `infra/` | Ansible: inventory, staged playbooks (01–06), roles, group_vars |
| `config/` | Host configuration: sysctl, auditd, ufw, logrotate, netdata, ollama env |
| `deploy/` | systemd units, Podman quadlets, compose, Caddy (mTLS) |
| `monitoring/` | Ollama metrics exporter, Netdata charts/alerts, dashboard export |
| `scripts/` | Install, maintenance, security, benchmark scripts |

## Cross-repository contract

Some scripts consume **jol-llm** assets (model manifests, benchmark CSV,
SBOM, compliance artifacts). Set `JOL_LLM_REPO` to a jol-llm checkout:

```bash
export JOL_LLM_REPO=/opt/jol/repos/jol-llm
llm/scripts/maintenance/health-check.sh --verify-model
```

Without `JOL_LLM_REPO`, scripts fall back to this repository root
(legacy layout) and skip/degrade gracefully where assets are absent.

Model registry metadata (manifests/licenses/benchmarks) stays in
**jol-llm** — the supply chain is hash-gated on the target host by
`scripts/install/03-model-pull.sh`.

## Usage

```bash
cd llm/infra
ansible-playbook -i inventory/production.ini playbooks/site.yml --check
```

Secrets: `infra/group_vars/all/vault.yml` must exist in **encrypted**
form only. Bootstrap from `vault.yml.example` (see its header).

## Documentation

Authoritative documentation stays in jol-llm:

- Architecture & deployment: `jol-llm/docs/01-architecture`, `docs/02-deployment`
- Security & threat model: `jol-llm/docs/03-security`, `jol-llm/security/`
- Runbooks: `jol-llm/docs/04-operations/runbooks`

## Change control

All changes under `/llm/` require approval from `@journeyoflife-org/devops`
(security-sensitive paths additionally `@journeyoflife-org/security`) per
CODEOWNERS — matching the 2-eyes rule previously enforced in jol-llm.
