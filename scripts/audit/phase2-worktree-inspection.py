#!/usr/bin/env python3
"""Phase 2 deep read-only worktree inspection across all JOL repos.
Non-destructive: only reads git state. Detects divergence, stashes,
detached HEAD, local-only branches, and sensitive untracked files.
"""
import os
import subprocess
import json

REPO_ROOT = "/opt/jol/repos"
REPOS = [
    ".github", "jol-analytics-ai", "jol-auth", "jol-bitrix24-integration",
    "jol-compliance", "jol-core", "jol-devops", "jol-domain-taxonomy",
    "jol-ecommerce-engine", "jol-hermes-agents", "jol-hub", "jol-infrastructure",
    "jol-link-registry", "jol-llm", "jol-mcp-servers", "jol-rag-server",
    "jol-repo-template", "jol-scripts", "jol-security",
    "jol-site-basilica", "jol-site-cathedral", "jol-site-cemetery-care",
    "jol-site-deanery", "jol-site-diocese", "jol-site-funeral", "jol-site-orthodox",
    "jol-site-other-church", "jol-site-parish", "jol-site-protestant",
]

# Filename patterns that indicate potential secret exposure if untracked
SENSITIVE_PATTERNS = [".env", ".pem", ".key", "credentials", "secret", "id_rsa",
                       ".p12", ".pfx", "token", "vault", ".htpasswd", "serviceaccount"]

def run(args, cwd):
    return subprocess.run(args, capture_output=True, text=True, cwd=cwd)

def inspect(repo):
    path = os.path.join(REPO_ROOT, repo)
    info = {"repo": repo, "path": path, "exists": os.path.isdir(path)}
    if not info["exists"]:
        return info
    # current branch / detached
    b = run(["git", "branch", "--show-current"], path)
    info["branch"] = b.stdout.strip() or "(detached-HEAD)"
    info["detached"] = not b.stdout.strip()
    # local branch list
    branches = run(["git", "branch", "--format=%(refname:short)"], path).stdout.split()
    info["local_branches"] = branches
    # remote
    info["remote_origin"] = run(["git", "remote", "get-url", "origin"], path).stdout.strip()
    # HEAD sha
    info["head_sha"] = run(["git", "rev-parse", "--short", "HEAD"], path).stdout.strip()
    # upstream + divergence
    up = run(["git", "rev-parse", "--abbrev-ref", "@{u}"], path)
    if up.returncode == 0:
        info["upstream"] = up.stdout.strip()
        counts = run(["git", "rev-list", "--left-right", "--count", "HEAD...@{u}"], path)
        if counts.returncode == 0:
            ahead, behind = counts.stdout.strip().split("\t")
            info["ahead"] = int(ahead)
            info["behind"] = int(behind)
        else:
            info["ahead"] = info["behind"] = "ERR"
    else:
        info["upstream"] = "(none set)"
        info["ahead"] = info["behind"] = "N/A"
    # stash entries
    stash = run(["git", "stash", "list"], path).stdout.strip()
    info["stash_count"] = len([l for l in stash.split("\n") if l.strip()])
    # working tree porcelain
    por = run(["git", "status", "--porcelain"], path).stdout.splitlines()
    info["dirty_count"] = len(por)
    staged = [l for l in por if l[:2] not in ("??", " M", "MM ", "M ") and l[0] in "AMRDTCU"]
    info["staged_count"] = len([l for l in por if l[0] in "AMRD" and l[1] != " "])
    untracked = [l[3:] for l in por if l.startswith("?? ")]
    info["untracked_count"] = len(untracked)
    # in-progress merge/rebase
    info["merge_in_progress"] = os.path.exists(os.path.join(path, ".git", "MERGE_HEAD"))
    info["rebase_in_progress"] = (os.path.exists(os.path.join(path, ".git", "rebase-merge")) or
                                  os.path.exists(os.path.join(path, ".git", "rebase-apply")))
    # sensitive untracked detection
    sens = [u for u in untracked if any(p in u.lower() for p in SENSITIVE_PATTERNS)]
    info["sensitive_untracked"] = sens
    return info

def main():
    results = [inspect(r) for r in REPOS]
    out_path = "/opt/jol/repos/jol-infrastructure/.staging/phase2-inspection.json"
    with open(out_path, "w") as f:
        json.dump(results, f, indent=2)

    # Print a compact summary table
    print(f"{'repo':32s} {'branch':32s} {'det':4s} {'A/B':6s} {'dirt':4s} {'stash':5s} {'merge':5s} {'sens':4s}")
    for r in results:
        if not r.get("exists"):
            print(f"{r['repo']:32s} MISSING")
            continue
        ab = f"{r.get('ahead','?')}/{r.get('behind','?')}"
        det = "DET" if r["detached"] else ""
        mg = "MERGE" if r["merge_in_progress"] or r["rebase_in_progress"] else ""
        sens = str(len(r["sensitive_untracked"])) if r["sensitive_untracked"] else "0"
        print(f"{r['repo']:32s} {r['branch'][:32]:32s} {det:4s} {ab:6s} {r['dirty_count']:<4d} {r['stash_count']:<5d} {mg:5s} {sens:4s}")

    # Warnings
    print("\n=== WARNINGS ===")
    for r in results:
        if not r.get("exists"):
            print(f"[MISSING] {r['repo']}")
            continue
        if r["detached"]:
            print(f"[DETACHED-HEAD] {r['repo']}")
        if r["merge_in_progress"] or r["rebase_in_progress"]:
            print(f"[IN-PROGRESS] {r['repo']} has merge/rebase in progress")
        if r.get("behind") not in ("N/A", "ERR", None) and isinstance(r.get("behind"), int) and r["behind"] > 0:
            print(f"[BEHIND] {r['repo']} is {r['behind']} commits behind upstream")
        if isinstance(r.get("ahead"), int) and r["ahead"] > 0:
            print(f"[AHEAD] {r['repo']} has {r['ahead']} unpushed commit(s)")
        if r["stash_count"] > 0:
            print(f"[STASH] {r['repo']} has {r['stash_count']} stash entry(ies)")
        if r["sensitive_untracked"]:
            print(f"[SENSITIVE-UNTRACKED] {r['repo']}: {r['sensitive_untracked']}")
    print(f"\nFull data: {out_path}")

if __name__ == "__main__":
    main()
