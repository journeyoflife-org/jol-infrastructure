#!/usr/bin/env python3
"""check-doc-claims.py — prose claims about controls must be re-checkable, not permanent.

WHY THIS EXISTS (docs/audit/self-audit-control-effectiveness-20261105.md §11, findings
F-40..F-47). This repository applies real rigour to shell gates: 370 fixture assertions
extract the gate's own text from the file under test and prove it can fail. It applied
none of that rigour to the PROSE that describes the controls — workflow header comments,
`AGENTS.md` open-item lists, Makefile justifications, evidence lines. Eight findings in one
audit, and every one was a sentence that was true when written and was never re-measured.

F-42 is the purest instance: `.git/hooks/pre-commit` was genuinely absent at
2026-11-01T16:31Z and was created at 16:35:52Z the same day. The observation had a
five-minute shelf life, was written into six files as "has never been installed", and was
still being copied into NEW code by a second session four days later.

THE RULE THIS ENFORCES
    A mutable state is cited with the instant it was observed, never as a permanent
    property. "has never existed" is unfalsifiable by construction — no future measurement
    can satisfy it, and one contrary measurement destroys it.

FOUR CLAIM CLASSES, each decidable from text the repository already has:

  A  workflow-comment branches must exist in the workflow's own `on:` block (F-45).
     `infra-validate.yml:4` advertises `feature/*`; the config lists only main and develop.

  B  a permanence claim about a mutable state must carry an instant nearby (F-42, F-47).

  C  a pre-commit hook's `files:` trigger must not be broader than its checker's corpus
     (F-44). `record-stamps` fires on every `docs/**.md` but reads a fixed 8-file list, so
     it reports PASS about files it never opened — including the audit that reports this.

  D  a gate asserted PASSES/MET in `AGENTS.md` must not also be listed in that section's
     "Tracked open items" (F-46). Both statements were present for the VMID-100 backup.

DEBT IS BASELINED AND MAY ONLY SHRINK — the pattern `check-changelog-table.py` already uses
for the 12 placeholder tickets. Several defects live in files a concurrent session has
staged, so fixing them here would be reverted by its next commit (last-writer-wins). They
are recorded as named debt instead: the count can never rise, and closing one means
deleting its baseline entry, which is the only way the ratchet moves.

SCOPE NOTE: `docs/audit/**` is deliberately excluded from class B. An audit quotes the
defect it reports verbatim; a quotation is not an assertion. Every other tracked text file
is in scope.

Usage:
    check-doc-claims.py            # scan the repo; exit 0 clean, 1 findings
    check-doc-claims.py --self-test # prove each class can FAIL (fixtures), then scan
"""

from __future__ import annotations

import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# ---------------------------------------------------------------- class A ----
# A branch glob advertised in a comment must be a real trigger. Decidable: take
# glob-ish tokens (`name/*`) from comment lines, take branch entries from the
# `on:` block, and require the first set to be a subset of the second.
# The trailing lookahead is NOT `\b`: `*` is a non-word character, so `\b` after it
# requires a following word character and therefore NEVER matches `feature/*` at end of
# comment. The first draft used `\b`, which made the detector blind and left three of its
# four fixtures passing vacuously — only the detection fixture went red, and it did.
COMMENT_GLOB = re.compile(r"\b([a-z][a-z0-9_-]*/\*)(?![\w*])")
BRANCH_LINE = re.compile(r"^\s*-\s+([A-Za-z0-9_.*\-/]+)\s*$")

# Baseline debt for class A: (workflow filename, advertised glob).
CLASS_A_DEBT = {
    # F-45: `.github/workflows/infra-validate.yml:4` says "push/PR to main, develop,
    # feature/*"; `on.push.branches`/`on.pull_request.branches` list only main, develop.
    # The file is staged AND unstaged in a concurrent session's index, so a fix landed
    # here would be reverted by its next commit. Owed to that session.
    ("infra-validate.yml", "feature/*"),
}


def class_a(text: str) -> list[str]:
    """Return branch globs advertised in comments but absent from the on: block."""
    in_on = False
    branches: set[str] = set()
    advertised: set[str] = set()
    for raw in text.splitlines():
        line = raw.rstrip()
        stripped = line.lstrip()
        if stripped.startswith("#"):
            advertised.update(COMMENT_GLOB.findall(stripped))
            continue
        if re.match(r"^on:\s*$", line):
            in_on = True
            continue
        if in_on:
            # A new top-level key ends the on: block.
            if re.match(r"^[A-Za-z]", line):
                in_on = False
                continue
            m = BRANCH_LINE.match(line)
            if m:
                branches.add(m.group(1))
    return sorted(advertised - branches)


