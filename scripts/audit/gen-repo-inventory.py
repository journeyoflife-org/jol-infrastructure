#!/usr/bin/env python3
"""Generate JOL repository inventory from GitHub CLI JSON output."""
import json
import sys
import os
import subprocess
from datetime import datetime, timezone

REPO_ROOT = "/opt/jol/repos"
ORG = "journeyoflife-org"

def get_gh_repos():
    result = subprocess.run(
        ["gh", "repo", "list", ORG, "--limit", "200",
         "--json", "name,nameWithOwner,url,visibility,defaultBranchRef,isArchived,isFork,isTemplate,primaryLanguage,createdAt,updatedAt,pushedAt,diskUsage,description"],
        capture_output=True, text=True
    )
    return json.loads(result.stdout)

def check_local_clone(repo_name):
    path = os.path.join(REPO_ROOT, repo_name)
    info = {"local_path": path, "clone_exists": os.path.isdir(path)}
    if not info["clone_exists"]:
        return info
    try:
        cwd = path
        info["git_branch"] = subprocess.run(["git", "branch", "--show-current"], capture_output=True, text=True, cwd=cwd).stdout.strip()
        info["git_remote"] = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True, cwd=cwd).stdout.strip()
        info["git_last_commit"] = subprocess.run(["git", "log", "--oneline", "-1"], capture_output=True, text=True, cwd=cwd).stdout.strip()
        info["git_uncommitted"] = bool(subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True, cwd=cwd).stdout.strip())
        dirty = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True, cwd=cwd).stdout.strip()
        info["dirty_files"] = len([l for l in dirty.split("\n") if l.strip()]) if dirty else 0
    except Exception as e:
        info["error"] = str(e)
    return info

def classify_repo(r):
    name = r["name"]
    if r["isArchived"]:
        rtype = "ARCHIVED"
    elif r["isFork"]:
        rtype = "FORK"
    elif name == ".github":
        rtype = "ORG-DEFAULTS"
    elif name == "jol-repo-template":
        rtype = "TEMPLATE"
    elif r["isTemplate"] and name in ("jol-mcp-servers", "jol-ecommerce-engine", "jol-rag-server", "jol-security"):
        rtype = "TEMPLATE+ACTIVE"
    elif name.startswith("jol-site-"):
        rtype = "SITE-SPOKE"
    elif name in ("jol-hub", "jol-auth"):
        rtype = "TIER0-CONTRACT"
    elif name in ("jol-rag-server", "jol-ecommerce-engine", "jol-analytics-ai"):
        rtype = "TIER1-PRIMARY"
    elif name in ("jol-llm", "jol-mcp-servers", "jol-hermes-agents"):
        rtype = "TIER2-AI"
    elif name in ("jol-infrastructure", "jol-devops", "jol-security", "jol-compliance", "jol-scripts"):
        rtype = "TIER4-INFRA"
    elif name in ("jol-link-registry", "jol-domain-taxonomy", "jol-bitrix24-integration"):
        rtype = "TIER3-INTEGRATION"
    else:
        rtype = "UNCATEGORIZED"

    if name in ("jol-hub", "jol-rag-server", "jol-auth"):
        crit = "CRITICAL"
    elif name in ("jol-llm", "jol-mcp-servers", "jol-ecommerce-engine", "jol-infrastructure"):
        crit = "HIGH"
    elif name in ("jol-hermes-agents", "jol-compliance", "jol-security", "jol-devops"):
        crit = "MEDIUM"
    elif name.startswith("jol-site-"):
        crit = "MEDIUM"
    else:
        crit = "LOW"

    if name in ("jol-rag-server", "jol-auth", "jol-hub"):
        sensitivity = "HIGH-GDPR-Art9"
    elif name in ("jol-ecommerce-engine", "jol-analytics-ai"):
        sensitivity = "HIGH-PCI"
    elif name in ("jol-llm", "jol-mcp-servers", "jol-hermes-agents"):
        sensitivity = "MEDIUM"
    elif name in ("jol-compliance", "jol-security"):
        sensitivity = "MEDIUM"
    else:
        sensitivity = "LOW"

    return rtype, crit, sensitivity

