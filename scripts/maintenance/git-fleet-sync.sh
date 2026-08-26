#!/usr/bin/env bash
# git-fleet-sync.sh — audited bulk git sync for the JOL repository fleet.
#
# Supersedes the draft `git-bulk-push.sh` (reviewed 2026-08-26, 4 defects):
#   D1  blind `git add -A`          -> staging is OPT-IN (--stage) with a
#                                      pre-commit secret-path preflight scan
#   D2  `git commit || true`        -> commit failures (e.g. pre-commit hook
#                                      rejections) are recorded as FAIL and
#                                      the repo is NEVER pushed
#   D3  set -e abort on no-remote   -> per-repo remote verification, error
#                                      aggregation, summary + exit code
#   D4  prod-deploy remotes pushed  -> SKIP list + production-remote refusal
#                                      (jol-mcp-servers' mcp-prod triggers a
#                                      live post-receive deploy on push)
#
# Modes:
#   (default)   read-only fleet status report (non-destructive)
#   --stage     additionally stage + commit dirty repos (message REQUIRED)
#   --push      additionally push (only committed repos with safe remotes)
#   --yes       non-interactive; without it each mutating repo needs 'y'
#
# SOC 2 CC8.1: do not run --stage/--push without a change record (issue +
# rollback plan). Every run prints a machine-readable summary for evidence.
#
# Usage:
#   git-fleet-sync.sh                          # report only
#   git-fleet-sync.sh --stage -m "chore: ..." --yes
#   git-fleet-sync.sh --stage --push -m "feat: ..." 
set -uo pipefail   # NOTE: deliberately NOT `set -e` (D3): one failing repo
                   # must not abort the fleet pass; failures are aggregated.

REPO_ROOTS=("/opt/jol/repos" "/opt/jol-m/repos")

# D4: repos that must never be touched by bulk sync.
#   jol-mcp-servers       -> remote 'mcp-prod' = production deploy push
#   jol-qoder-history     -> no remote; Tier-1 sensitive exports
#   jol-m-qoder-history   -> no remote; Tier-1 sensitive exports (tree B)
SKIP_LIST=("jol-mcp-servers" "jol-qoder-history" "jol-m-qoder-history")

# D4: remote names matching these patterns are treated as production
# deployment channels and refuse bulk push even if not in SKIP_LIST.
PROD_REMOTE_RE='(prod|deploy|release)'

# D1: preflight scan — staged paths matching these patterns refuse the commit.
SECRET_PATH_RE='(^|/)(\.env(\..*)?$|.*\.pem$|.*\.key$|id_[a-z]+$|.*\.p12$|.*\.pfx$|credentials.*\.json$|.*vault.*pass.*$|.*token$|secrets?\.ya?ml$)'

MODE_REPORT=1; MODE_STAGE=0; MODE_PUSH=0; ASSUME_YES=0; COMMIT_MSG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) MODE_STAGE=1; MODE_REPORT=0 ;;
    --push)  MODE_PUSH=1; MODE_STAGE=1; MODE_REPORT=0 ;;
    --yes)   ASSUME_YES=1 ;;
    -m)      COMMIT_MSG="${2:-}"; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ $MODE_STAGE -eq 1 && -z "$COMMIT_MSG" ]]; then
  echo "FATAL: --stage requires -m \"<commit message>\"" >&2; exit 2
fi

log() { printf '%s\n' "$*" ; }   # stdout only, so tee capture works

declare -A RESULT   # repo -> status
declare -A DETAIL   # repo -> detail
COUNT_TOTAL=0 COUNT_CLEAN=0 COUNT_OK=0 COUNT_FAIL=0 COUNT_SKIP=0

in_skip_list() {
  local name="$1" s
  for s in "${SKIP_LIST[@]}"; do [[ "$name" == "$s" ]] && return 0; done
  return 1
}

secret_path_preflight() {   # repo dir; returns 1 + prints offenders on hit
  local repo="$1" hits
  hits=$(cd "$repo" && { git diff --cached --name-only; git ls-files --others --exclude-standard; } \
         | grep -E "$SECRET_PATH_RE" || true)
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | sed 's/^/      BLOCKED PATH: /'
    return 1
  fi
  return 0
}

confirm() {   # prompt unless --yes
  [[ $ASSUME_YES -eq 1 ]] && return 0
  read -r -p "      proceed? [y/N] " ans; [[ "$ans" == "y" || "$ans" == "Y" ]]
}

