# Qoder Agent Setup (jol-infrastructure)

Canonical Qoder configuration for the jol-infrastructure workspace:
Codebase Index, Rules, MCP servers, autonomy, and verification.
The Qoder settings UI is the runtime source of truth; keep this page in
sync when standards change.

Scope: this page applies to `/opt/jol/repos/jol-infrastructure`.
Configuration for the jol-hub monorepo (Django/Next.js rules,
`.qoderignore`) is deferred until that repository is cloned.

## Codebase Index

1. Open Qoder Settings (`Ctrl + Shift + ,`) → **Codebase Index**.
2. Toggle **Automatic Indexing** ON for this workspace.

No `.qoderignore` is required: the repository `.gitignore` already excludes
all indexing noise (`.venv/`, `.idea/`, `.terraform/`, `.external_modules/`,
`*.pem`, `.env*`, `qodana-results/`), and Qoder respects `.gitignore`.

## Rule: JOL-Infrastructure

1. Qoder Settings → **Rule Management** → **Add**.
2. Name: `JOL-Infrastructure`
3. Type: **Specific Files**
4. File patterns: `ansible/**, terraform/**, helm/**, kubernetes/**, policies/**, scripts/**`
5. Content:

```markdown
# JOL Infrastructure Standards (jol-infrastructure)

## Layout
- ansible/ — roles: common, ssh, time_sync, monitoring, base_firewall, backup_client
- terraform/ — modules + environments (dev/staging/prod), encrypted remote state (ADR-001)
- helm/, kubernetes/ — cluster workloads and policies
- policies/ — OPA Rego, tfsec, checkov policy-as-code
- scripts/ — audit, bootstrap, maintenance, network utilities

## Secrets & Compliance (SOC 2 Type II / GDPR / ISO 27001)
- Secrets ONLY via Ansible Vault, Proxmox cloud-init, or Vaultwarden — never plaintext, never in *.tfvars, never in Qoder Memory/Rules
- OPA enforce-no-secrets-in-terraform must pass on all Terraform changes
- UFW default-deny incoming; SSH key-only; all HTTP/gRPC TLS 1.3
- Ansible must be idempotent; run ansible --check before apply
- Scheduled jobs use Europe/Vilnius timezone
- Record every change in docs/ change history
- Validate via pre-commit (tflint, tfsec, checkov, opa test) before commit
```

## MCP Server: github-jol

GitHub access uses the official `github/github-mcp-server` image. The
deprecated `@modelcontextprotocol/server-github`, `server-postgres`, and
`server-commands` packages must not be used.

Token policy: fine-grained PAT scoped to `journeyoflife-org` only,
read-only (contents, metadata); no write, admin, or delete privileges.
The token lives only in Qoder's secure settings — never commit it to any
repository.

1. Qoder Settings → **MCP Servers** → **Add**.
2. Paste the configuration and replace the placeholder with the PAT:

```json
{
  "mcpServers": {
    "github-jol": {
      "command": "docker",
      "args": ["run", "-i", "--rm", "-e", "GITHUB_PERSONAL_ACCESS_TOKEN", "ghcr.io/github/github-mcp-server"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "<FINE_GRAINED_READ_ONLY_PAT>"
      }
    }
  }
}
```

## Agent Autonomy

Set agent autonomy to **Confirm before executing commands**. Full
auto-execution is not permitted in this repository given the compliance
posture (SOC 2 Type II / GDPR / ISO 27001).

## Verification Checklist

Run these in a fresh Qoder chat and confirm the expected answers:

1. "List the Ansible roles in this repo" → common, ssh, time_sync, monitoring, base_firewall, backup_client.
2. "What does ADR-001 decide?" → Terraform state backend.
3. "What is the UFW policy on rag-prod-lt01?" → default-deny incoming; VMID 100 on pve-prod-hv01.
4. "List the three most recent commits on journeyoflife-org/jol-infrastructure" → real data via the github-jol MCP.
5. Request a small Ansible task change → answer must cite Vault-only secrets, idempotency, and `ansible --check`.

## See Also

- [QODER.md](../../QODER.md) — AI-assistant behavioral guidelines and repo-specific change-management constraints
- [pycharm-qodana.md](pycharm-qodana.md) — PyCharm remote development + Qodana
- [tool-versions.md](tool-versions.md) — pinned tool versions
