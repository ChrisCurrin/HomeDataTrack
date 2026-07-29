#!/bin/bash
# Installs the datatrack CLI and registers a launchd agent that samples
# continuously, so usage is recorded whether or not the menu bar app is open.
#
# Everything lands under $HOME. No sudo, no system-level daemon, nothing to
# uninstall outside your own account.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

LABEL="com.chriscurrin.datatrack"
BIN_DIR="$HOME/.local/bin"
AGENT_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs"
PLIST="$AGENT_DIR/$LABEL.plist"
INTERVAL="${DATATRACK_INTERVAL:-10}"

echo "==> Building release binary"
swift build -c release
BUILD_BIN="$(swift build -c release --show-bin-path)"

echo "==> Installing datatrack to $BIN_DIR"
mkdir -p "$BIN_DIR" "$AGENT_DIR" "$LOG_DIR"
install -m 755 "$BUILD_BIN/datatrack" "$BIN_DIR/datatrack"

# Unload any previous agent before rewriting the plist, otherwise launchd keeps
# running the old binary path.
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "==> Unloading existing agent"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
fi

echo "==> Writing $PLIST"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DIR/datatrack</string>
        <string>watch</string>
        <string>--interval</string>
        <string>$INTERVAL</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/datatrack.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/datatrack.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/sbin:/usr/bin:/sbin:/bin</string>
    </dict>
</dict>
</plist>
PLIST_EOF

echo "==> Loading agent"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/$LABEL" 2>/dev/null || true

sleep 2
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "==> Agent is running"
else
    echo "!! Agent did not start. Check $LOG_DIR/datatrack.log" >&2
    exit 1
fi

cat <<EOF

Installed.

  Sampling every ${INTERVAL}s, logging to $LOG_DIR/datatrack.log

Next steps:

  $BIN_DIR/datatrack doctor            What this Mac will and will not disclose
  $BIN_DIR/datatrack status            Current network and today's usage
  $BIN_DIR/datatrack name current "iPhone Hotspot"
  $BIN_DIR/datatrack budget set current 5GB --cycle monthly

Add $BIN_DIR to your PATH if it is not already there.

To remove:
  launchctl bootout gui/\$(id -u)/$LABEL
  rm $PLIST $BIN_DIR/datatrack
EOF
