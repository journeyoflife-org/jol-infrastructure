#!/usr/bin/env python3
"""check-record-stamps.py — every timestamp a compliance record labels `Z` must be a real UTC
instant that had already happened when the record was written.

WHY THIS EXISTS (found while verifying issue #137 on 2026-11-01). `CHANGELOG.md` and the
host/runbook Change-History tables are the SOC 2 CC8.1 evidence artifact, so their stamps are
load-bearing: an auditor reconstructs the ORDER of production changes from them. Measured against
artifacts, several stamps in this repo are not real UTC instants. Two failure modes, one root
cause — a stamp was typed from the wall clock the author was looking at instead of one `date -u`
reading taken at the event:

  class A — local DATE + UTC CLOCK, off by one day. The vm/101 drill is recorded as
            `2026-11-01T22:41:37Z`, but the drill script's own mtime is `2026-10-31T22:42:27Z`,
            issue #135 was CLOSED at `2026-10-31T22:56:04Z`, and the PR carrying the record was
            committed `2026-10-31T22:55:37Z`. A record cannot postdate its own commit by 23 h.
            The run crossed local midnight (Europe/Vilnius = UTC+2 in November), so the date rolled
            forward while the clock value stayed right.  -> true instant 2026-10-31T22:41:37Z.

  class B — local CLOCK relabelled `Z`, off by two hours. The F-2 row is stamped
            `2026-10-31T23:05:00Z` while its own prechange directory is
            `/root/prechange-20261031-230501` with mtime `2026-10-31T21:05:01Z`: the name was built
            with `$(date +%H%M%S)` (local) and the record then called that value UTC.
            -> true instant 2026-10-31T21:05:00Z.

Neither class is visible to `make lint-changelog` (it counts table columns, not clock values), and
CI never ran a stamp check at all — which is how both reached `main`.

RULES
  rule 1  no `...Z` stamp may be later than NOW                        (write-time guard)
  rule 2  no `...Z` stamp may be later than the commit that introduced its line (retro audit;
          this is the only rule that catches class B, which is in the past but ahead of itself)

EXEMPTIONS — deliberately not findings
  * a stamp on a line that also carries a forward-looking marker (NEXT_RUN/`scheduled`/`owed`/
    `window`/`until`/`first run`/`verify`/`before`/`fires`/`due`/`plan`): those are real future
    instants, e.g. the PBS GC `next-run: 1794018600` = `2026-11-07T02:30Z`.
  * a time WITHOUT a trailing `Z` is not scanned at all. The fleet writes node-local clock
    references (the `02:00` nightly, the `04:00` monthly verify) and those are legitimately ahead.

RATCHET — pre-existing debt is listed in STAMP_DEBT_BASELINE and reported as grandfathered, never
as a new violation. The list may only shrink. Closing a row means deleting its entry.

Usage:
    check-record-stamps.py [--git] FILE [FILE ...]   # default ledger files
    check-record-stamps.py --self-test               # prove the checker can FAIL first
    check-record-stamps.py --git CHANGELOG.md        # add rule 2 (blame each line to its commit)

Exit: 0 clean, 1 new findings, 2 usage/IO error.
"""

import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

STAMP = re.compile(r"(?P<dt>\d{4}-\d{2}-\d{2})[T ](?P<tm>\d{2}:\d{2}(?::\d{2})?)Z")
# A stamp that sits in a scheduler sentence is a real FUTURE instant (a read-back `next-run`, a
# cron entry), not a claim about when something happened. Matched on an 80-char window around the
# stamp, never the whole row — these rows are megametres long and would otherwise exempt anything
# (the #135 row legitimately mentions an owed November proof in passing).
CONTEXT = 80
# Deliberately NARROW: only scheduler fields count as a genuine future instant. A prose word like
# "scheduled"/"owed" must not exempt a bad stamp — an earlier draft matched "schedule" and thereby
# hid the F-3 row's `2026-11-01T00:03:15Z`, which is exactly the defect being hunted.
FORWARD_MARKER = re.compile(
    r"next-run|next run|gc-schedule|schedule (?:sat|sun|mon|tue|wed|thu|fri)|\*-\*-|"
    r"keep-daily|keep-weekly|keep-monthly|prune-backups", re.I)
SLACK = timedelta(minutes=5)          # seconds old is fine; hours ahead is not
UNCOMMITTED = "0000000000000000000000000000000000000000"

