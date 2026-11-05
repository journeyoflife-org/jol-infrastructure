#!/usr/bin/env bash
# =============================================================================
# install-workstation-backup-timer.sh — make the /home backup a POLICY, not an event
#
# WHY. Phase 0 was run by hand on 2026-11-05T13:10Z and it passed: 1,088,475 entries,
# 81 GiB, restore probe byte-identical, secrets tree match. That closes D-1 for
# exactly one day. The standing rule in this repo is that a backup taken once is not a
# backup policy — and the proof artifact that unblocks provision-jolhome-disk.sh
# expires after 7 days, so an unscheduled backup silently turns into "the migration is
# blocked" with nothing naming the cause. This installs the schedule.
#
# It is a SYSTEM unit, not a user unit, because the job needs root (it reads every
# owner under /home and writes a root-owned snapshot tree). The capacity watchdog is a
# user timer; this one is not, and that difference is deliberate.
#
# Idempotent, DRY_RUN by default, non-destructive.
#
# Usage:  sudo DRY_RUN=0 ./install-workstation-backup-timer.sh
#         ./install-workstation-backup-timer.sh          # plan, no root needed
# Rollback:
#   sudo systemctl disable --now jol-home-backup.timer
#   sudo rm /etc/systemd/system/jol-home-backup.{service,timer}
#   sudo systemctl daemon-reload
# =============================================================================
set -euo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

BIN="${BIN:-/usr/local/bin/jol-backup-home.sh}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
# 03:40 local. Chosen against the measured schedule, not picked at random:
#   02:00  hv01 vzdump nightly to pbs01
#   03:30  Qdrant snapshot on rag-prod-lt01
#   00:35  fstrim.timer (weekly)
#   09:17  jolarca state backup
#   23:20  jol-control state backup
#   every 15 min  the capacity watchdog
# 03:40 sits clear of all of them and off the top of the hour, where everything clusters.
SCHEDULE="${SCHEDULE:-*-*-* 03:40:00}"
DRY_RUN="${DRY_RUN:-1}"

say() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
# No run() helper: every mutation in this script is behind the single DRY_RUN early
# exit below, so a per-call wrapper would be dead code. An earlier draft defined one
# and never called it — the exact Basilica `assert_command()` pattern.

# --- guards ------------------------------------------------------------------
HOST_ID="$(hostname -s 2>/dev/null || echo unknown)"
for h in pve-prod-hv01 pbs01 llm-prod-lt01 rag-prod-lt01 mcp-prod-lt01 her-prod-lt01; do
    [[ "$HOST_ID" == "$h" ]] && { say "ABORT: $h is a fleet host; this schedules the custodian workstation's backup"; exit 2; }
done
if [[ "$DRY_RUN" != "1" && "$(id -u)" -ne 0 ]]; then
    say "ABORT: writing $UNIT_DIR needs root. Run without sudo to see the plan."
    exit 2
fi

# Dependency, checked not assumed: this timer invokes the installed binary, so the
# install step must have happened. Saying "run the installer first" is more useful
# than creating a unit that fails at 03:40 and nobody connects to the cause.
#
# ⚠ Existence and executability are DIFFERENT facts and must be reported separately.
# The first version tested `-x`, which for a 750 root:root binary is FALSE for an
# unprivileged user — so a plan run told the operator to re-run the other installer,
# which was already done and would have accomplished nothing. That is advice that
# sends a human in a circle. `-e` gates everyone; `-x` is only asserted for the apply
# path, where root is already required and the bit does resolve.
if [[ ! -e "$BIN" ]]; then
    say "ABORT: $BIN does not exist."
    say "       Run install-workstation-scripts.sh first — this timer schedules that binary, it does not install it."
    exit 2
fi
if [[ "$DRY_RUN" != "1" && ! -x "$BIN" ]]; then
    say "ABORT: $BIN exists but is not executable by uid $(id -u) even though root is required here — unexpected mode on the installed binary."
    say "       Check: ls -l $BIN   (expected 750 root:root)"
    exit 2
fi