# ---------------------------------------------------------------- class B ----
# Permanence language about a state that can change. The escape hatch is an
# instant in the same window: dated claims are re-checkable, permanent ones are not.
PERMANENCE = re.compile(
    r"(has|had|have)\s+never\s+(been\s+installed|existed)"
    r"|never\s+been\s+installed"
    r"|never\s+existed\s+on\s+this\s+working\s+copy",
    re.IGNORECASE,
)
# Exemption is by QUOTATION, not by proximity of a date — the same principle
# `check-record-stamps.py` uses with its `stamp-quoted` token. The first draft exempted a
# claim when any instant appeared within 400 chars, and that was measurably too weak: all
# four real F-42 files carry a nearby date, but the date belongs to a DIFFERENT measurement
# (e.g. "Measured 2026-11-01: no CI job invoked it" beside an undated hook-absence claim),
# so every genuine defect was exempted and the class detected nothing. "has never" is
# unfalsifiable by construction — no future measurement can satisfy it and one contrary
# measurement destroys it — so the only acceptable use of the phrase is quoting it in order
# to retract it. Backticks are deliberately NOT quote characters: they mark code spans
# (`.git/hooks/pre-commit`), and treating them as quotes would exempt the Makefile instance.
QUOTE_CHARS = "\"'\u201c\u201d\u2018\u2019"

# These claims wrap across lines, and every continuation line restarts with a comment
# marker (`#`, `@#`, `//`, `*`, `<!--`, `>`), so a pattern matching `never\s+existed`
# cannot cross the break — the real Makefile instance reads `…has never` / `@# existed…`.
# Normalise first (strip each line's leading comment marker, join with single spaces) and
# carry a char->line map so findings still report an original line number. This is the
# probe defect that hid the Makefile occurrence from the first census of F-42 (audit §1).
COMMENT_PREFIX = re.compile(r"^\s*(?:@?#{1,6}|/{2,}|<!--|\*|>)\s*")


def _join_comment_wrapped(text: str) -> tuple[str, list[int]]:
    parts: list[str] = []
    linemap: list[int] = []
    for i, ln in enumerate(text.splitlines(), 1):
        s = COMMENT_PREFIX.sub("", ln).rstrip()
        if parts:
            linemap.append(i)  # the joining space belongs to the later line
        parts.append(s)
        linemap.extend([i] * len(s))
    return " ".join(parts), linemap

# Class B debt: file -> number of ASSERTED permanence claims tolerated. Counts were
# produced by running this checker, not estimated; a guessed baseline is what made the
# first draft report four files as clean.
CLASS_B_DEBT = {
    # F-42, the hook-absence claim class. Contended file: staged AND unstaged in a
    # concurrent session's index, so a fix landed here is reverted by its next commit.
    # L47/L48 are outside that session's hunks and are owed to it; L66 and L109 are
    # inside its layers and must not be edited from here.
    ".github/workflows/infra-validate.yml": 3,
    # F-42: the `lint-stamps` recipe justification. NOT in HEAD — it is the concurrent
    # session's in-flight insertion, written after 46340fd corrected the same claim
    # elsewhere. Scanned by NAME because it has no extension; the first draft's extension
    # filter skipped the Makefile entirely, so F-42's Makefile instance escaped class B.
    "Makefile": 1,
    # Immutable CC8.1 ledger rows (F-42). Corrected by a NEW row, never by editing these.
    "CHANGELOG.md": 2,
    # Change History rows: 339 records the gate-13 rewrite that genuinely was never
    # installed on the host (a true historical fact), 887 is a ledger row. Neither is
    # editable; both are re-checkable only against the host.
    "docs/runbooks/hv01-storage-backup-reconfiguration.md": 2,
    # Point-in-time evidence records (F-47 class): accurate when taken, stated timelessly.
    "docs/compliance/evidence/hv01-storage-inspection-20261021.txt": 1,
    "docs/servers/her-prod-lt01.md": 1,
    "docs/servers/pve-prod-hv01.md": 1,
    # Both say "/dev/sdb1, a device/node that has never existed". Legitimate prose, but the
    # rule is deliberately broad: "this host has no such device node" says the same thing
    # and stays true when re-measured. Rephrase to clear, do not baseline forever.
    "scripts/maintenance/backup-workstation-home.sh": 1,
    "scripts/maintenance/provision-jolhome-disk.sh": 1,
}
CLASS_B_EXCLUDE_PREFIXES = ("docs/audit/",)
# Extension-less tracked files that still carry prose claims about controls.
CLASS_B_EXTRA_NAMES = ("Makefile",)
# A detector's own source necessarily contains the pattern it detects: its self-test
# fixtures ARE synthetic violations. `check-record-stamps.py` sets the same precedent by
# keeping itself out of DEFAULT_FILES. This exclusion was found the hard way — the live
# scan looked green only while this file was still UNTRACKED (`git ls-files` skipped it);
# the hermetic throwaway-repo fixture in tests/test-doc-claims.sh staged it and caught the
# self-flag, which is why that fixture proves detection end to end and not just per-function.
CLASS_B_SELF = os.path.relpath(os.path.abspath(__file__), REPO)


