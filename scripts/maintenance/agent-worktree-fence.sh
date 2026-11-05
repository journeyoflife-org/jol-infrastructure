#!/usr/bin/env bash
# =============================================================================
# agent-worktree-fence.sh — make concurrent-session contamination VISIBLE.
#
# WHY (issue #142, finding F-25)
# "Two agent sessions wrote the same working tree concurrently — nothing in the
# repo could see it." That is not a story about intent, it is a story about
# observability. On 2026-11-05 one session's staged CHANGELOG.md blob turned out
# to DELETE two CC8.1 records the other session had already committed, and the
# only reason anyone found out is that a scoped-commit gate happened to diff in
# both directions. Nothing in the repo would have told either session.
#
# WHAT THIS MEASURES, AND WHY IT NEEDS NO COOPERATION
# One repository can have several worktrees. A path that is UNCOMMITTED in more
# than one of them is a collision by construction: two lines of work intend
# different things for one file, and whichever commits second silently wins or
# destroys the other. That signal needs no lock file, no session identity and no
# agreement — it reads straight off git. Measured live on this host: 7 paths
# collided, including CHANGELOG.md, Makefile and infra-validate.yml.
#
# There is deliberately no claim/lock ledger. I grepped this repo for an existing
# convention first (`flock`, `.lock`, `LOCK`) and found NONE — every apparent hit
# was the substring "LOCK" inside the word "BLOCKED". Inventing cooperative
# locking the repo has no precedent for would add machinery that only deters the
# polite, while the objective signal was available for free.
#
# Subcommands
#   status            census + collision set. Exit 1 if any path collides.
#   check <path>...   exit 2 if a named path collides — usable before a commit.
#   new <branch> [base]  create an ISOLATED sibling worktree so the next session
#                     gets its OWN index. This is the structural fix.
#   prune-stale       drop registrations whose directory is gone, but only after
#                     proving every affected branch still exists.
#
# Read-only by default. `new` and `prune-stale` honour DRY_RUN=1 and print the
# command they would run. Nothing here ever mutates the working tree.
# Exit: 0 clear, 1 collisions found, 2 guard or measurement failure — 2 is
# distinct because "could not measure" must never be reported as "clean".
# =============================================================================
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