say "=== install-workstation-backup-timer.sh (DRY_RUN=$DRY_RUN, host=$HOST_ID) ==="
say "schedule: $SCHEDULE   command: $BIN"
if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY  : would write %s/jol-home-backup.service\n' "$UNIT_DIR"
    printf 'DRY  : would write %s/jol-home-backup.timer\n' "$UNIT_DIR"
    printf 'DRY  : systemctl daemon-reload && enable --now jol-home-backup.timer\n'
    printf 'DRY  : then prove gate 6 fires against a deliberately stale fixture\n'
    exit 0
fi

cat >"$UNIT_DIR/jol-home-backup.service" <<'UNIT'
[Unit]
Description=JOL workstation /home backup to the off-device HDD (rsync snapshot chain, restore-proven)
Documentation=file:///opt/jol/repos/jol-infrastructure/docs/runbooks/workstation-storage-990pro-home-migration.md
# The destination is /mnt/jol-backup on sda1. If that mount is absent the job must
# refuse, not write a "backup" into a directory on / — which is precisely the failure
# that silently lost the Terraform state backups for four nights. Ordering on the
# mount makes systemd wait for it; the script also checks device identity itself,
# because an ordering dependency is not a substitute for verifying the destination.
After=mnt-jol\x2dbackup.mount
Requires=mnt-jol\x2dbackup.mount

[Service]
Type=oneshot
# Root is required to read every owner under /home and to write the snapshot tree.
User=root
ExecStart=/usr/local/bin/jol-backup-home.sh
Environment=DRY_RUN=0
# rc=1 means "the backup ran and did not verify" — a real, reportable outcome.
# Do NOT mask it with SuccessExitStatus: a unit that always looks green is the
# defect this whole thread exists to prevent.
Nice=15
IONiceClass=2
IONiceLevel=6
TimeoutStartSec=2h

[Install]
WantedBy=multi-user.target
UNIT

cat >"$UNIT_DIR/jol-home-backup.timer" <<UNIT
[Unit]
Description=Daily JOL workstation /home backup

[Timer]
# Calendar timer, so Persistent=true actually means something: against a monotonic
# OnUnitActiveSec it is a silent no-op. A laptop asleep at 03:40 runs on wake instead
# of losing the night.
OnCalendar=${SCHEDULE}
Persistent=true
AccuracySec=5min
RandomizedDelaySec=0

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now jol-home-backup.timer

echo
say "=== verify ==="
systemctl --no-pager list-timers jol-home-backup.timer | head -3 || true

# NEGATIVE CONTROL: the monitor must actually be able to fail.
# Two traps here, both hit earlier in this thread and both avoided deliberately:
#   (a) forcing HOME_BACKUP_MAX_AGE_H=0 against a snapshot taken minutes ago does NOT
#       fire, because age floors to 0 and `0 > 0` is false. The control would have
#       passed vacuously. Instead a fixture directory holding a 40 h-old snapshot is
#       used, so the condition is real rather than arithmetically degenerate.
#   (b) `if watchdog | grep -q X` under `set -o pipefail` inherits the WATCHDOG's rc=1
#       even when grep matched, so a correctly-firing gate reads as a failed control.
#       Output and status are captured separately.
# ⚠ Do NOT use $HOME here. This installer runs under sudo, where $HOME is /root, so
# `$HOME/.local/bin/jol-workstation-capacity-check.sh` does not exist and the command
# returned rc=127 — which this script then reported as "the /home backup is unmonitored".
# That is a false accusation produced entirely by the control's own path resolution:
# the watchdog was fine, the reference to it was wrong. Resolve the real operator's
# home from SUDO_USER, and fail with a precise reason rather than blaming the gate.
WATCHDOG="${WATCHDOG:-}"
if [[ -z "$WATCHDOG" ]]; then
    for c in \
        "/home/${SUDO_USER:-nomatch}/.local/bin/jol-workstation-capacity-check.sh" \
        "$HOME/.local/bin/jol-workstation-capacity-check.sh" \
        "/usr/local/bin/jol-workstation-capacity-check.sh"; do
        if [[ -x "$c" ]]; then WATCHDOG="$c"; break; fi
    done
fi
[[ -n "$WATCHDOG" ]] || { say "FAIL: cannot locate jol-workstation-capacity-check.sh; the gate-6 controls below cannot be run."; exit 1; }
say "watchdog under test: $WATCHDOG (as user ${SUDO_USER:-$USER})"