def class_b(text: str) -> list[int]:
    """Return 1-based line numbers of ASSERTED permanence claims.

    A quoted mention is exempt — it is discussing the phrase in order to retract it, which
    is what `check-changelog-table.py`'s corrected docstring and this module's own docstring
    do. Matched against a comment-normalised, line-joined copy of the text: these sentences
    wrap, and a line-at-a-time grep misses them. That probe defect cost the first census of
    F-42 an entire file (the Makefile) — see the audit §1 Rule 1.
    """
    norm, linemap = _join_comment_wrapped(text)
    hits: set[int] = set()
    for m in PERMANENCE.finditer(norm):
        before = norm[max(0, m.start() - 3):m.start()]
        after = norm[m.end():m.end() + 3]
        if any(q in before for q in QUOTE_CHARS) and any(q in after for q in QUOTE_CHARS):
            continue  # a quotation of the phrase, not an assertion of it
        if m.start() < len(linemap):
            hits.add(linemap[m.start()])
    return sorted(hits)


# ---------------------------------------------------------------- class C ----
# A hook that passes no filenames and reads a hardcoded corpus must not fire on
# paths outside that corpus. Decidable without inventing paths: enumerate the
# tracked files the trigger regex matches, and count those the corpus omits.
def _hook_blocks(text: str) -> list[dict]:
    """Parse the local-hook entries of .pre-commit-config.yaml into dicts."""
    hooks: list[dict] = []
    cur: dict | None = None
    for raw in text.splitlines():
        line = raw.rstrip()
        m = re.match(r"^\s*-\s+id:\s*(\S+)\s*$", line)
        if m:
            if cur:
                hooks.append(cur)
            cur = {"id": m.group(1)}
            continue
        if cur is None:
            continue
        for key in ("entry", "files", "pass_filenames"):
            km = re.match(r"^\s*%s:\s*(.+?)\s*$" % key, line)
            if km:
                cur[key] = km.group(1).strip()
    if cur:
        hooks.append(cur)
    return hooks


def _default_files(checker_src: str) -> list[str]:
    m = re.search(r"DEFAULT_FILES\s*=\s*[\[(](.*?)[\])]", checker_src, re.S)
    if not m:
        return []
    return re.findall(r"""["']([^"']+)["']""", m.group(1))


def class_c(config_text: str, tracked: list[str], read_src) -> list[str]:
    """Return '<hook>: N trigger-matched files outside its corpus' violations."""
    out: list[str] = []
    for hook in _hook_blocks(config_text):
        if hook.get("pass_filenames", "").lower() != "false":
            continue
        entry = hook.get("entry", "")
        cm = re.search(r"(scripts/maintenance/check-[\w.-]+\.py)", entry)
        if not cm:
            continue
        try:
            corpus = set(_default_files(read_src(cm.group(1))))
        except OSError:
            continue
        if not corpus:
            continue
        pattern = hook.get("files", "")
        if not pattern:
            continue
        rx = re.compile(pattern)
        matched = [p for p in tracked if rx.match(p)]
        uncovered = sorted(set(matched) - corpus)
        if uncovered:
            out.append("%s:%d" % (hook["id"], len(uncovered)))
    return out