DRY_RUN="${DRY_RUN:-1}"
MODE="${1:-status}"
# Explicit if, not `[[ ... ]] && shift || true`: the A && B || C form is not
# if-then-else (C also runs when A is true and B fails), which is exactly the
# kind of "it looked like a guard" construction this tool exists to remove.
if [[ $# -gt 0 ]]; then shift; fi

say() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf '[%s] ABORT: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 2; }

# -----------------------------------------------------------------------------
# collide — the entire decision, as a PURE FUNCTION so it can be fixture-tested
# without a second worktree existing anywhere.
#
#   stdin : lines of "<worktree-id>\t<path>"
#   stdout: "<distinct-worktree-count>\t<path>" for count >= 2, sorted by path
#
# A path listed twice within ONE worktree is not a collision, which is why the
# distinct ids are counted rather than the lines.
# -----------------------------------------------------------------------------
collide() {
    awk -F'\t' '
        NF >= 2 && $1 != "" && $2 != "" {
            key = $2 SUBSEP $1
            if (!(key in seen)) { seen[key] = 1; cnt[$2]++ }
        }
        END { for (p in cnt) if (cnt[p] > 1) printf "%s\t%s\n", cnt[p], p }
    ' | sort -k2
}

# Uncommitted paths of one worktree, as clean paths. Assembled from three
# plumbing queries instead of parsing `git status` columns, because porcelain
# renders a rename as "R  old -> new" and field 2 is then an arrow fragment — a
# path list built that way silently drops every staged rename.
wt_paths() { # wt_paths <worktree-path>
    {
        git -C "$1" diff --name-only 2>/dev/null
        git -C "$1" diff --cached --name-only 2>/dev/null
        git -C "$1" ls-files --others --exclude-standard 2>/dev/null
    } | grep -v '^[[:space:]]*$' | sort -u
}

# Live worktrees as "<id>\tstate\tbranch\t<path>". The id is the path with / and
# . flattened, purely so it survives a tab-separated stream; the real path is
# carried in field 4.
enumerate_worktrees() {
    git worktree list --porcelain 2>/dev/null | awk '
        function emit() {
            if (wt == "") return
            id = wt; gsub(/[\/.]/, "_", id)
            printf "%s\t%s\t%s\t%s\n", id, (p ? "prunable" : "live"), (br ? br : "detached"), wt
            wt = ""; br = ""; p = 0
        }
        /^worktree / { wt = substr($0, 10) }
        /^branch /   { br = substr($0, 8); sub("refs\/heads\/", "", br) }
        /^prunable/  { p = 1 }
        /^$/         { emit() }
        END          { emit() }
    '
}

# The "<id>\t<path>" stream for live worktrees only. A prunable registration has
# no directory and therefore no dirty set; feeding one into the collision test
# would be measuring a ghost. Printed directly rather than accumulated so a very
# dirty worktree cannot blow up a shell variable.
build_stream() {
    local table="$1" id state br path p
    while IFS=$'\t' read -r id state br path; do
        [[ "$state" == "live" && -n "$path" ]] || continue
        while read -r p; do
            [[ -n "$p" ]] && printf '%s\t%s\n' "$id" "$p"
        done < <(wt_paths "$path")
    done <<< "$table"
}

census() { # census <table> <stream>
    # Counts DISTINCT paths per worktree by de-duplicating here rather than trusting
    # wt_paths' `sort -u` upstream. Relying on the producer's hygiene would make the
    # printed number correct only by coincidence, and this is the same assumption
    # this whole thread has been removing from its gates.
    printf '%s\n' "$1" | awk -F'\t' -v S="$2" '
        BEGIN {
            n = split(S, lines, "\n")
            for (i = 1; i <= n; i++) {
                if (lines[i] == "") continue
                split(lines[i], f, "\t")
                if (f[1] == "" || f[2] == "") continue
                k = f[1] SUBSEP f[2]
                if (!(k in seen)) { seen[k] = 1; c[f[1]]++ }
            }
        }
        { printf "  %-46s %-9s %-34s %s\n", $4, $2, $3, (c[$1] ? c[$1] : 0) " path(s)" }
    '
}

case "$MODE" in
  status)
    say "=== agent-worktree-fence status (read-only) ==="
    TABLE="$(enumerate_worktrees)"
    [[ -n "$TABLE" ]] || die "git worktree list produced nothing — refusing to report 'no collision' from an empty census"
    echo "  worktree                                       state       branch                             uncommitted"
    STREAM="$(build_stream "$TABLE")"
    census "$TABLE" "$STREAM"

    COL="$(printf '%s\n' "$STREAM" | collide)"
    NCOL="$(printf '%s\n' "$COL" | grep -c . || true)"
    echo ""
    if (( NCOL == 0 )); then
        say "RESULT: clear — no path is uncommitted in more than one worktree"
        exit 0
    fi
    say "COLLISION: $NCOL path(s) uncommitted in MORE THAN ONE worktree."
    printf '%s\n' "$COL" | awk -F'\t' '{printf "  %s  (in %s worktrees)\n", $2, $1}'
    say "Consequence: whichever session commits second wins, or deletes the other's"
    say "work. Scope commits by pathspec, derive any shared-file blob from HEAD plus"
    say "your own lines only, or isolate: DRY_RUN=0 $0 new <branch>"
    exit 1
    ;;

  check)
    [[ $# -gt 0 ]] || die "check needs at least one path"
    TABLE="$(enumerate_worktrees)"
    [[ -n "$TABLE" ]] || die "cannot enumerate worktrees — reporting 'clear' would be unfounded"
    STREAM="$(build_stream "$TABLE")"
    COL="$(printf '%s\n' "$STREAM" | collide | cut -f2)"
    HIT=0
    for want in "$@"; do
        if printf '%s\n' "$COL" | grep -qxF -- "$want"; then
            printf 'COLLIDES: %s\n' "$want" >&2
            HIT=$((HIT + 1))
        fi
    done
    if (( HIT > 0 )); then
        printf '%s of %d named path(s) collide across worktrees — scope or isolate first\n' "$HIT" "$#" >&2
        exit 2
    fi
    printf 'clear: none of the %d named path(s) is uncommitted in another worktree\n' "$#"
    ;;

  new)
    br="${1:-}"; base="${2:-HEAD}"
    [[ -n "$br" ]] || die "new needs a branch name"
    case "$br" in
        *[!A-Za-z0-9._/-]*|'') die "branch name '$br' contains unsupported characters" ;;
    esac
    [[ "$base" != "$br" ]] || die "base and new branch are both '$br'"
    root="$(git rev-parse --show-toplevel)" || die "not inside a git worktree"
    slug="${br##*/}"; slug="${slug//[^A-Za-z0-9_-]/-}"
    dest="$(dirname "$root")/$(basename "$root")--$slug"
    if [[ -e "$dest" ]]; then die "$dest already exists — refusing to overwrite"; fi
    if git show-ref --verify --quiet "refs/heads/$br"; then
        die "branch $br already exists locally; pick a new name, or use 'git worktree add $dest $br' deliberately"
    fi
    say "purpose: a separate worktree carries its OWN index, so two sessions cannot"
    say "         stage over one another. Sharing a worktree is what produced #142."
    say "target : $dest"
    say "branch : $br  (new, from $base)"
    if [[ "$DRY_RUN" == "1" ]]; then
        printf 'DRY  : git worktree add -b %s %s %s\n' "$br" "$dest" "$base"
        say "Nothing created. Re-run with DRY_RUN=0."
        exit 0
    fi
    git worktree add -b "$br" "$dest" "$base" || die "git worktree add failed"
    say "created $dest — run the next session there and it gets its own index"
    say "verify : $0 status"
    ;;

  prune-stale)
    TABLE="$(enumerate_worktrees)"
    [[ -n "$TABLE" ]] || die "cannot enumerate worktrees"
    BRANCHES="$(printf '%s\n' "$TABLE" | awk -F'\t' '$2=="prunable" && $3!="detached"{print $3}')"
    if [[ -z "$(printf '%s' "$TABLE" | grep prunable || true)" ]]; then
        say "no prunable registrations — nothing to do"
        exit 0
    fi
    echo "  prunable worktree registrations:"
    printf '%s\n' "$TABLE" | awk -F'\t' '$2=="prunable"{printf "    %s [%s]\n", $4, $3}'
    # Guard before action. Pruning removes the .git/worktrees admin dir only, so
    # the branch must survive — assert it exists first, and again after. A branch
    # that only ever existed in the vanished working copy is a different problem
    # and must stop this, not be pruned away with it.
    for b in $BRANCHES; do
        git show-ref --verify --quiet "refs/heads/$b" \
            || die "branch $b has no local ref — its work is not safely held; investigate before pruning"
    done
    say "all ${BRANCHES//$/ } affected branch(es) verified as present local refs"
    if [[ "$DRY_RUN" == "1" ]]; then
        printf 'DRY  : git worktree prune -v\n'
        say "Nothing pruned. Re-run with DRY_RUN=0."
        exit 0
    fi
    git worktree prune -v || die "git worktree prune failed"
    for b in $BRANCHES; do
        git show-ref --verify --quiet "refs/heads/$b" \
            || die "POST-CHECK FAILED: branch $b vanished during prune — investigate immediately"
    done
    say "pruned; every affected branch still resolves"
    ;;

  *)
    die "unknown subcommand '$MODE'. Use: status | check <path>... | new <branch> [base] | prune-stale"
    ;;
esac