DEFAULT_FILES = [
    "CHANGELOG.md",
    "AGENTS.md",
    "docs/runbooks/hv01-storage-backup-reconfiguration.md",
    "docs/servers/pve-prod-hv01.md",
    "docs/servers/mcp-prod-lt01.md",
    "docs/servers/rag-prod-lt01.md",
    "docs/servers/her-prod-lt01.md",
    "docs/compliance/evidence/hv01-backup-baseline-20261031.txt",
]

# Grandfathered rule-2 debt: rows inherited from back-filled September history whose stamp sits
# ahead of the commit that carries them. Not part of the two classes above and not re-derivable
# from an artifact here, so they are recorded rather than guessed. Key = "<path>:<stamp>"; the list
# may only shrink, exactly like TICKET_DEBT_BASELINE in check-changelog-table.py.
STAMP_DEBT_BASELINE = {
    "CHANGELOG.md:2026-09-19T15:00:00Z",
    "CHANGELOG.md:2026-09-16T18:30:00Z",
}


def parse(match):
    fmt = "%Y-%m-%d %H:%M:%S" if len(match.group("tm")) == 8 else "%Y-%m-%d %H:%M"
    return datetime.strptime(match.group("dt") + " " + match.group("tm"), fmt).replace(
        tzinfo=timezone.utc)


