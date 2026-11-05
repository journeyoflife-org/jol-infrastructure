#!/usr/bin/env bash
# =============================================================================
# install-workstation-capacity-timer.sh — install the workstation capacity watchdog
#
# Idempotent, DRY_RUN by default, non-destructive (§ script design contract).
# Installs:
#   ~/.local/bin/jol-workstation-capacity-check.sh           (the checker)
#   ~/.config/systemd/user/jol-workstation-capacity.service  (Type=oneshot)
#   ~/.config/systemd/user/jol-workstation-capacity.timer    (every 15 min, persistent)
#   systemctl --user enable --now jol-workstation-capacity.timer
#
# WHY A USER TIMER AND NOT CRON: the checker raises desktop notifications, and
# notify-send needs the session's D-Bus address — a cron job runs outside it and would
# silently lose every alert. A lingering user service also survives the laptop
# suspending, which is when /home actually fills (IDE indexing + agent sessions).
#
# This closes the 2026-11-04 gap: /home hit 100 % with 1.3 MB free and the ONLY signal
# was the GNOME popup at "<50 MiB left". There was no capacity watchdog anywhere.
#
# Usage:  DRY_RUN=0 ./install-workstation-capacity-timer.sh
# Rollback:
#   systemctl --user disable --now jol-workstation-capacity.timer
#   rm ~/.config/systemd/user/jol-workstation-capacity.{service,timer}
#   systemctl --user daemon-reload
#   rm ~/.local/bin/jol-workstation-capacity-check.sh
#   # state/log dir is evidence — keep it, or remove deliberately:
#   # rm -rf ~/.local/share/jol-fleet-health/capacity*
# =============================================================================
set -euo pipefail

DRY_RUN="${DRY_RUN:-1}"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
SCRIPT_SRC="$(dirname "$(readlink -f "$0")")/workstation-capacity-check.sh"
[[ -f "$SCRIPT_SRC" ]] || { echo "ABORT: $SCRIPT_SRC not found (run from the repo)"; exit 2; }

run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf 'DRY  : %s\n' "$*"
    else
        printf 'APPLY: %s\n' "$*"
        "$@"
    fi
}

echo "=== install-workstation-capacity-timer.sh (DRY_RUN=$DRY_RUN) ==="
echo "source script: $SCRIPT_SRC"
HOST_NOW="$(hostname -s 2>/dev/null || echo unknown)"

# Syntax-check before anything is installed. A watchdog that cannot parse is worse than
# no watchdog: the timer would report success while measuring nothing.
bash -n "$SCRIPT_SRC" || { echo "ABORT: syntax check failed on $SCRIPT_SRC"; exit 2; }
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "$SCRIPT_SRC" || echo "NOTE: shellcheck reported warnings (not blocking the install)"
fi

run mkdir -p "$BIN_DIR" "$UNIT_DIR"
run install -m 750 "$SCRIPT_SRC" "$BIN_DIR/jol-workstation-capacity-check.sh"

if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY  : would write %s/jol-workstation-capacity.service\n' "$UNIT_DIR"
    printf 'DRY  : would write %s/jol-workstation-capacity.timer\n' "$UNIT_DIR"
    printf 'DRY  : systemctl --user daemon-reload && enable --now jol-workstation-capacity.timer\n'
else
    cat >"$UNIT_DIR/jol-workstation-capacity.service" <<'UNIT'
[Unit]
Description=JOL workstation capacity watchdog (/home, inodes, mount reality, self-liveness)
Documentation=file:///opt/jol/repos/jol-infrastructure/scripts/maintenance/workstation-capacity-check.sh
# Gate 2 reads live mounts and gate 3b reads the unit state; both are meaningless
# before the filesystems exist.
After=local-fs.target

[Service]
Type=oneshot
# The checker is read-only apart from its own state under %h/.local/share, so it gets
# no write access anywhere else. NoNewPrivileges: it never needs to escalate.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=%h/.local/share/jol-fleet-health
ExecStart=%h/.local/bin/jol-workstation-capacity-check.sh
# notify-send needs the session bus; without it the log line and the journal still
# record truth, and the checker says so instead of failing quietly.
Environment=NOTIFY=1
# rc=1 means "an alert fired" — that is the CORRECT result of a full disk, and systemd
# must record the unit as failed so `systemctl --user status` and the journal show the
# truth. A oneshot service is never retried, so there is no retry storm to protect
# against; masking rc=1 with SuccessExitStatus would hide every alert state from the
# one place an operator looks after a notification is missed.
TimeoutStartSec=120
UNIT

    cat >"$UNIT_DIR/jol-workstation-capacity.timer" <<'UNIT'
