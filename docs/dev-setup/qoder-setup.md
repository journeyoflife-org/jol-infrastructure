# Qoder Agent Setup (jol-infrastructure)

Canonical Qoder configuration for the jol-infrastructure workspace:
Codebase Index, Rules, MCP servers, autonomy, update policy, and verification.
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

## MCP Servers

Verified state of this workstation 2026-09-17. `~/.qoder` is shared by
PyCharm and WebStorm, so one configuration serves both IDE tracks.

| Server | Status | Provided by |
|--------|--------|-------------|
| `chrome-devtools`, `playwright` | connected | chrome-devtools-mcp 1.2.0 / playwright 1.0.0 plugins |
| `browser-use` | connected | no entry in `installed_plugins_v2.json` — bundled by the Qoder IDE core, so it is versioned with the plugin build, not the marketplace |
| `context7` | connected | context7 1.0.0 plugin |
| `terraform` | connected | terraform 0.1.0 plugin (`hashicorp/terraform-mcp-server:1.0.0`, cached locally; tag-only pin — see QD-7) |
| **`github-jol`** | **NOT CONNECTED — target state** | specified by this page; verified absent from all three MCP configs 2026-09-17 |

No user-added MCP server exists: `~/.qoder/mcp.json`,
`~/.qoder/shared_client/mcp.json` and
`~/.qoder/shared_client/extension/local/mcp.json` all hold
`"mcpServers": {}`. Everything in the connected rows above is bundled by an
installed plugin — none of it was added here.

### github-jol — connection procedure (operator action required)

GitHub access, when wired, uses the official `github/github-mcp-server` image.
The deprecated `@modelcontextprotocol/server-github`, `server-postgres`, and
`server-commands` packages must not be used.

Token policy: fine-grained PAT scoped to `journeyoflife-org` only, read-only
(contents, metadata); no write, admin, or delete privileges. The token lives
only in Qoder's secure settings — never commit it to any repository, never
place it in a file under `/opt/jol`, and never enter it from an agent session.

- ⚠ **FINDING GH-TOKEN-SCOPE (2026-09-17)**: the workstation's existing
  `gh` CLI credential is an OAuth token on the **personal** account
  `JourneyOfLife` with scopes `admin:org`, `repo`, `workflow`,
  `write:packages`. It is NOT policy-equivalent and MUST NOT be reused as
  `GITHUB_PERSONAL_ACCESS_TOKEN` for an agent-facing MCP server — doing so
  would grant the agent org-admin and write access.
- Prerequisites verified present: `docker` 29.8.0 daemon running, GitHub
  reachable from this host. `ghcr.io/github/github-mcp-server` is not yet
  pulled (first start fetches it — record the digest like any other pinned
  tool in [tool-versions.md](tool-versions.md)).

Steps:

1. Mint the fine-grained PAT in GitHub (org `journeyoflife-org`, read-only
   contents + metadata) as the org owner.
2. Qoder Settings → **MCP Servers** → **Add**, paste the configuration below
   and supply the PAT in the settings UI:

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

3. Reload the Qoder plugin, then run gate **G1** in the verification
   checklist below and record the result here.

Rollback: delete the `github-jol` entry in Qoder Settings → MCP Servers.
No repository artefact depends on it.

### Interim compensating control

While `github-jol` is absent, GitHub reads from an agent session go through
`/usr/bin/gh` (2.100.0) under the "Confirm before executing commands" autonomy
rule — proven working 2026-09-17 against
`repos/journeyoflife-org/jol-infrastructure/commits`. That path is functional
but broader-scoped (see GH-TOKEN-SCOPE above), so it is an interim measure and
not the target state.

### terraform MCP — verified read-only surface

Confirmed 2026-09-17 that the wired terraform server exposes exactly nine
tools: `search_modules`, `search_providers`, `search_policies`,
`get_module_details`, `get_provider_details`, `get_provider_capabilities`,
`get_policy_details`, `get_latest_module_version`,
`get_latest_provider_version` — registry lookups only. No plan-, apply- or
registry-install-capable tool is registered.

The server's launch contract
(`~/.qoder/plugins/cache/qoder-marketplace/terraform/0.1.0/.qoder-plugin/mcp.json`)
passes `TFE_TOKEN`, `TFE_ADDRESS` and `ENABLE_TF_OPERATIONS` straight through
from the shell environment. The write-capable HCP Terraform tools are compiled
into the binary but stay unregistered while those variables are unset — verified
unset on 2026-09-17. The plan-first rule in [QODER.md](../../QODER.md)
therefore has no MCP-side bypass **on this workstation**, and it is exactly one
exported variable away from having one. Re-run this check after any plugin
update — gate **G3** below.