def commit_times(path):
    """line number -> committer datetime of the commit that last touched that line."""
    try:
        out = subprocess.run(["git", "blame", "--line-porcelain", "--", path],
                             capture_output=True, text=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        sys.stderr.write("WARN: git blame failed (%s); rule 2 skipped for %s\n" % (exc, path))
        return {}
    times, sha, cur = {}, None, None
    for line in out.splitlines():
        head = re.match(r"^([0-9a-f]{40}) \d+ (\d+) ", line)
        if head:
            sha, cur = head.group(1), int(head.group(2))
        elif line.startswith("committer-time ") and cur is not None and sha != UNCOMMITTED:
            times[cur] = datetime.fromtimestamp(int(line.split()[1]), timezone.utc)
    return times


def is_exempt(line, match, neighbours=""):
    """Two ways a `...Z` string on a page is NOT a claim that something happened.

    1. scheduler field (`next-run`, `gc-schedule`, `keep-*`, `*-*-01`) — a genuinely future instant.
       Looked for in the line plus its physical neighbours, because evidence files wrap prose across
       lines while a ledger row is one unbroken line. Never applied to a row's LEADING cell.
    2. a SUPERSEDED value shown being corrected: `<old> -> <new>` where the new stamp is earlier.
       Without this rule a correction record fails its own gate — measured: §13 quotes the 37 broken
       stamps precisely so the fix is auditable, and the first draft flagged 10 of its own lines.
       Stated weakening: a row could hide a bad stamp behind such an arrow, which is why the leading
       cell of a ledger row is still always checked.
    """
    if line.startswith("| ") and match.start() < 40:
        return False
    if FORWARD_MARKER.search(neighbours or line):
        return True
    after = line[match.end():]
    if "->" not in after and "→" not in after:
        return False
    arrow = max(after.find("->"), after.find("→"))
    old = parse(match)
    for other in STAMP.finditer(after):
        if other.start() > arrow and parse(other) < old:
            return True
    return False


def scan(path, now, use_git):
    if not os.path.exists(path):
        return [], [], "missing"
    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()
    times = commit_times(path) if use_git and os.path.isdir(".git") else {}
    findings, exempt = [], []
    for no, text in enumerate(lines, 1):
        neighbours = "".join(lines[max(0, no - 2):no + 1])
        for match in STAMP.finditer(text):
            stamp = parse(match)
            if is_exempt(text, match, neighbours):
                exempt.append((no, match.group(0)))
                continue
            if stamp > now + SLACK:
                findings.append((no, match.group(0),
                                 "future of now (%s)" % now.strftime("%Y-%m-%dT%H:%MZ")))
            elif no in times and stamp > times[no] + SLACK:
                key = "%s:%s" % (path, match.group(0))
                if key in STAMP_DEBT_BASELINE:
                    exempt.append((no, match.group(0) + " (grandfathered)"))
                else:
                    findings.append((no, match.group(0),
                                     "future of its own commit (%s)"
                                     % times[no].strftime("%Y-%m-%dT%H:%MZ")))
    return findings, exempt, "ok"


def self_test():
    """A check that has never been observed to fail is not a check."""
    now = datetime(2026, 10, 31, 23, 30, tzinfo=timezone.utc)
    commit = datetime(2026, 10, 31, 21, 0, tzinfo=timezone.utc)
    cases = [
        # (label, line text, expect_rule1_future_of_now, expect_rule2_future_of_commit)
        ("class A: local date + UTC clock (the #135 row)",
         "| 2026-11-01T22:41:37Z | @J | vm/101 drill PASSED | prod | #135 |", True, True),
        ("class B: local clock relabelled Z (the F-2 row) — only rule 2 can see it",
         "| 2026-10-31T23:05:00Z | @J | mirror repaired | prod | #124 |", False, True),
        ("a stamp that is past and inside its commit is fine",
         "| 2026-10-31T20:58:30Z | @J | drill | prod | #131 |", False, False),
        ("a real future schedule read-back is exempt (GC next-run)",
         "garbage-collection status -> next-run: 1794018600 (= 2026-11-07T02:30Z = 04:30 EET)",
         False, False),
        ("a Z-less LOCAL reference is not a UTC claim, so not scanned",
         "the 2026-11-01 02:00 nightly is the next scheduled proof", False, False),
        ("a backup group name (genuine UTC, past) is fine",
         "source pbs01:backup/vm/101/2026-10-31T00:00:10Z", False, False),
        ("seconds-old stamp is inside rule-1 slack (but still ahead of its old commit)",
         "| 2026-10-31T23:29:00Z | just ran |", False, True),
        ("a scheduler word later in the SAME row must not exempt its leading stamp",
         "| 2026-11-01T00:03:15Z | @J | archive sanitised; the job's next-run stays 2026-11-07 "
         "and keep-daily=7 | prod | #128 |", True, True),
        ("a bare scheduler value in prose is a real future instant, exempt",
         "read back: `next-run: 1794018600` (= 2026-11-07T02:30Z = 04:30 EET), upid null",
         False, False),
        ("a SUPERSEDED stamp shown as `old -> new` is quoted history, exempt",
         "| 2026-10-31T20:00:00Z | @J | record said `2026-11-01T22:41:37Z` -> true instant "
         "`2026-10-31T20:41:37Z` | repo | #137 |", False, False),
        ("the same bad stamp WITHOUT an arrow is still a finding",
         "| 2026-10-31T20:00:00Z | @J | drill at `2026-11-01T22:41:37Z` PASSED | repo | #137 |",
         True, True),
        ("an arrow alone is not enough — the stamp after it must be EARLIER, not later",
         "| 2026-10-31T20:00:00Z | @J | fixed 2026-10-31T20:00Z -> 2027-01-01T00:00:00Z next |",
         True, True),
    ]
    failed = 0
    for label, text, want_r1, want_r2 in cases:
        r1 = r2 = False
        for match in STAMP.finditer(text):
            if is_exempt(text, match):
                continue
            stamp = parse(match)
            r1 = r1 or stamp > now + SLACK
            r2 = r2 or stamp > commit + SLACK
        for rule, want, got in (("rule1", want_r1, r1), ("rule2", want_r2, r2)):
            ok = want == got
            print("%-4s %s [%s] (expected finding=%s, got %s)"
                  % ("ok" if ok else "FAIL", label, rule, want, got))
            if not ok:
                failed += 1
    if STAMP.search("2026-11-01 02:00 nightly"):
        print("FAIL sanity: the checker matched a Z-less local reference")
        failed += 1
    return 1 if failed else 0


def main(argv):
    use_git = "--git" in argv
    args = [a for a in argv if not a.startswith("--")]
    if "--self-test" in argv:
        rc = self_test()
        if rc:
            print("self-test FAILED — the checker itself is broken; trusting it would be unsafe")
            return rc
        print("self-test passed (both stamp classes detected; schedules and local refs are not)")
    paths = args or DEFAULT_FILES
    total = exempt_total = 0
    for path in paths:
        findings, exempt, status = scan(path, datetime.now(timezone.utc), use_git)
        if status == "missing":
            print("SKIP (not found): %s" % path)
            continue
        for no, stamp, why in findings:
            print("ERROR %s:%d stamp %s is %s — a stamp labelled Z must be an instant that had "
                  "already happened when the record was written" % (path, no, stamp, why))
        total += len(findings)
        exempt_total += len(exempt)
    if total:
        print("STAMP CHECK FAILED: %d stamp(s) are not verifiable UTC instants (%d exempt as "
              "forward-looking). Fix: take one `date -u` reading at the event, or cite the artifact "
              "whose mtime proves the instant." % (total, exempt_total))
        return 1
    print("STAMP CHECK PASS (%d file(s), every Z-labelled stamp is a real past instant%s; "
          "%d forward-looking stamp(s) exempt)" % (len(paths), " + commit-bound" if use_git else "",
                                                   exempt_total))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