# Run the watchdog AS ITS OWN USER, not as root. Root reads everything, so the
# "unreadable directory" branch can never fire under sudo and the control would prove
# less than it appears to.
run_watchdog() { # $1=HOME_BACKUP_DIR override ("" = default)
    if [[ "$(id -u)" == "0" && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        if [[ -n "$1" ]]; then
            runuser -u "$SUDO_USER" -- env HOME="/home/$SUDO_USER" HOME_BACKUP_DIR="$1" NOTIFY=0 "$WATCHDOG"
        else
            runuser -u "$SUDO_USER" -- env HOME="/home/$SUDO_USER" NOTIFY=0 "$WATCHDOG"
        fi
    elif [[ -n "$1" ]]; then
        HOME_BACKUP_DIR="$1" NOTIFY=0 "$WATCHDOG"
    else
        NOTIFY=0 "$WATCHDOG"
    fi
}

HB_FIX="$(mktemp -d)"
mkdir -p "$HB_FIX/home-20260101T000000Z"
# The fixture is created by ROOT, but the watchdog is deliberately run as its own user
# (otherwise the "unreadable directory" branch can never fire and the control proves
# less than it appears to). Those two decisions contradicted each other: mktemp's
# 700 root:root mode made the non-root watchdog report UNVERIFIED, and the control
# failed for the wrong reason on 2026-11-05 even though gate 6 was working correctly.
# Hand the fixture to the user who will be asked to read it.
if [[ "$(id -u)" == "0" && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    chown -R "$SUDO_USER":"$SUDO_USER" "$HB_FIX" || fail "could not hand the gate-6 fixture to $SUDO_USER"
fi
say "--- gate 6 negative control (fixture snapshot dated ~78 days ago, ceiling 30 h, must fire) ---"
NEG_RC=0
NEG_OUT="$(run_watchdog "$HB_FIX" 2>&1)" || NEG_RC=$?
rm -rf "$HB_FIX"
if printf '%s\n' "$NEG_OUT" | grep -q 'gate 6:.*NOT running' && (( NEG_RC != 0 )); then
    say "OK   : gate 6 fires on a stale snapshot and exits non-zero (rc=$NEG_RC) — the monitor is live"
else
    say "FAIL : gate 6 did not fire on a stale fixture (rc=$NEG_RC) — the /home backup is unmonitored"
    printf '%s\n' "$NEG_OUT" | grep 'gate 6' || true
    exit 1
fi

# POSITIVE control: against the real snapshot the same gate must be quiet, or the
# negative control proves nothing about discrimination.
say "--- gate 6 positive control (real snapshot dir, must be judged fresh) ---"
# rc is deliberately NOT asserted here: other gates (the /home capacity alert) legitimately
# make the watchdog exit non-zero, so a non-zero status does not contradict gate 6 being
# green. Asserting on it would produce a control that fails for an unrelated reason.
# ⚠ The `|| true` is LOAD-BEARING, not decoration. This script is `set -e`, so a bare
# assignment from a command substitution that exits non-zero ABORTS the whole installer.
# When POS_RC was deleted as an unused variable, its `|| POS_RC=$?` went with it and the
# installer died here on 2026-11-05 — silently, after the timer was already installed,
# so the positive control never ran. Deleting dead code means re-reading what else the
# line was doing; this is the same mistake as deleting run() and its DRY_RUN guards.
POS_OUT="$(run_watchdog "" 2>&1)" || true
if printf '%s\n' "$POS_OUT" | grep -q 'gate 6: /home backup fresh'; then
    say "OK   : gate 6 reports the real snapshot fresh — the gate discriminates in both directions"
else
    say "FAIL : gate 6 did not report the real snapshot as fresh:"
    printf '%s\n' "$POS_OUT" | grep 'gate 6' || true
    exit 1
fi

say "=== done ==="
say "Next: run the capacity watchdog once as jol; gate 6 should report the snapshot fresh."
say "Rollback: systemctl disable --now jol-home-backup.timer;"
say "          rm $UNIT_DIR/jol-home-backup.{service,timer}; systemctl daemon-reload"