CLASS_C_DEBT = {
    # F-44: fires on every docs/**.md and AGENTS.md, reads a fixed 8-file list. The fix
    # needs `pass_filenames: true` plus filename support in the checker, and
    # check-record-stamps.py is staged+unstaged in a concurrent session's index.
    #
    # The VALUE is informational only — the gate keys on the hook NAME. The first draft
    # gated on the uncovered-file count (126), and committing the audit document that
    # reports F-44 pushed it to 127, reddening the gate for a reason unrelated to the
    # defect: every new docs/**.md grows that number. A metric that moves with ordinary
    # repo growth trains people to bump the baseline instead of fixing the control, so
    # the structural condition is gated and the magnitude is merely reported.
    "record-stamps": 126,
}


# ---------------------------------------------------------------- class D ----
# AGENTS.md must not assert a gate is met and list the same gate as open.
OPEN_ITEMS_HEADER = re.compile(r"Tracked open items", re.IGNORECASE)
MET = re.compile(r"\b(?:PASSES|gate is MET|PASSED)\b")


def class_d(text: str) -> list[str]:
    """Return subjects asserted MET and simultaneously listed as open."""
    lines = text.splitlines()
    open_idx = [i for i, ln in enumerate(lines) if OPEN_ITEMS_HEADER.search(ln)]
    if not open_idx:
        return []
    # The open-items block runs to the next section heading.
    start = open_idx[0]
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if re.match(r"^#{2,3}\s", lines[j]) or lines[j].startswith("### "):
            end = j
            break
    block = "\n".join(lines[start:end])
    subjects = set(re.findall(r"VMID\s+(\d+)", block))
    if not subjects:
        return []
    out = []
    for vmid in sorted(subjects):
        # A MET assertion naming the same VMID *and* the same subject (backup).
        for ln in lines:
            if ("VMID %s" % vmid in ln or "vm/%s" % vmid in ln) and MET.search(ln) \
                    and "backup" in ln.lower():
                out.append("VMID %s asserted MET while listed open" % vmid)
                break
    return out


CLASS_D_DEBT = {
    # F-46: AGENTS.md §2.1 checklist says the VMID-100 backup gate PASSES and is MET
    # with 9 consecutive OK runs and three drills; §2.1 "Tracked open items" in the
    # SAME section still says "no off-host VM backup of VMID 100 (RPO/RTO not met)".
    # AGENTS.md carries a concurrent session's unstaged edits, so it is not touched here.
    "VMID 100 asserted MET while listed open": 1,
}


# ------------------------------------------------------------- driver --------
def tracked_files() -> list[str]:
    r = subprocess.run(["git", "-C", REPO, "ls-files"],
                       capture_output=True, text=True, check=True)
    return [p for p in r.stdout.split() if not p.startswith(".staging/")]


def read_src(rel: str) -> str:
    with open(os.path.join(REPO, rel), encoding="utf-8", errors="replace") as fh:
        return fh.read()


