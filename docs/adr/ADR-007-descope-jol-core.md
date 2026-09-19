# ADR-007: De-scope `jol-core` from Tier 0 (Contracts)

## Status

Accepted

## Context

`jol-core` was designated as a Tier 0 (Contracts) repository in the JOL ecosystem map (AGENTS.md §1), intended to hold "domain models and shared contracts consumed by all Tier 1/2/3 repos."

The 2026-09-19 fleet audit (Phase 5: Architecture Assessment, finding H1) revealed that `jol-core`:

1. **Contains no shared library structure** — no `pyproject.toml`, no `src/` directory, no `package.json`, no package scaffolding of any kind.
2. **Contains no tests** — zero test files, no test infrastructure.
3. **Contains no CI** — zero GitHub Actions workflows.
4. **Contains no lockfile** — no dependency pinning.
5. **Contains standalone reference documents** — a 589-line Django script (`gdpr_compliant_bitrix24_synchronization_implementation.py`) that imports from non-existent local modules (`.models`, `.exceptions`), plus several standalone markdown documents (Terraform configuration, multi-tenant framework, multi-repo management). These are conceptual/reference implementations, not functional shared libraries.
6. **Has no downstream consumers** — the Phase 3 dependency scan confirmed that no repository in the fleet imports `jol-core` as a package. Cross-repo communication occurs via HTTP APIs and convention, not enforced package dependencies.

The Tier 0 designation is therefore **aspirational, not actual**. AGENTS.md §1 describes Tier 0 as holding "domain models, shared contracts" but the empirical evidence shows `jol-core` holds none.

Maintaining the Tier 0 designation creates audit risk:
- SOC 2 auditors may question why a "contract" repo has no contracts.
- ISO 27001 A.8.8 (configuration management) requires accurate asset documentation.
- The ecosystem map in AGENTS.md misleads contributors about actual dependency edges.

## Decision

**De-scope `jol-core` from Tier 0.** Specifically:

1. **Update AGENTS.md §1 ecosystem map** — remove `jol-core` from the Tier 0 (Contracts) tier. Add a note clarifying that Tier 0 contract edges are convention/HTTP, not enforced package dependencies.
2. **Update AGENTS.md cross-repo dependency sections** — remove `jol-core` from upstream dependency lists in §2.1 (`jol-rag-server`), §2.3 (`jol-mcp-servers`), and §2.4 (`jol-hermes-agents`).
3. **Retain `jol-core` in the fleet** — the repository is not archived or deleted. It remains available as a tombstone for future use if a concrete shared-contract requirement emerges post-pilot.
4. **Document this decision** — this ADR records the rationale and conditions for re-evaluation.

### Conditions for Re-evaluation

If any of the following become true, `jol-core` should be re-evaluated for Tier 0 reinstatement:

- A concrete use case emerges for shared Pydantic models or contract schemas consumed by 3+ repos.
- The pilot phase completes and the fleet scales beyond 29 repos, creating genuine need for enforced type contracts.
- A domain-driven design (DDD) initiative identifies bounded contexts that benefit from a shared kernel package.

## Consequences

- **Positive**: AGENTS.md ecosystem map now reflects empirical reality — no false Tier 0 claims.
- **Positive**: Audit trail is clean — ADR documents the decision with evidence-based rationale.
- **Positive**: Future contributors are not confused by an empty "contract" repo.
- **Negative**: If shared contracts become necessary post-pilot, the effort to populate `jol-core` (or create a new shared library repo) must be scoped and planned.
- **Risk**: LOW — the fleet already operates without `jol-core` as a dependency. No runtime behavior changes.

## Alternatives Considered

1. **Populate `jol-core` with domain models** — rejected. Massive effort (extracting models from 10+ repos, defining shared contracts, managing versioning) with no concrete use case. The fleet functions without it.
2. **Archive/delete `jol-core`** — rejected. Premature. The repo may serve a future purpose post-pilot. De-scoping preserves the option without creating false audit claims.
3. **Leave as-is (Tier 0 aspirational)** — rejected. Creates audit risk and contributor confusion. The AGENTS.md governance document must reflect reality.

## Compliance Impact

| Framework | Requirement | Before | After |
|-----------|-------------|--------|-------|
| **SOC 2** | CC8.1 (change management) | 🟡 Misleading ecosystem map | ✅ Accurate documentation |
| **ISO 27001** | A.8.8 (configuration management) | 🟡 Asset register inaccuracy | ✅ Accurate asset classification |
| **GDPR** | Art. 30 (records of processing) | 🟢 No impact | 🟢 No impact |

## Security Impact

**NONE.** De-scoping `jol-core` from Tier 0 is a documentation change only. No runtime behavior, no credentials, no network access, no deployment configuration is affected.

## Cross-Repo Dependency Impact

| Repo | Previous Claim | Actual State | Change |
|------|---------------|--------------|--------|
| `jol-rag-server` | Upstream: `jol-core` (models) | No import of `jol-core` | Remove from §2.1 upstream |
| `jol-mcp-servers` | Upstream: `jol-core` (shared audit/auth models) | No import of `jol-core` | Remove from §2.3 upstream |
| `jol-hermes-agents` | Future: `jol-core` domain models | No import of `jol-core` | Remove from §2.4 upstream |

## Rollback Strategy

To reinstate `jol-core` as Tier 0:
1. Populate the repo with actual shared library code (Pydantic models, contract schemas).
2. Add `pyproject.toml`, tests, CI, lockfile.
3. Reversing this ADR: update AGENTS.md ecosystem map to re-add `jol-core` to Tier 0.
4. Update cross-repo dependency sections to re-add upstream references.

## References

- AGENTS.md §1 (Repository Ecosystem Map)
- `docs/audit/architecture-assessment.md` — Finding H1
- `docs/audit/remediation-plan.md` — Batch 1
- Phase 3 dependency scan — confirmed no `jol-core` imports
- Phase 5 architecture scan — `jol-core` scored 4/17 (governance docs only)