⚠ **QD-7**: that manifest selects the image by mutable tag
`hashicorp/terraform-mcp-server:1.0.0` rather than by digest — the same class of
finding as the tracked `minio:latest` on `jol-rag-server`, one notch milder. The
manifest is vendor-controlled, so the compensating control is recording the
resolved digest in [tool-versions.md](tool-versions.md) and re-checking it at
each G3 run.

## Agent Autonomy

Set agent autonomy to **Confirm before executing commands**. Full
auto-execution is not permitted in this repository given the compliance
posture (SOC 2 Type II / GDPR / ISO 27001).

## Plugin Update Policy

Automatic Qoder plugin updates are **disabled** (Qoder Settings →
Plugin Settings → Update Settings → uncheck "Automatically install
plugin updates when available"). The plugin receives repository code
context, so a version change is a supply-chain change and is governed
like every other pinned tool: the installed version is recorded in
[tool-versions.md](tool-versions.md) and reviewed during the quarterly
maintenance window (SOC 2 CC8.1).

Rollback: if a newly approved version misbehaves, reinstall the pinned
build from the JetBrains Marketplace plugin archive and re-run the
verification checklist below.

An IDE upgrade also re-resolves the plugin set and can silently replace a
pinned build without touching the auto-update setting — observed
2026-09-17T14:28–14:30Z, when both IDEs moved to 2026.2.2 and the Qoder
plugin landed on 2026.917.73315602 while this page's companion pin still said
2026.819.62697638 (finding **QD-1**, corrected in
[tool-versions.md](tool-versions.md)). Gate **G3** covers re-verification.

## Qoder Security (security-scan plugin)

Status: **QD-6 resolved — the control is genuinely OFF, proven empirically
2026-09-17.** No scan of any JOL edit has run since 2026-09-05.

Four stores describe this one switch and they disagree:

| Store | Records |
|-------|---------|
| `~/.qoder/settings.json` → `enabledPlugins["security-scan@qoder-bundler"]` | `false` — **authoritative** |
| `~/.qoder/settings.json` → `securityScan.{l1StaticCheck,l2LightweightScan,l3DeepScan}` | all `true` — **armed**, see the resolver read below |
| `~/.qoder/plugins/installed_plugins_v2.json` → `enabled` | `true` — an install record, not a runtime switch |
| `~/.qodersec/config.yaml` → `review.post_tool_use_file.enabled` | `true` — binary-side default, not currently consulted |

**Resolver read — the sanctioned authority.** The plugin's own settings resolver
(`bin/security-scan-settings.sh`) is the only component allowed to answer this
question; `SKILL.md` explicitly forbids parsing `settings.json` by hand. Executed
2026-09-17 it returned:

```json
{"status":"ok","host":"qoder_ide","l2_enabled":true,"l3_enabled":true}
```

Both cloud-egress layers are therefore **armed right now** and held back by one
thing only: the plugin enablement switch. Enabling the plugin without clearing
those two toggles brings L2 and L3 live in the same instant. The plugin is
nonetheless not loaded — a third independent observable confirms it: the
`security-scan` skill is absent from this session's registered skill set while
sibling plugin skills (`context7-mcp`, `chrome-devtools`, `frontend-design`,
`better-harness`) are all present.

So the true state is asymmetric, and that asymmetry is the whole point of QD-6:
**no scanning today, egress pre-armed.** Nothing is scanning JOL source, yet the
safest-looking config file is one toggle away from uploading it. Close QD-6 as a
deliberate, recorded act — never a casual tick.

**Why evidence rather than inference.** Log silence alone proves nothing here:
the `PostToolUse` matcher in `.qoder-plugin/qoder-hooks.json` is
`Edit|Write|MultiEdit|NotebookEdit`, and the agent's primary edit tool in this
harness is `SearchReplace` — absent from that list. Every repository edit in this
session fell outside the matcher and could not have logged anything, live plugin
or not. One near-miss worth recording so it is not repeated: `~/.qodersec/.config-version`
holds `0.8.1`, which looks like proof of a post-update hook run. It is not — that
file is written only by `qodersec-launch.sh` (`bootstrap.sh` never touches it), so
it was already seeded on the 2026-09-05 first run; the `0.8.1` there is the
*plugin* version, while the *binary* it pinned is 0.8.0.

**The probe that settled it.** A throwaway file was created inside this project
with the `Write` tool — a name the matcher does cover — then edited with
`SearchReplace`, and the log re-read: still 22 lines, last event
`[2026-09-05 21:28:31]`, zero new entries. A second hook agrees: `SessionStart`
logged `session-start baseline init` on every session through 2026-09-05 and
nothing since, despite many sessions. `Write`-path silence cannot be explained by
the matcher, so the plugin is not loaded. The probe file was deleted afterwards.

⚠ Log timestamps are **Europe/Vilnius local, not UTC** (`21:28:31` local =
`18:28:31Z`). Quote them as local in audit records; conflating the two shifts the
evidence by three hours.

**Remediation — operator action in the Settings UI, not a file edit.**
`~/.qoder/settings.json` is live-owned by a running IDE: hand-editing it while
PyCharm is up can be silently rewritten on the next settings change or at exit,
yielding a false "fixed". Do not enable the plugin on its own either — that arms
both cloud-egress layers, whose toggles already read `true`.

1. Qoder Settings → Security: enable Qoder Security and set **L2 lightweight**
   and **L3 deep** to **off** in the same pass — mandatory, not optional, since
   the resolver already reports both as `true`. Target posture: L1 local regex
   only, zero egress, until the QD-3 data-residency decision exists.
2. Restart the IDE — hooks bind at session start.
3. Run gate **G2** below, including the `Write` vs `SearchReplace` probe, and
   record the result here. If only the `Write` probe logs, **QD-6b** is
   confirmed: real-time detection covers part of the agent edit surface, the
   repository `check-secrets` and pre-commit hooks remain the authoritative
   gate, and L1 is best-effort only — it must not be cited as *the* secret
   detection control.
4. Acceptable alternative: keep the plugin off and set all three `securityScan`
   toggles `false`, so the stores tell one truth. A weak config is tolerable;
   a config that reads enabled while behaving disabled is not, because a
   reviewer can cite a control that is not running.

What each layer does with source — the distinction that matters on a GDPR
Art. 9 / PCI-DSS estate:

| Layer | Trigger | Data path | Verified state |
|-------|---------|-----------|----------------|
| L1 pattern warnings | `PostToolUse` on `Edit\|Write\|MultiEdit\|NotebookEdit` — `SearchReplace` not matched | local regex only (31 rules) | **not running** (QD-6); last runs 2026-09-05 21:03–21:28 local, 9 runs, 0 candidates, nothing off-host |
| L2 lightweight review | explicit `/security-scan` selection | `qodercli` → vendor backend | never run |
| L3 deep review | explicit request, or offered at a push/PR/merge handoff | `qodercli` → vendor backend | never run |
| Project/file cloud scan | explicit scope request | **file-bundle upload**, 10 000-code-line cap | never run |

Rules for the cloud layers (**QD-3**):

1. L2/L3/cloud scans transmit source to a third-party backend. Until a
   processing and data-residency decision is recorded, they must not be run
   against repositories holding production topology, host inventories or
   secret material — `jol-infrastructure`, `terraform/`, `inventory/`,
   `kubernetes/`, `llm/`, `docs/servers/`, anything SOPS-encrypted. Same
   discipline as the EU-only provider chain required of Hermes.
2. Application and front-end repositories may use them once that decision
   exists. The scan is credit-metered: an exhausted-credits outcome must never
   be reported as "no security issues found".
3. Custom detection rules belong in a committed
   `<git-root>/.codesec/security-patterns.yaml` — JOL-specific patterns
   (forbidden `STRIPE_*` literals, Vaultwarden/Ansible-Vault handling) are
   then reviewable in CODEOWNERS instead of living in a personal `~/.qodersec`
   file. Keep `hook_debug: false`; debug logs capture diff content.
4. `SessionStart` runs `ensure-deps`, which installs and updates runtime
   binaries outside this repository's pinning process — recorded versions
   `qodersec` 0.8.0 (channel `global`, 2026-09-05T17:59:48Z) and `qodercli`
   1.0.45. That is a supply-chain path (**QD-2**); both are now pinned in
   [tool-versions.md](tool-versions.md) and reviewed quarterly.
5. Coverage gap (**QD-4**): the only baseline state on this host is keyed
   `viavitae-org-554996` over `/opt/viavitae/...` paths, and the JOL sessions
   logged "No git HEAD found; Qoder Security coverage baseline was not
   initialized". No JOL repository has a scan baseline yet.

## Agent Instruction File Coverage

Qoder rules are per workspace: they are not inherited across repositories and
the org-level `.github` repository does not distribute them. Verified
2026-09-17 across `/opt/jol/repos` (**QD-5**): only `jol-infrastructure`,
`jol-hub` and `jol-hermes-agents` carry an instruction file, so the ten cloned
`jol-site-*` spokes and the remaining back-end repositories give an agent no
tenant, payment or secrets guardrails at all.

This workspace cannot close the gap: agent file edits are confined to the
opened project (the "allow editing files outside the project" control is OFF by
the workstation governance standard — the tooling refused the writes, which is
the control working as designed), and every spoke's `main` is protected and
needs a PR plus CODEOWNERS review. Treat this as 10+ reviewed changes.

Canonical content for a spoke — deliberately short and by reference, so no
contract is duplicated out of `jol-hub`:

```markdown
# QODER.md — <spoke>

Vertical Next.js 14 site consuming `@jol-hub/*` platform packages at
published versions (`^1.0.0`, never `workspace:*`). pnpm@10.30.3 via
corepack; never `npm install`.

Inherit every contract from jol-hub/QODER.md by reference — ADR-001
schema-per-tenant (unknown tenant → generic 404, never enumerate tenants),
the closed payment boundary, secrets via Vaultwarden/Ansible Vault only,
Conventional Commits with the closed scope list, and a rollback statement
per change.

Gates before commit: `pnpm verify` (type-check, vitest,
check-payment-boundary, check-theme-literals, check-secrets), `check-a11y`,
`check-perf`. Never report a browser-bound gate as executed on an offline
host.
```

⚠ Before this template is committed, reconcile the package scope: spokes
declare `@jol-hub/*` while `.npmrc` routes `@journeyoflife-org` to GitHub
Packages. Do not let an instruction file assert a registry mapping that the
build does not honour.

## Verification Checklist

Run these in a fresh Qoder chat and confirm the expected answers:

1. "List the Ansible roles in this repo" → common, ssh, time_sync, monitoring, base_firewall, backup_client.
2. "What does ADR-001 decide?" → Terraform state backend.
3. "What is the UFW policy on rag-prod-lt01?" → default-deny incoming; VMID 100 on pve-prod-hv01.
4. "List the three most recent commits on journeyoflife-org/jol-infrastructure" → real data. Since `github-jol` is not connected (verified 2026-09-17), this must be served by the `gh` CLI interim path; an answer claiming the `github-jol` MCP is itself a drift signal.
5. Request a small Ansible task change → answer must cite Vault-only secrets, idempotency, and `ansible --check`.

**G1 — github-jol activation gate** (run only once the connector is configured;
baseline 2026-09-17: NOT APPLICABLE, server absent):

```text
□ Server present:  grep -c github-jol ~/.qoder/shared_client/extension/local/mcp.json   # ≥ 1 after the settings UI writes it
□ Read-only works: ask Qoder to list the 3 latest commits on journeyoflife-org/jol-infrastructure → served by github-jol tools, matching `gh api` output
□ Write refused:   the PAT must be rejected by GitHub on any write attempt (fine-grained read-only)
□ No secret at rest: git -C /opt/jol/repos/jol-infrastructure status --porcelain   # clean — token never in a repo file
□ Record:          date + result appended to this section, image digest pinned in tool-versions.md
```

**G2 — security-scan activation gate** (fresh session after an IDE restart;
log timestamps below are Europe/Vilnius local, not UTC):

```text
□ Resolver truth: ~/.qoder/plugins/cache/qoder-bundler/security-scan/bin/security-scan-settings.sh   # host + l2_enabled/l3_enabled must match the intended posture — the ONLY sanctioned resolver; never parse settings.json by hand
□ Resolver post-fix: re-run it after the change → must return l2_enabled:false, l3_enabled:false under option (a). Baseline 2026-09-17: {"host":"qoder_ide","l2_enabled":true,"l3_enabled":true} with the plugin disabled = armed-but-unloaded (QD-6)
□ L1 via Write:  create a throwaway file with the Write tool → a new `layer1 scan: tool=Write` line appears
□ L1 via SR:     edit that same file with SearchReplace → if NO line appears, QD-6b is confirmed and L1 covers only part of the agent edit surface
□ Housekeeping:  delete the probe file; git status --porcelain must be clean
□ Baseline:      with the workspace inside a real git repo, the log must no longer report "No git HEAD found"
□ Egress off:    no L2/L3/cloud line in the log until a Tier-1 decision is recorded (QD-3)
□ Stores agree:  enabledPlugins["security-scan@qoder-bundler"], the three securityScan toggles and installed_plugins_v2.json describe ONE intended state (QD-6)
```

**G3 — pin re-verification gate** (after every IDE or plugin change):

```text
□ Plugin build matches the pin: unzip -p ~/.local/share/JetBrains/{PyCharm,WebStorm}2026.2/qoder-jetbrains/lib/instrumented-qoder-product-*.jar META-INF/plugin.xml | grep -m1 '<version>'
□ Runtime binaries match:       cat ~/.qodersec/bin/qodersec-version.json ~/.qodersec/bin/qodercli-version.json
□ MCP surface unchanged:        terraform still exposes 9 read-only tools, and TFE_*/ENABLE_TF_* remain unset
□ Terraform pin intact:         docker image inspect --format '{{.RepoDigests}}' hashicorp/terraform-mcp-server:1.0.0
```

## See Also

- [QODER.md](../../QODER.md) — AI-assistant behavioral guidelines and repo-specific change-management constraints
- [pycharm-qodana.md](pycharm-qodana.md) — PyCharm remote development + Qodana
- [tool-versions.md](tool-versions.md) — pinned tool versions
