#!/bin/bash
# Build, install and start the app.
#
#   ./install.sh              build + install + start
#   ./install.sh --login      also start it automatically at login
#
# Also migrates an install of the old BatteryHistory identity: the recorded
# history moves to the new data directory, and the old login item is booted out
# and deleted so the renamed app cannot end up running twice.
#
# Paths can be overridden for testing: APP_DIR, DATA_DIR, AGENT_DIR.
set -euo pipefail
cd "$(dirname "$0")"

# ---- app identity: the only line in this file that names the app ----
NAME="SysMonitor"
# --------------------------------------------------------------------

LABEL="local.ktutnik.$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]')"
APP_DIR="${APP_DIR:-$HOME/Applications}"
AGENT_DIR="${AGENT_DIR:-$HOME/Library/LaunchAgents}"
DATA_DIR="${DATA_DIR:-$HOME/Library/Application Support/$NAME}"
APP="$APP_DIR/$NAME.app"
PLIST="$AGENT_DIR/$LABEL.plist"

# The identity this app was renamed from. Only used by the migration below.
OLD_NAME="BatteryHistory"
OLD_LABEL="local.ktutnik.batteryhistory"
OLD_APP="$APP_DIR/$OLD_NAME.app"
OLD_PLIST="$AGENT_DIR/$OLD_LABEL.plist"
OLD_DATA_DIR="${OLD_DATA_DIR:-$HOME/Library/Application Support/$OLD_NAME}"

WANT_LOGIN=0
[ "${1:-}" = "--login" ] && WANT_LOGIN=1

echo "==> building"
mkdir -p "$APP_DIR"
./build.sh "$APP" >/dev/null

echo "==> stopping any running copy"
pkill -x "$NAME" 2>/dev/null || true
pkill -x "$OLD_NAME" 2>/dev/null || true
sleep 1

# The old login item would start the old binary again behind our back.
if [ -f "$OLD_PLIST" ]; then
  echo "==> removing the old login item ($OLD_LABEL)"
  launchctl bootout "gui/$UID/$OLD_LABEL" 2>/dev/null || true
  rm -f "$OLD_PLIST"
fi
if [ -d "$OLD_APP" ]; then
  echo "note: the old app is still at $OLD_APP -- delete it when you are happy."
fi

# Move the history across, once. Never merge, never overwrite: if the new
# directory already exists the old one is left exactly where it is.
if [ -d "$OLD_DATA_DIR" ] && [ ! -e "$DATA_DIR" ]; then
  echo "==> moving recorded history to $DATA_DIR"
  mkdir -p "$(dirname "$DATA_DIR")"
  mv "$OLD_DATA_DIR" "$DATA_DIR"
elif [ -d "$OLD_DATA_DIR" ] && [ -e "$DATA_DIR" ]; then
  echo "note: $DATA_DIR already exists, so $OLD_DATA_DIR was left untouched."
fi

if [ "$WANT_LOGIN" = 1 ]; then
  echo "==> registering login item ($PLIST)"
  mkdir -p "$AGENT_DIR"
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/$NAME</string></array>
  <key>RunAtLoad</key><true/>
  <!-- A menu bar app the user quit on purpose must stay quit until next login. -->
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$UID" "$PLIST"
else
  echo "==> starting"
  open "$APP"
fi

echo
echo "installed: $APP"
[ "$WANT_LOGIN" = 1 ] && echo "login item: $PLIST (starts at every login)"
echo "history:   $DATA_DIR"
echo
echo "The icon is in the menu bar. Quit it from the gear menu in the dropdown."
[ "$WANT_LOGIN" = 0 ] && echo "Run ./install.sh --login to have it start at login."
exit 0
