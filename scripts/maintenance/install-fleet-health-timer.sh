#!/usr/bin/env bash
# =============================================================================
# install-fleet-health-timer.sh — install the workstation alert PULL
#
# Idempotent, DRY_RUN by default, non-destructive (§ script design contract).
# Installs:
#   ~/.local/bin/jol-fleet-health-pull.sh              (the checker)
#   ~/.config/systemd/user/jol-fleet-health.service    (Type=oneshot)
#   ~/.config/systemd/user/jol-fleet-health.timer      (every 15 min, persistent)
#   systemctl --user enable --now jol-fleet-health.timer
#
# This is LAYER 3 of the alerting design and needs NO credential: it rides the SSH
# keys already in ~/.ssh/config. It does not replace a push channel — while the
# laptop is asleep nothing fires (see runbook §7.2 for the Telegram/SMTP decision).
#
# Usage:  DRY_RUN=0 ./install-fleet-health-timer.sh
# Rollback:
#   systemctl --user disable --now jol-fleet-health.timer
#   rm ~/.config/systemd/user/jol-fleet-health.{service,timer}
#   systemctl --user daemon-reload
#   rm ~/.local/bin/jol-fleet-health-pull.sh
# =============================================================================
set -euo pipefail

DRY_RUN="${DRY_RUN:-1}"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
SCRIPT_SRC="$(dirname "$(readlink -f "$0")")/fleet-health-pull.sh"
[[ -f "$SCRIPT_SRC" ]] || { echo "ABORT: $SCRIPT_SRC not found (run from the repo)"; exit 2; }

run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf 'DRY  : %s\n' "$*"
    else
        printf 'APPLY: %s\n' "$*"
        "$@"
    fi
}

echo "=== install-fleet-health-timer.sh (DRY_RUN=$DRY_RUN) ==="
echo "source script: $SCRIPT_SRC"

run mkdir -p "$BIN_DIR" "$UNIT_DIR"
run install -m 750 "$SCRIPT_SRC" "$BIN_DIR/jol-fleet-health-pull.sh"

if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY  : would write %s/jol-fleet-health.service\n' "$UNIT_DIR"
    printf 'DRY  : would write %s/jol-fleet-health.timer\n' "$UNIT_DIR"
    printf 'DRY  : systemctl --user daemon-reload && enable --now jol-fleet-health.timer\n'
else
    cat >"$UNIT_DIR/jol-fleet-health.service" <<'UNIT'
[Unit]
Description=JOL fleet health pull (hv01 + pbs01 watchdogs -> desktop alert)
Documentation=file://opt/jol/repos/jol-infrastructure/docs/runbooks/hv01-storage-backup-reconfiguration.md
# A network failure must NOT look like a healthy fleet: the script treats an
# unreachable host as an alert, so it needs connectivity resolved first.
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# Hardening: the pull only needs to read SSH config + talk outbound.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only
# $HOME/.local/share/jol-fleet-health is the only writable path required.
ReadWritePaths=%h/.local/share/jol-fleet-health
ExecStart=%h/.local/bin/jol-fleet-health-pull.sh
# notify-send needs the desktop bus; without it the log line still records truth.
Environment=NOTIFY=1
TimeoutStartSec=180
UNIT

    cat >"$UNIT_DIR/jol-fleet-health.timer" <<'UNIT'
[Unit]
Description=Run the JOL fleet health pull every 15 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=15min
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now jol-fleet-health.timer
fi

echo
echo "=== verify ==="
if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY  : systemctl --user list-timers jol-fleet-health.timer"
    echo "DRY  : systemctl --user start jol-fleet-health.service --wait"
else
    systemctl --user list-timers jol-fleet-health.timer --no-pager | head -3
    # Prove the timer can actually raise an alert NOW (hv01 reports the dead mail
    # transport, so this must fail with rc=1 and a critical notification).
    if systemctl --user start jol-fleet-health.service --wait; then
        echo "NOTE : service exited 0 — every host healthy (or the pull is blind; check its log)"
    else
        echo "OK   : service exited non-zero — alert raised as designed"
    fi
    tail -6 "$HOME/.local/share/jol-fleet-health/pull.log" 2>/dev/null || true
fi
echo "=== done ==="
