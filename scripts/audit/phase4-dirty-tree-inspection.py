#!/usr/bin/env python3
"""Phase 4 dirty-tree inspection script.

Captures complete dirty state for each repo:
  - git status (porcelain)
  - git diff --stat (modified files summary)
  - git diff (full diff for modified files)
  - untracked files list
  - staged files list
  - branch state

Outputs structured JSON + per-repo text files for review.
"""
import json
import os
import subprocess
from pathlib import Path
from datetime import datetime

REPO_ROOT = Path("/opt/jol/repos")
OUTPUT_DIR = Path("/opt/jol/repos/jol-infrastructure/.staging/phase4-dirty-trees")
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

# Known dirty repos from Phase 2 inspection
DIRTY_REPOS = [
    "jol-analytics-ai",
    "jol-auth",
    "jol-compliance",
    "jol-core",
    "jol-hermes-agents",
    "jol-infrastructure",
    "jol-link-registry",
    "jol-llm",
    "jol-repo-template",
    "jol-devops",
    "jol-site-basilica",
    "jol-site-cathedral",
    "jol-site-cemetery-care",
    "jol-site-deanery",
    "jol-site-diocese",
    "jol-site-funeral",
    "jol-site-orthodox",
    "jol-site-other-church",
    "jol-site-parish",
    "jol-site-protestant",
]


def run_git(repo_path: Path, *args) -> tuple[int, str, str]:
    """Run git command, return (returncode, stdout, stderr)."""
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_path)] + list(args),
            capture_output=True,
            text=True,
            timeout=30,
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "TIMEOUT"


def inspect_repo(repo_name: str) -> dict:
    """Inspect a single repo's dirty state."""
    repo_path = REPO_ROOT / repo_name
    if not repo_path.exists():
        return {"repo": repo_name, "error": "NOT_FOUND"}

    info = {
        "repo": repo_name,
        "timestamp": datetime.now().isoformat(),
        "branch": "",
        "status_porcelain": "",
        "diff_stat": "",
        "diff_full": "",
        "untracked": [],
        "staged": [],
        "modified": [],
        "ahead_behind": "",
    }

    # Current branch
    rc, out, _ = run_git(repo_path, "rev-parse", "--abbrev-ref", "HEAD")
    if rc == 0:
        info["branch"] = out.strip()

    # Git status (porcelain)
    rc, out, _ = run_git(repo_path, "status", "--porcelain")
    if rc == 0:
        info["status_porcelain"] = out
        # Parse porcelain to categorize
        for line in out.splitlines():
            if not line.strip():
                continue
            status = line[:2]
            file = line[3:]
            if status == "??":
                info["untracked"].append(file)
            elif status[0] in "MADRC":
                info["staged"].append({"status": status, "file": file})
            elif status[1] in "MADRC":
                info["modified"].append(file)

    # Diff stat (modified files)
    rc, out, _ = run_git(repo_path, "diff", "--stat")
    if rc == 0:
        info["diff_stat"] = out

    # Full diff (modified files) — limit to first 5000 chars to avoid huge output
    rc, out, _ = run_git(repo_path, "diff")
    if rc == 0:
        info["diff_full"] = out[:5000] if len(out) > 5000 else out

    # Ahead/behind upstream
    rc, out, _ = run_git(repo_path, "rev-list", "--left-right", "--count", "HEAD...@{u}")
    if rc == 0:
        info["ahead_behind"] = out.strip()

    return info


def main():
    results = []
    for repo_name in DIRTY_REPOS:
        print(f"Inspecting {repo_name}...")
        info = inspect_repo(repo_name)
        results.append(info)

        # Write per-repo text file
        repo_file = OUTPUT_DIR / f"{repo_name}.txt"
        with open(repo_file, "w") as f:
            f.write(f"=== {repo_name} ===\n")
            f.write(f"Branch: {info.get('branch', 'UNKNOWN')}\n")
            f.write(f"Ahead/Behind: {info.get('ahead_behind', 'N/A')}\n\n")

            f.write("=== STATUS (porcelain) ===\n")
            f.write(info.get("status_porcelain", "(clean)") + "\n\n")

            f.write("=== DIFF STAT ===\n")
            f.write(info.get("diff_stat", "(none)") + "\n\n")

            f.write(f"=== UNTRACKED ({len(info.get('untracked', []))}) ===\n")
            for u in info.get("untracked", []):
                f.write(f"  {u}\n")
            f.write("\n")

            f.write(f"=== STAGED ({len(info.get('staged', []))}) ===\n")
            for s in info.get("staged", []):
                f.write(f"  {s['status']} {s['file']}\n")
            f.write("\n")

            f.write(f"=== MODIFIED ({len(info.get('modified', []))}) ===\n")
            for m in info.get("modified", []):
                f.write(f"  {m}\n")
            f.write("\n")

            f.write("=== DIFF (first 5000 chars) ===\n")
            f.write(info.get("diff_full", "(none)") + "\n")

    # Write JSON summary
    json_file = OUTPUT_DIR / "phase4-dirty-trees.json"
    with open(json_file, "w") as f:
        json.dump(results, f, indent=2)

    print(f"\nWrote {len(results)} repo inspections to {OUTPUT_DIR}")
    print(f"JSON summary: {json_file}")


if __name__ == "__main__":
    main()
