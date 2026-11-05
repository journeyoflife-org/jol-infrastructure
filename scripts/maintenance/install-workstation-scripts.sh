#!/usr/bin/env bash
# =============================================================================
# install-workstation-scripts.sh — put the workstation's root-run scripts on PATH
#
# WHY. On 2026-11-05 the operator ran:
#     sudo DRY_RUN=0 scripts/maintenance/backup-workstation-home.sh
# from ~ and got "command not found" — the path is relative to the repo, and sudo
# does not change that. The deeper cause is that three root-run scripts were
# authored with no install target, unlike every other maintenance script in this
# directory: the fleet convention (see hv01-config-backup.sh, hv01-health-check.sh,
# hv01-offline-fsck-drill.sh) is a version-controlled repo copy installed to
# /usr/local/bin with matching sha256 and mode 750 root:root. The workstation
# watchdog already follows that pattern via install-workstation-capacity-timer.sh;
# these three did not. This closes that, so a script is invoked by a stable name
# from any working directory instead of by a path someone has to remember.
#
# Idempotent, DRY_RUN by default, non-destructive (install only overwrites the
# same-managed target; it removes nothing).
#
# Usage:  sudo DRY_RUN=0 ./install-workstation-scripts.sh
#         ./install-workstation-scripts.sh            # plan, no root needed
# Rollback:
#         sudo rm /usr/local/bin/jol-{backup-home,fix-backup-mount,provision-home-disk}.sh
# =============================================================================
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

REPO_DIR="$(dirname "$(readlink -f "$0")")"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
DRY_RUN="${DRY_RUN:-1}"

# repo filename            -> installed name                    -> mode
# The mode is per-target, and the split is not cosmetic. Three of these scripts
# have a documented READ-ONLY invocation (--report, --verify-only, --preflight)
# that is meant to be runnable without root; at 750 root:root the operator cannot
# execute them at all, so the help text this installer prints advertised an
# invocation that its own permissions forbade. Scripts whose every path mutates
# stay 750. The read-only-capable ones are 755 root:root, which is safe because
# each one enforces `id -u == 0` on its mutating path in code and dies otherwise.
TARGETS=(
    "fix-jol-backup-mount.sh|jol-fix-backup-mount.sh|750"
    "backup-workstation-home.sh|jol-backup-home.sh|755"
    "provision-jolhome-disk.sh|jol-provision-home-disk.sh|755"
    "migrate-home-to-jolhome.sh|jol-migrate-home.sh|755"
    # 755 like the other read-only-capable tools: DRY_RUN=1 is reachable without
    # root and only plans. Its mutating paths and the 600 artifact write enforce
    # uid 0 in code, so the world-readable mode exposes no writable path.
    "record-jolhome-custody.sh|jol-record-custody.sh|755"
)

say() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
run() {
    if [[ "$DRY_RUN" == "1" ]]; then printf 'DRY  : %s\n' "$*"; return 0
    fi
    printf 'APPLY: %s\n' "$*"; "$@"
}

# --- guards ------------------------------------------------------------------
HOST_ID="$(hostname -s 2>/dev/null || echo unknown)"
for h in pve-prod-hv01 pbs01 llm-prod-lt01 rag-prod-lt01 mcp-prod-lt01 her-prod-lt01; do
    [[ "$HOST_ID" == "$h" ]] && { say "ABORT: $h is a fleet host; these are the custodian workstation's scripts"; exit 2; }
done
if [[ "$DRY_RUN" != "1" && "$(id -u)" -ne 0 ]]; then
    say "ABORT: writing to $BIN_DIR needs root. Run without sudo to see the plan."
    exit 2
fi

say "=== install-workstation-scripts.sh (DRY_RUN=$DRY_RUN, host=$HOST_ID, target=$BIN_DIR) ==="

FAILED=0
for pair in "${TARGETS[@]}"; do
    src="$REPO_DIR/${pair%%|*}"
    rest="${pair#*|}"
    dst_name="${rest%%|*}"
    mode="${rest##*|}"
    dst="$BIN_DIR/$dst_name"

    if [[ ! -f "$src" ]]; then
        say "FAIL: source missing: $src"
        FAILED=1
        continue
    fi

    # A script that cannot parse must never reach a scheduler or a sudo invocation.
    # This is the check that matters here because these scripts are run by a human
    # under sudo at a terminal, where a syntax error arrives as a wall of text and
    # is easy to misread as a data problem.
    if ! bash -n "$src" 2>/dev/null; then
        say "FAIL: syntax error in $src — refusing to install"
        FAILED=1
        continue
    fi
    if command -v shellcheck >/dev/null 2>&1; then
        if ! shellcheck -x -S warning "$src" >/dev/null 2>&1; then
            say "FAIL: shellcheck reported problems in $src — refusing to install"
            FAILED=1
            continue
        fi
    fi

    run install -m "$mode" -o root -g root "$src" "$dst" || { FAILED=1; continue; }
done

echo
say "=== verify ==="
if [[ "$DRY_RUN" == "1" ]]; then
    say "DRY  : would check sha256 parity repo vs installed for each target"
    say "DRY  : then run: sudo DRY_RUN=0 $0"
else
    for pair in "${TARGETS[@]}"; do
        src="$REPO_DIR/${pair%%|*}"
        rest="${pair#*|}"
        dst="$BIN_DIR/${rest%%|*}"
        want_mode="${rest##*|}"
        [[ -f "$dst" ]] || { say "FAIL: $dst absent"; FAILED=1; continue; }
        a="$(sha256sum "$src" | cut -d' ' -f1)"
        b="$(sha256sum "$dst" | cut -d' ' -f1)"
        if [[ "$a" == "$b" ]]; then
            got_mode="$(stat -c '%a' "$dst")"
            if [[ "$got_mode" != "$want_mode" ]]; then
                say "FAIL : $(basename "$dst") is mode $got_mode, expected $want_mode — a read-only invocation may be unreachable"
                FAILED=1
            else
                say "OK   : $(basename "$dst") sha256 ${a:0:16}… identical to repo copy, mode $(stat -c '%a %U:%G' "$dst")"
            fi
        else
            say "FAIL : $(basename "$dst") differs from the repo copy — host/repo drift (the F-4 class)"
            FAILED=1
        fi
    done
fi

echo
if (( FAILED )); then
    say "=== NOT INSTALLED — see the FAIL lines above ==="
    exit 1
fi
say "=== done ==="
say "Invoke from anywhere, e.g.:"
say "  sudo DRY_RUN=0   $BIN_DIR/jol-backup-home.sh"
say "  sudo DRY_RUN=1   $BIN_DIR/jol-provision-home-disk.sh"
say "  $BIN_DIR/jol-backup-home.sh --report        # read-only, no root"
say "  $BIN_DIR/jol-migrate-home.sh --preflight    # read-only, no root"
say ""
say "Phase 2 (the /home cutover) must NOT be run from a desktop session:"
say "  sudo systemctl isolate rescue.target"
say "  sudo DRY_RUN=1 $BIN_DIR/jol-migrate-home.sh    # plan"
say "  sudo DRY_RUN=0 $BIN_DIR/jol-migrate-home.sh    # copy + verify + fstab swap"
say "  sudo reboot                                    # the passphrase prompt appears here"
exit 0