sync_repo() {
  local repo="$1" name root
  name=$(basename "$repo"); root=$(dirname "$repo")
  COUNT_TOTAL=$((COUNT_TOTAL + 1))

  if in_skip_list "$name"; then
    RESULT[$name]="SKIP"; DETAIL[$name]="on skip list (prod-deploy remote / no remote / Tier-1 exports)"
    COUNT_SKIP=$((COUNT_SKIP + 1)); return
  fi
  if [[ ! -d "$repo/.git" ]]; then
    RESULT[$name]="SKIP"; DETAIL[$name]="not a git repository"
    COUNT_SKIP=$((COUNT_SKIP + 1)); return
  fi
  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    RESULT[$name]="FAIL"; DETAIL[$name]="git unusable (dubious ownership? add scoped safe.directory)"
    COUNT_FAIL=$((COUNT_FAIL + 1)); return
  fi

  local dirty branch remote
  dirty=$(git -C "$repo" status --porcelain | wc -l)
  branch=$(git -C "$repo" branch --show-current)
  remote=$(git -C "$repo" remote | head -1)

  if [[ $MODE_REPORT -eq 1 ]]; then
    RESULT[$name]="REPORT"
    DETAIL[$name]="branch=${branch:-DETACHED} dirty=$dirty remote=${remote:-NONE}"
    COUNT_CLEAN=$((COUNT_CLEAN + 1)); return
  fi

  if [[ "$dirty" -eq 0 ]]; then
    RESULT[$name]="CLEAN"; DETAIL[$name]="nothing to commit (branch=$branch)"
    COUNT_CLEAN=$((COUNT_CLEAN + 1)); return
  fi

  log "-> $name (root=$root)"
  git -C "$repo" status --short | sed 's/^/    /'

  # D1: opt-in staging with secret-path preflight
  if ! confirm; then
    RESULT[$name]="SKIP"; DETAIL[$name]="declined by operator"
    COUNT_SKIP=$((COUNT_SKIP + 1)); return
  fi
  git -C "$repo" add -A
  if ! secret_path_preflight "$repo"; then
    git -C "$repo" reset -q          # non-destructive undo of staging
    RESULT[$name]="FAIL"; DETAIL[$name]="secret-path preflight BLOCKED staging (staging reverted)"
    COUNT_FAIL=$((COUNT_FAIL + 1)); return
  fi

  # D2: NO `|| true` — hook rejection is a hard failure, never pushed
  if ! git -C "$repo" commit -m "$COMMIT_MSG"; then
    RESULT[$name]="FAIL"; DETAIL[$name]="commit rejected (pre-commit hooks / signing); NOT pushed"
    COUNT_FAIL=$((COUNT_FAIL + 1)); return
  fi

  if [[ $MODE_PUSH -eq 1 ]]; then
    # D3: verify remote exists before push; aggregate, do not abort fleet
    if [[ -z "$remote" ]]; then
      RESULT[$name]="PARTIAL"; DETAIL[$name]="committed; NO remote configured - push skipped"
      COUNT_OK=$((COUNT_OK + 1)); return
    fi
    # D4: refuse production deployment channels
    if [[ "$remote" =~ $PROD_REMOTE_RE ]]; then
      RESULT[$name]="PARTIAL"
      DETAIL[$name]="committed; remote '$remote' matches prod pattern - push REFUSED (deploy channel)"
      COUNT_OK=$((COUNT_OK + 1)); return
    fi
    if ! git -C "$repo" ls-remote --exit-code "$remote" >/dev/null 2>&1; then
      RESULT[$name]="PARTIAL"; DETAIL[$name]="committed; remote '$remote' unreachable - push skipped"
      COUNT_OK=$((COUNT_OK + 1)); return
    fi
    if git -C "$repo" push "$remote" "$branch"; then
      RESULT[$name]="PUSHED"; DETAIL[$name]="committed + pushed to $remote/$branch"
      COUNT_OK=$((COUNT_OK + 1)); return
    fi
    RESULT[$name]="FAIL"; DETAIL[$name]="committed; push FAILED (branch protection? auth?)"
    COUNT_FAIL=$((COUNT_FAIL + 1)); return
  fi

  RESULT[$name]="COMMITTED"; DETAIL[$name]="committed on $branch (no push requested)"
  COUNT_OK=$((COUNT_OK + 1))
}

echo "=== JOL Fleet Sync ==="
echo "mode: $([[ $MODE_REPORT -eq 1 ]] && echo report || { [[ $MODE_PUSH -eq 1 ]] && echo "stage+commit+push" || echo "stage+commit"; })"
[[ $MODE_STAGE -eq 1 ]] && echo "commit message: $COMMIT_MSG"
echo "skip list: ${SKIP_LIST[*]}"
echo ""

for root in "${REPO_ROOTS[@]}"; do
  echo "--- scanning $root ---"
  [[ -d "$root" ]] || { echo "  (absent)"; continue; }
  for repo in "$root"/*/; do
    [[ -d "$repo" ]] || continue
    sync_repo "${repo%/}"
  done
done

echo ""
echo "=== SUMMARY ==="
for root in "${REPO_ROOTS[@]}"; do
  for repo in "$root"/*/; do
    name=$(basename "${repo%/}")
    [[ -v "RESULT[$name]" ]] || continue
    printf "  %-26s %-9s %s\n" "$name" "${RESULT[$name]}" "${DETAIL[$name]}"
  done
done
echo ""
echo "total=$COUNT_TOTAL clean/report=$COUNT_CLEAN ok=$COUNT_OK skipped=$COUNT_SKIP FAILED=$COUNT_FAIL"
[[ $COUNT_FAIL -gt 0 ]] && exit 1
exit 0