[Unit]
Description=Run the JOL workstation capacity watchdog every 15 minutes

[Timer]
# CALENDAR timer, deliberately not OnUnitActiveSec. `Persistent=true` only has meaning
# for calendar timers — against a monotonic OnUnitActiveSec it is silently a no-op, and
# the comment claiming post-suspend catch-up would have been decoration. With a calendar
# schedule, a laptop that was asleep at :00/:15/:30/:45 runs the check on wake instead
# of losing the interval, which is when /home actually fills.
OnCalendar=*:0/15
Persistent=true
AccuracySec=1min
RandomizedDelaySec=0

[Install]
WantedBy=timers.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now jol-workstation-capacity.timer
fi

echo
echo "=== verify ==="
if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY  : sha256 parity repo vs installed"
    echo "DRY  : systemctl --user list-timers jol-workstation-capacity.timer"
    echo "DRY  : systemctl --user start jol-workstation-capacity.service --wait"
    echo "DRY  : NEGATIVE CONTROL -> CAP_ALERT_PCT=50 expect CRITICAL + rc=1"
else
    echo "--- sha parity (provenance: the host copy must equal the repo copy) ---"
    sha256sum "$SCRIPT_SRC" "$BIN_DIR/jol-workstation-capacity-check.sh" | awk '{print $1}' |
        sort -u | wc -l | xargs -I{} sh -c 'test "{}" = "1" && echo "OK   : identical" || echo "FAIL : repo and installed copies differ"'
    systemctl --user list-timers jol-workstation-capacity.timer --no-pager | head -3

    echo "--- positive control: real thresholds, expect rc=0 on a healthy disk ---"
    if systemctl --user start jol-workstation-capacity.service --wait; then
        echo "OK   : service exited 0 — all capacity gates green"
    else
        echo "ALERT: service exited non-zero — a capacity gate fired (read the log below)"
    fi

    echo "--- NEGATIVE CONTROL: forced thresholds must actually fire ---"
    # A watchdog that has never been seen to fail is indistinguishable from a dead one.
    # Run the SAME installed binary with CAP_ALERT_PCT=50; on this host several mounts sit
    # above that, so it MUST print CRITICAL and exit non-zero.
    # ⚠ The first version of this control printed FAIL against a watchdog that had just
    #   raised 5 CRITICALs and exited 1. Cause: `set -o pipefail` makes the pipeline
    #   inherit the CHECKER's non-zero status even when grep matches, so a working
    #   watchdog read as a blind one. A verification that fails when the thing under test
    #   works correctly is the more dangerous of the two bugs — it invites "fixing" the
    #   gate until it stops reporting. Capture output and exit code SEPARATELY, then assert
    #   on both.
    NEG_RC=0
    NEG_OUT="$(CAP_ALERT_PCT=50 NOTIFY=0 "$BIN_DIR/jol-workstation-capacity-check.sh" 2>&1)" || NEG_RC=$?
    NEG_HITS="$(printf '%s\n' "$NEG_OUT" | grep -c 'CRITICAL: capacity:')"
    if (( NEG_HITS > 0 )) && (( NEG_RC != 0 )); then
        echo "OK   : negative control fired — ${NEG_HITS} capacity CRITICAL(s), rc=${NEG_RC}"
    else
        echo "FAIL : negative control did not fire (CRITICALs=${NEG_HITS}, rc=${NEG_RC}) — do not trust this watchdog's green"
        printf '%s\n' "$NEG_OUT" | tail -8
        exit 1
    fi

    echo "--- GUARD CONTROL: a fleet host must be REFUSED, not measured wrongly ---"
    # rc=2 is a refusal to run. If FLEET_HOSTS matched this machine it would have aborted
    # above, so prove the branch exists and discriminates by naming this host as a fleet host.
    if FLEET_HOSTS="$HOST_NOW" "$BIN_DIR/jol-workstation-capacity-check.sh" >/dev/null 2>&1; then
        echo "FAIL : guard did not refuse a fleet-host identity"
        exit 1
    else
        echo "OK   : guard refuses to certify a fleet host as the workstation (rc=2 path live)"
    fi
    tail -6 "$HOME/.local/share/jol-fleet-health/capacity.log" 2>/dev/null || true
fi
echo "=== done ==="
