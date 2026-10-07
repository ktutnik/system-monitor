#!/bin/bash
# Remove the app.
#
#   ./uninstall.sh            remove the app and the login item, KEEP the history
#   ./uninstall.sh --purge    also delete the recorded charge history
#
# This targets the current identity only. If an old BatteryHistory install is
# still around, run that copy's own uninstall.sh, or let install.sh boot it out.
#
# Paths can be overridden for testing: APP_DIR, DATA_DIR, AGENT_DIR.
set -euo pipefail

# ---- app identity: the only line in this file that names the app ----
NAME="SysMonitor"
# --------------------------------------------------------------------

LABEL="local.ktutnik.$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]')"
APP_DIR="${APP_DIR:-$HOME/Applications}"
AGENT_DIR="${AGENT_DIR:-$HOME/Library/LaunchAgents}"
DATA_DIR="${DATA_DIR:-$HOME/Library/Application Support/$NAME}"
APP="$APP_DIR/$NAME.app"
PLIST="$AGENT_DIR/$LABEL.plist"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

echo "==> stopping"
pkill -x "$NAME" 2>/dev/null || true

if [ -f "$PLIST" ]; then
  echo "==> removing login item"
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
fi

if [ -d "$APP" ]; then
  echo "==> removing $APP"
  rm -rf "$APP"
fi

if [ "$PURGE" = 1 ]; then
  # The store is the only copy of anything older than about a week -- pmset cannot
  # give it back. Deleting it is opt-in for that reason.
  if [ -d "$DATA_DIR" ]; then
    n=$(ls -1 "$DATA_DIR" 2>/dev/null | wc -l | tr -d ' ')
    echo "==> deleting $n day(s) of recorded history: $DATA_DIR"
    rm -rf "$DATA_DIR"
  fi
else
  if [ -d "$DATA_DIR" ]; then
    echo
    echo "kept: $DATA_DIR ($(ls -1 "$DATA_DIR" | wc -l | tr -d ' ') days of history)"
    echo "      re-run with --purge to delete it too."
  fi
fi

echo
echo "uninstalled."
exit 0