def scan() -> tuple[list[str], list[str]]:
    """Return (violations, debt_notes). Violations are NEW problems only."""
    viol: list[str] = []
    notes: list[str] = []
    files = tracked_files()

    # --- class A
    for wf in sorted(p for p in files if p.startswith(".github/workflows/")
                     and p.endswith((".yml", ".yaml"))):
        for glob in class_a(read_src(wf)):
            key = (os.path.basename(wf), glob)
            if key in CLASS_A_DEBT:
                notes.append("A debt %s advertises %s (not a trigger)" % key)
            else:
                viol.append("A: %s advertises branch glob %s that its on: block does not "
                            "list — a comment asserting a trigger the config lacks" % key)
    # An advertised-glob debt entry whose workflow no longer produces it must be deleted.
    live_a = {(os.path.basename(w), g)
              for w in files if w.startswith(".github/workflows/")
              for g in class_a(read_src(w))}
    for key in CLASS_A_DEBT:
        if ".github/workflows/%s" % key[0] in files and key not in live_a:
            viol.append("A: debt entry %s no longer reproduces — delete it" % (key,))

    # --- class B
    for path in files:
        if path.startswith(CLASS_B_EXCLUDE_PREFIXES) or path == CLASS_B_SELF:
            continue
        if not (path.endswith((".md", ".txt", ".yml", ".yaml", ".py", ".sh"))
                or os.path.basename(path) in CLASS_B_EXTRA_NAMES):
            continue
        if not os.path.exists(os.path.join(REPO, path)):
            continue
        lines = class_b(read_src(path))
        allowed = CLASS_B_DEBT.get(path, 0)
        if len(lines) > allowed:
            viol.append("B: %s asserts %d permanence claim(s) (line(s) %s), debt allows "
                        "%d — a mutable state stated as permanent rather than quoted for "
                        "retraction"
                        % (path, len(lines), ",".join(map(str, lines)), allowed))
        elif lines:
            notes.append("B debt %s: %d asserted permanence claim(s) at line(s) %s"
                         % (path, len(lines), ",".join(map(str, lines))))
    # Debt entries that no longer match anything must be deleted: shrink-only.
    # A path that is ABSENT is skipped, not counted as zero: an unmeasurable file is
    # not evidence that the debt was cleared (the same distinction the custody gate had
    # to learn — "UNVERIFIED", never "absent"). This also lets the checker run inside a
    # hermetic fixture repo that contains none of the baselined paths.
    for path, allowed in CLASS_B_DEBT.items():
        if not os.path.exists(os.path.join(REPO, path)):
            continue
        found = len(class_b(read_src(path)))
        if found < allowed:
            viol.append("B: %s debt entry allows %d asserted claim(s) but only %d remain — "
                        "delete or lower the baseline entry; debt may only shrink"
                        % (path, allowed, found))

    # --- class C
    cfg = ".pre-commit-config.yaml"
    c_hits = class_c(read_src(cfg), files, read_src) if os.path.exists(
        os.path.join(REPO, cfg)) else []
    for hit in c_hits:
        hook, count = hit.split(":")
        if hook in CLASS_C_DEBT:
            notes.append("C debt %s: %s file(s) matched by the trigger, outside the corpus "
                         "(count is informational; the gate keys on the hook name)" % (hook, count))
        else:
            viol.append("C: hook %s has pass_filenames:false and fires on %s tracked file(s) "
                        "its checker corpus omits — it reports PASS about files it never "
                        "opened" % (hook, count))
    for hook, allowed in CLASS_C_DEBT.items():
        if not os.path.exists(os.path.join(REPO, cfg)):
            continue  # no config in this tree: nothing was measured, so nothing is stale
        live = [h for h in c_hits if h.startswith(hook + ":")]
        if not live and allowed:
            viol.append("C: %s debt entry is stale (no live violation) — delete it" % hook)

    # --- class D
    if "AGENTS.md" in files:
        d_hits = class_d(read_src("AGENTS.md"))
        for hit in d_hits:
            if CLASS_D_DEBT.get(hit, 0) >= 1:
                notes.append("D debt %s" % hit)
            else:
                viol.append("D: AGENTS.md — %s" % hit)
        for key, allowed in CLASS_D_DEBT.items():
            if key not in d_hits and allowed:
                viol.append("D: AGENTS.md debt entry %r no longer reproduces — delete it"
                            % key)
    return viol, notes


