# Runbook: GitHub Branch-Protection Audit

## Overview
Procedure for auditing effective branch-protection posture across the `journeyoflife-org` GitHub fleet.

**SOC 2 CC6.1**: logical access controls enforced on default branches.
**SOC 2 CC8.1**: change-management gates require reviewed PRs before merge.
**ISO 27001 A.8.32**: change-management controls verified per-repo.

## Prerequisites
- `gh` CLI authenticated with a token that has `repo` + `read:org` scopes
- `jq` installed
- Fleet repo list: `gh repo list journeyoflife-org --limit 100 --json name --jq '.[].name'`

## Critical: Two-Layer Enforcement Model

GitHub enforces branch policy through **two independent layers** that can disagree per repo:

| Layer | API endpoint | Scope |
|-------|-------------|-------|
| **Classic branch protection** | `GET /repos/{org}/{repo}/branches/{branch}/protection` | Per-branch, legacy REST API |
| **Rulesets** | `GET /repos/{org}/{repo}/rulesets` → `GET .../rulesets/{id}` | Org-wide or repo-level, newer UI |

**Effective posture = classic ∪ rulesets targeting the default branch.**

A classic-only audit mis-scopes review requirements: a repo with `require_code_owner_reviews=false` in the classic API may still be gated by an org/repo ruleset with `require_code_owner_review=true`, and vice versa.

### The `~DEFAULT_BRANCH` Trap

In ruleset conditions, the `~` prefix on a `ref_name.include` token means **EXCLUDE**:

```yaml
# This ruleset applies to everything EXCEPT main:
conditions:
  ref_name:
    include: ["~DEFAULT_BRANCH"]   # ← EXCLUDES the default branch
    exclude: []
```

A ruleset with `~DEFAULT_BRANCH` or `~master` silently leaves `main` unprotected. Always verify that `.conditions.ref_name.include` contains an explicit positive reference (`refs/heads/main` or `~DEFAULT_BRANCH` is NOT present).

## Procedure

### 1. Enumerate Repos and Default Branches

```bash
for repo in $(gh repo list journeyoflife-org --limit 100 --json name --jq '.[].name'); do
  default=$(gh api "repos/journeyoflife-org/$repo" --jq '.default_branch')
  echo "$repo → $default"
done
```

### 2. Query Classic Branch Protection

```bash
# Returns "Branch not protected" (exit 1) for repos without classic protection
gh api "repos/journeyoflife-org/$repo/branches/main/protection" 2>/dev/null \
  --jq '{
    required_reviews: .required_pull_request_reviews.required_approving_review_count,
    code_owner_reviews: .required_pull_request_reviews.require_code_owner_reviews,
    status_checks: (.required_status_checks.contexts // [] | length),
    force_push_blocked: .allow_force_pushes.enabled | not,
    deletion_blocked: .allow_deletions.enabled | not
  }'
```

**Trap**: `require_code_owner_reviews: false` here does NOT mean "no review gate" — a ruleset may still enforce it.

### 3. Query Rulesets (Per Repo, By ID)

```bash
# List endpoint returns compact objects WITHOUT .rules — must read by ID
ruleset_ids=$(gh api "repos/journeyoflife-org/$repo/rulesets" --jq '.[].id')

for id in $ruleset_ids; do
  gh api "repos/journeyoflife-org/$repo/rulesets/$id" --jq '{
    id: .id,
    name: .name,
    enforcement: .enforcement,
    include: .conditions.ref_name.include,
    exclude: .conditions.ref_name.exclude,
    review_count: (.rules[] | select(.type=="pull_request") | .parameters.required_approving_review_count // 0),
    code_owner: (.rules[] | select(.type=="pull_request") | .parameters.require_code_owner_review // false),
    has_pr_rule: ([.rules[].type] | any(. == "pull_request"))
  }'
done
```

### 4. Compute Effective Posture

For each repo, combine both layers:

```
effective_review_gate =
  classic.require_code_owner_reviews == true
  OR
  any ruleset WHERE:
    .enforcement == "active"
    AND .conditions.ref_name.include contains "refs/heads/main"
        (or the default branch name — NOT "~DEFAULT_BRANCH")
    AND .rules contains type=="pull_request"
```

**Audit script** (produces a summary table):

```bash
for repo in $(gh repo list journeyoflife-org --limit 100 --json name --jq '.[].name'); do
  # Classic layer
  classic_co=$(gh api "repos/journeyoflife-org/$repo/branches/main/protection" 2>/dev/null \
    --jq '.required_pull_request_reviews.require_code_owner_reviews // false' 2>/dev/null || echo "false")

  # Ruleset layer — check each ruleset by ID
  ruleset_gate="false"
  for id in $(gh api "repos/journeyoflife-org/$repo/rulesets" --jq '.[].id' 2>/dev/null); do
    include=$(gh api "repos/journeyoflife-org/$repo/rulesets/$id" \
      --jq '.conditions.ref_name.include | join(",")' 2>/dev/null)
    has_pr=$(gh api "repos/journeyoflife-org/$repo/rulesets/$id" \
      --jq '[.rules[].type] | any(. == "pull_request")' 2>/dev/null)
    # Positive include (not ~DEFAULT_BRANCH) + has PR rule
    if [[ "$include" != *"~"* ]] && [[ "$has_pr" == "true" ]]; then
      ruleset_gate="true"
      break
    fi
  done

  effective="UNPROTECTED"
  [[ "$classic_co" == "true" || "$ruleset_gate" == "true" ]] && effective="GATED"

  printf "%-35s classic=%-5s ruleset=%-5s effective=%s\n" \
    "$repo" "$classic_co" "$ruleset_gate" "$effective"
done
```

### 5. Verify CODEOWNERS Resolution

Even with a review gate, the gate is **procedural** (not substantive) if CODEOWNERS references a dead team:

```bash
# Check each repo's CODEOWNERS for team references that return 404
gh api "repos/journeyoflife-org/$repo/contents/.github/CODEOWNERS" \
  --jq '.content' | base64 -d | grep -oP '@[\w-]+/[\w-]+' | while read -r team; do
  slug=$(echo "$team" | sed 's|@||')
  status=$(gh api "orgs/$(echo $slug | cut -d/ -f1)/teams/$(echo $slug | cut -d/ -f2)" \
    --jq '.id' 2>&1)
  [[ $? -ne 0 ]] && echo "DEAD: $team (404)"
done
```

### 6. Record Findings

Log the audit results in a change record under `docs/compliance/evidence/` with:
- Per-repo effective-posture table (classic / ruleset / effective)
- Any gaps identified (UNPROTECTED repos, dead CODEOWNERS refs)
- Remediation steps with command-level evidence

## Rollback

This is a read-only audit — no rollback needed. If remediation is executed:
1. Snapshot the repo settings before changes (`gh api .../rulesets/<id>` → save JSON)
2. Apply changes via `gh api` or GitHub UI
3. Re-run this audit to verify

## Documentation

Log audit execution in `CHANGELOG.md` with ticket reference and evidence file path.
