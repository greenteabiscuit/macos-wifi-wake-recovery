#!/bin/bash

set -u

LABEL="local.wifi-wake-recovery"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INSTALL_DIR="$HOME/Library/Application Support/WiFiWakeRecovery"

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST"
rm -rf "$INSTALL_DIR"

echo "Wi-Fi wake recovery has been removed. Logs were left in place."