# ------------------------------------------------------------ self-test ------
def self_test() -> int:
    """Prove each class can FAIL. A detector never observed to fire is not a control."""
    fails = 0

    def ok(msg: str) -> None:
        print("  ok   %s" % msg)

    def bad(msg: str) -> None:
        nonlocal fails
        fails += 1
        print("  FAIL %s" % msg)

    def expect(cond: bool, msg: str) -> None:
        ok(msg) if cond else bad(msg)

    # --- A
    dirty = ('# Trigger: push/PR to main, develop, feature/*\n'
             'name: X\non:\n  push:\n    branches:\n      - main\n      - develop\n'
             '  pull_request:\n    branches:\n      - main\npermissions:\n  contents: read\n')
    expect(class_a(dirty) == ["feature/*"],
           "A: an advertised branch glob absent from on: is detected (F-45 reproduced)")
    clean = dirty.replace("# Trigger: push/PR to main, develop, feature/*",
                          "# Trigger: push/PR to main, develop")
    expect(class_a(clean) == [], "A: a comment that matches its config is clean")
    widened = dirty.replace("      - develop\n  pull_request:",
                            "      - develop\n      - feature/*\n  pull_request:")
    expect(class_a(widened) == [], "A: adding the glob to on: clears the finding")
    expect(class_a("# no globs here\non:\n  push:\n    branches:\n      - main\n") == [],
           "A: a workflow with no advertised glob is not flagged")

    # --- B
    undated = "the hook has never been installed on this working copy, so nothing ran.\n"
    expect(class_b(undated) == [1], "B: an asserted permanence claim is detected (F-42)")
    quoted = ('F-42 records the places that inherited "has never been installed" as a '
              "timeless property.\n")
    expect(class_b(quoted) == [],
           "B: the same phrase QUOTED in order to retract it is exempt")
    expect(class_b("nothing to see here\n") == [], "B: ordinary prose is not flagged")
    dated_but_asserted = ("measured 2026-11-01T16:31Z: no CI job invoked it, and the hook "
                          "has never been installed on this working copy.\n")
    expect(class_b(dated_but_asserted) == [1],
           "B: a nearby instant dating a DIFFERENT measurement does NOT exempt the claim "
           "(the weakness the first draft had, which exempted all four real F-42 files)")
    code_span = ("`.git/hooks/pre-commit` has never existed on this working copy, so a bad "
                 "stamp went unseen.\n")
    expect(class_b(code_span) == [1],
           "B: a backtick code span is not a quotation, so the Makefile instance is caught")
    wrapped = ("# Wired here because `.git/hooks/pre-commit` has never\n"
               "# existed on this working copy, so a bad stamp went unseen.\n")
    expect(class_b(wrapped) == [1],
           "B: a claim WRAPPED across two comment lines is still detected (the probe defect "
           "that hid the Makefile occurrence)")

    # --- C
    def fake_src(rel: str) -> str:
        return 'DEFAULT_FILES = [\n    "CHANGELOG.md",\n    "AGENTS.md",\n]\n'

    cfg = ("repos:\n  - repo: local\n    hooks:\n"
           "      - id: record-stamps\n"
           "        entry: python3 scripts/maintenance/check-record-stamps.py --self-test\n"
           "        files: ^(CHANGELOG\\.md|AGENTS\\.md|docs/.*\\.md)$\n"
           "        pass_filenames: false\n")
    tracked = ["CHANGELOG.md", "AGENTS.md", "docs/runbooks/new-runbook.md"]
    hits = class_c(cfg, tracked, fake_src)
    expect(hits == ["record-stamps:1"],
           "C: a trigger broader than its checker corpus is detected (F-44 reproduced)")
    expect(class_c(cfg, ["CHANGELOG.md", "AGENTS.md"], fake_src) == [],
           "C: a trigger whose matches are all in the corpus is clean")
    expect(class_c(cfg.replace("pass_filenames: false", "pass_filenames: true"),
                   tracked, fake_src) == [],
           "C: pass_filenames:true is the fix, and clears the finding")

    # --- D
    agents = ("### 2.1 x\n\n"
              "□ VM backup:  **PASSES 2026-10-22 — off-host backups of VMID 100 exist.**\n"
              "**Updated 2026-10-31: the gate is MET — 9 consecutive scheduled OK runs.**\n\n"
              "#### Tracked open items\n"
              "**no off-host VM backup of VMID 100 (RPO/RTO not met)**.\n\n"
              "### 2.2 y\n")
    expect(class_d(agents) == ["VMID 100 asserted MET while listed open"],
           "D: a gate asserted MET and listed open in the same section is detected (F-46)")
    expect(class_d(agents.replace("#### Tracked open items\n**no off-host VM backup of "
                                  "VMID 100 (RPO/RTO not met)**.\n", "")) == [],
           "D: removing the stale open item clears the finding")
    expect(class_d("### 2.1 x\n□ VM backup: PASSES for VMID 100.\n### 2.2 y\n") == [],
           "D: an open-items-free section is not flagged")

    print("  self-test %s (all four classes observed to fail on synthetic defects)"
          % ("passed" if fails == 0 else "FAILED: %d fixture(s) red" % fails))
    return 1 if fails else 0


def main() -> int:
    do_self = "--self-test" in sys.argv[1:]
    if do_self:
        if self_test():
            return 1
    viol, notes = scan()
    for n in notes:
        print("  %s" % n)
    if viol:
        print("")
        for v in viol:
            print("  VIOLATION %s" % v)
        print("DOC-CLAIM CHECK FAIL (%d new violation(s)); debt entries: A=%d B=%d C=%d D=%d"
              % (len(viol), len(CLASS_A_DEBT), len(CLASS_B_DEBT),
                 len(CLASS_C_DEBT), len(CLASS_D_DEBT)))
        print("  each debt entry names a finding in "
              "docs/audit/self-audit-control-effectiveness-20261105.md and may only shrink")
        return 1
    print("DOC-CLAIM CHECK PASS (no NEW prose claim contradicts its own config; "
          "debt entries A=%d B=%d C=%d D=%d are baselined and shrink-only)"
          % (len(CLASS_A_DEBT), len(CLASS_B_DEBT), len(CLASS_C_DEBT), len(CLASS_D_DEBT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
