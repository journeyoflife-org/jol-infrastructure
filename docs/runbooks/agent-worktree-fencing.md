# Agent Worktree Fencing

**Purpose:** stop two agent sessions from silently overwriting each other's work in
one repository. Closes the observability half of **F-25 (issue #142)**.
**Scope:** development workflow on the custodian workstation. No fleet host, no
runtime service, no secret material.

## 1. The incident this exists for

On 2026-11-05 two agent sessions operated on `jol-infrastructure` at once. One had
staged a `CHANGELOG.md` blob that, measured against `HEAD` in both directions,
**deleted two CC8.1 change records the other session had already committed**
(`2026-10-31T22:41:37Z` vm/101 restore drill, `2026-11-01 16:17Z` issue #137
finding F-12) and additionally failed `check-changelog-table.py` on three rows with
unescaped pipes. Had that blob been committed, two compliance records would have
disappeared with no error raised.

Nobody detected that. A scoped-commit gate diffed in both directions by accident and
found it. F-25's wording is exact: *nothing in the repo could see it.*

## 2. The signal that needs no cooperation

One repository may have several **worktrees**. A path that is uncommitted in more
than one of them is a collision **by construction**: two lines of work intend
different things for one file, and whichever session commits second wins, or
destroys the other's.

This is measurable straight from git. No lock file, no session identity, no
agreement required. Measured live on this host:

```
/opt/jol/repos/jol-infrastructure         live  docs/cc81-offline-fsck-all-three-vmids   26 path(s)
/opt/jol/repos/jol-infrastructure-f14f21  live  fix/cc81-f14-f21-closeout                11 path(s)

COLLISION: 7 path(s) uncommitted in MORE THAN ONE worktree.
  CHANGELOG.md                                    (in 2 worktrees)
  .github/workflows/infra-validate.yml            (in 2 worktrees)
  Makefile                                        (in 2 worktrees)
  scripts/maintenance/pve-rotate-cipassword.sh    (in 2 worktrees)
  scripts/maintenance/tests/test-hv01-config-backup-f3.sh
  scripts/maintenance/tests/test-hv01-gate11.sh
  scripts/maintenance/tests/test-pve-rotate-verify.sh
```

`CHANGELOG.md` is the structural problem: **every** session that performs a
production change must append to it, so it collides by design under §0.3. Treat it
as a shared write surface and handle it accordingly (§5).

## 3. Tooling

`scripts/maintenance/agent-worktree-fence.sh`

| Command | Meaning | Exit |
|---|---|---|
| `status` | worktree census plus the collision set | 0 clear, 1 collisions, 2 could not measure |
| `check <path>...` | fail if any named path collides — run before a commit | 0 clear, 2 collision or guard |
| `new <branch> [base]` | create an isolated sibling worktree with its **own index** | 0, or 2 guard |
| `prune-stale` | drop registrations whose directory is gone, only after proving every affected branch still resolves | 0, or 2 guard |

`DRY_RUN=1` is the default for `new` and `prune-stale`. **`rc=2` is deliberately
distinct from `rc=0`**: "could not measure" is never reported as "clear", which is
the failure class this repo keeps rediscovering.

## 4. The convention

**One agent session, one worktree, one branch.** Before starting a second session on
the same repository:

```
scripts/maintenance/agent-worktree-fence.sh new <branch>              # DRY_RUN=1 default:
                                                                       #   prints the plan
DRY_RUN=0 scripts/maintenance/agent-worktree-fence.sh new <branch>    # creates it
```

The first line is read-only by default and shows the exact `git worktree add` it
would run. Two identical `DRY_RUN=0` lines here originally made the plan step look
like it also created the worktree, which is the kind of instruction that gets run
twice.

The sibling lands at `../<repo>--<branch-slug>` and carries its own index, so
staging in one session cannot alter the other's.

## 5. When a worktree must be shared anyway

Do not "fix" it by committing the whole index — that sweeps the other session's
staged entries into your commit.

1. Run `agent-worktree-fence.sh check <your paths>` first.
2. Commit new files with a pathspec-scoped commit (`git commit --only -- <paths>`),
   which disregards content staged for other paths.
3. For a file carrying both authors, build the blob from **`HEAD` plus your own
   lines only**, never from the working tree, and verify the diff against `HEAD`
   is exactly your insertion count with **zero deletions**. Land it through a
   temporary index so the shared index blob hash never changes.
4. Re-check afterwards that the other session's staged paths, unstaged count and
   untracked files are unchanged.

Step 3 is what caught the deleted-records hazard in §1. The candidate blob measured
**16 insertions / 2 deletions** against `HEAD` where **14 / 0** was required, and the
two extra insertions plus two deletions turned out to be the other session's
*rewritten* rows being carried along. Had the check asserted only an insertion count,
or only looked at additions the way the first analysis did, that would have shipped.

## 6. Limits, stated plainly

- The fence **detects, it does not prevent**. Nothing stops a session that never
  runs it. The only real prevention is separate worktrees (§4).
- No claim/lock ledger exists in this repo and none was added. Grepped for a
  convention first (`flock`, `.lock`, `LOCK`) and found none — every apparent hit
  was the substring `LOCK` inside the word `BLOCKED`. A cooperative lock would have
  deterred only the polite while the objective signal was free.
- Two worktrees on the same branch cannot be distinguished by this method, because
  git forbids that checkout anyway.
- The collision set covers uncommitted state. Two sessions editing the same file and
  committing in sequence is invisible here; review and rebase remain the control.
- CI cannot enforce any of this: `infra-validate.yml` triggers push only on `main`
  and `develop`, so a feature branch without a pull request runs no job at all.

## 7. Verification

`scripts/maintenance/tests/test-worktree-fence.sh` — **30 fixtures**, auto-discovered
by `make test-gates`. The pure `collide()` function is extracted from the script
under test, never copied, and extraction failure aborts with `rc=2` so an empty
extraction cannot pass as a green run.

Mutant-proven **7 of 7 red, none surviving, no harness errors**: counting lines
instead of distinct worktrees; reporting every path rather than shared ones;
dropping the empty-path and empty-id guards; removing the deduplication key;
dropping the sort; and breaking the census field separator.

Two of those seven **survived the first draft of these fixtures**, which is why the
suite was widened rather than declared adequate: a single empty-path line cannot
detect a missing empty-path guard (it takes two, from different worktrees), and
nothing at all asserted the census counts. The census was then fixed to de-duplicate
itself instead of relying on its producer's hygiene.

Live coverage asserts the tool reports `CHANGELOG.md` as a genuine collision on this
host, that `check` blocks on it (`rc=2`) and passes an unrelated path (`rc=0`), that
an unknown subcommand exits 2 rather than 0, and that `DRY_RUN` creates nothing.