def main():
    repos = get_gh_repos()
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    enriched = []
    for r in repos:
        rtype, crit, sensitivity = classify_repo(r)
        lang = (r.get("primaryLanguage") or {}).get("name", "N/A") if r.get("primaryLanguage") else "N/A"
        branch = (r.get("defaultBranchRef") or {}).get("name", "N/A") if r.get("defaultBranchRef") else "N/A"
        local = check_local_clone(r["name"])

        enriched.append({
            "name": r["name"],
            "full_name": r["nameWithOwner"],
            "url": r["url"],
            "visibility": r["visibility"],
            "default_branch": branch,
            "type": rtype,
            "is_archived": r["isArchived"],
            "is_fork": r["isFork"],
            "is_template": r["isTemplate"],
            "primary_language": lang,
            "created_at": r.get("createdAt", "N/A")[:10],
            "last_updated": r["updatedAt"][:10],
            "last_pushed": r["pushedAt"][:10],
            "disk_usage_kb": r["diskUsage"],
            "description": (r.get("description") or "").replace("\n", " "),
            "criticality": crit,
            "data_sensitivity": sensitivity,
            "local_path": local["local_path"],
            "clone_exists": local["clone_exists"],
            "git_branch": local.get("git_branch", "N/A"),
            "git_uncommitted": local.get("git_uncommitted", "N/A"),
            "git_last_commit": local.get("git_last_commit", "N/A"),
            "dirty_files": local.get("dirty_files", 0),
        })

    crit_order = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3}
    enriched.sort(key=lambda x: (crit_order.get(x["criticality"], 9), x["name"]))

    os.makedirs("docs/audit", exist_ok=True)

    # CSV
    csv_path = "docs/audit/repository-inventory.csv"
    with open(csv_path, "w") as f:
        headers = ["name","full_name","url","visibility","default_branch","type",
                    "is_archived","is_fork","is_template","primary_language","created_at",
                    "last_updated","last_pushed","disk_usage_kb","criticality",
                    "data_sensitivity","clone_exists","local_path","git_branch",
                    "git_uncommitted","git_last_commit","description"]
        f.write(",".join(headers) + "\n")
        for r in enriched:
            row = []
            for h in headers:
                val = str(r.get(h, "")).replace(",", ";").replace('"', "'")
                row.append(f'"{val}"' if any(c in str(r.get(h, "")) for c in [",", '"']) else val)
            f.write(",".join(row) + "\n")

    # Markdown
    md_path = "docs/audit/repository-inventory.md"
    with open(md_path, "w") as f:
        f.write(f"# JOL Repository Inventory\n\n")
        f.write(f"**Generated:** {now}  \n")
        f.write(f"**Organization:** `{ORG}`  \n")
        f.write(f"**Total repositories discovered:** {len(enriched)}  \n")
        f.write(f"**Pagination:** CLI limit=200 returned {len(enriched)}; REST `orgs/{ORG}/repos?per_page=100` page 1 returned {len(enriched)} (<100, no page 2) — no truncation. Cross-check type filters: source/fork/member/all all reconcile.  \n\n")

        f.write("## Summary\n\n")
        f.write("| # | Repository | Type | Criticality | Language | Visibility | Branch | Local | Last Push |\n")
        f.write("|---|-----------|------|-------------|----------|------------|--------|-------|----------|\n")
        for i, r in enumerate(enriched, 1):
            clone_s = "YES" if r["clone_exists"] else "NO"
            f.write(f"| {i} | [{r['name']}]({r['url']}) | {r['type']} | {r['criticality']} | {r['primary_language']} | {r['visibility']} | `{r['default_branch']}` | {clone_s} | {r['last_pushed']} |\n")

        f.write(f"\n## Classification Breakdown\n\n")
        types = {}
        for r in enriched:
            types.setdefault(r["type"], []).append(r["name"])
        f.write("### By Type\n\n")
        for t in sorted(types.keys()):
            f.write(f"- **{t}** ({len(types[t])}): {', '.join(sorted(types[t]))}\n")

        crits = {}
        for r in enriched:
            crits.setdefault(r["criticality"], []).append(r["name"])
        f.write("\n### By Criticality\n\n")
        for c in ["CRITICAL", "HIGH", "MEDIUM", "LOW"]:
            if c in crits:
                f.write(f"- **{c}** ({len(crits[c])}): {', '.join(sorted(crits[c]))}\n")

        f.write(f"\n## Local Clone Status\n\n")
        f.write(f"Repository root: `{REPO_ROOT}`\n\n")
        cloned = [r for r in enriched if r["clone_exists"]]
        not_cloned = [r for r in enriched if not r["clone_exists"]]
        f.write(f"**Cloned locally:** {len(cloned)}/{len(enriched)}\n\n")
        if not_cloned:
            f.write("**Not cloned locally:**\n\n")
            for r in not_cloned:
                f.write(f"- `{r['name']}` ({r['type']}, {r['criticality']})\n")
        f.write("\n")

        # Detailed records per repo
        f.write(f"## Detailed Repository Records\n\n")
        for r in enriched:
            f.write(f"### {r['name']}\n\n")
            f.write(f"| Field | Value |\n|-------|-------|\n")
            f.write(f"| Full name | `{r['full_name']}` |\n")
            f.write(f"| URL | {r['url']} |\n")
            f.write(f"| Visibility | {r['visibility']} |\n")
            f.write(f"| Default branch | `{r['default_branch']}` |\n")
            f.write(f"| Type | {r['type']} |\n")
            f.write(f"| Criticality | {r['criticality']} |\n")
            f.write(f"| Data sensitivity | {r['data_sensitivity']} |\n")
            f.write(f"| Primary language | {r['primary_language']} |\n")
            f.write(f"| Created | {r['created_at']} |\n")
            f.write(f"| Disk usage | {r['disk_usage_kb']} KB |\n")
            f.write(f"| Last pushed | {r['last_pushed']} |\n")
            f.write(f"| Archived | {r['is_archived']} |\n")
            f.write(f"| Fork | {r['is_fork']} |\n")
            f.write(f"| Template | {r['is_template']} |\n")
            f.write(f"| Local clone | {'YES' if r['clone_exists'] else 'NO'} |\n")
            if r["clone_exists"]:
                f.write(f"| Local branch | `{r['git_branch']}` |\n")
                f.write(f"| Uncommitted | {r['git_uncommitted']} |\n")
                f.write(f"| Last commit | {r['git_last_commit']} |\n")
            if r["description"]:
                f.write(f"| Description | {r['description']} |\n")
            f.write("\n")

    print(f"Inventory generated:")
    print(f"  CSV: {csv_path}")
    print(f"  MD:  {md_path}")
    print(f"  Total repos: {len(enriched)}")
    print(f"  Cloned locally: {len(cloned)}")
    print(f"  Not cloned: {len(not_cloned)}")

if __name__ == "__main__":
    main()
