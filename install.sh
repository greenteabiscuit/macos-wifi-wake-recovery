#!/bin/bash

set -euo pipefail

LABEL="local.wifi-wake-recovery"
INSTALL_DIR="$HOME/Library/Application Support/WiFiWakeRecovery"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
SSIDS=()
ROUTERS=()

usage() {
  cat <<'EOF'
Usage: ./install.sh [--ssid NAME]... [--router ADDRESS]...

At least one --ssid or --router is required. Repeat either option to match
multiple Wi-Fi networks or router addresses.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssid)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      SSIDS+=("$2")
      shift 2
      ;;
    --router)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      ROUTERS+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ${#SSIDS[@]} -eq 0 && ${#ROUTERS[@]} -eq 0 ]]; then
  echo "Provide at least one --ssid or --router." >&2
  usage >&2
  exit 2
fi

command -v swiftc >/dev/null 2>&1 || {
  echo "swiftc is required. Install Apple's Command Line Tools with: xcode-select --install" >&2
  exit 1
}

mkdir -p "$INSTALL_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 0644 "$SOURCE_DIR/WiFiWakeMonitor.swift" "$INSTALL_DIR/WiFiWakeMonitor.swift"
install -m 0755 "$SOURCE_DIR/wifi-recover.sh" "$INSTALL_DIR/wifi-recover.sh"

CONFIG="$INSTALL_DIR/config.plist"
rm -f "$CONFIG"
/usr/bin/plutil -create xml1 "$CONFIG"
/usr/bin/plutil -insert SSIDs -array "$CONFIG"
for i in "${!SSIDS[@]}"; do
  /usr/bin/plutil -insert "SSIDs.$i" -string "${SSIDS[$i]}" "$CONFIG"
done
/usr/bin/plutil -insert Routers -array "$CONFIG"
for i in "${!ROUTERS[@]}"; do
  /usr/bin/plutil -insert "Routers.$i" -string "${ROUTERS[$i]}" "$CONFIG"
done
chmod 0600 "$CONFIG"

swiftc \
  -framework AppKit \
  -framework CoreWLAN \
  -framework IOKit \
  -framework SystemConfiguration \
  "$INSTALL_DIR/WiFiWakeMonitor.swift" \
  -o "$INSTALL_DIR/wifi-wake-monitor"

TMP_PLIST="$(mktemp)"
trap 'rm -f "$TMP_PLIST"' EXIT
/usr/bin/plutil -create xml1 "$TMP_PLIST"
/usr/bin/plutil -insert Label -string "$LABEL" "$TMP_PLIST"
/usr/bin/plutil -insert ProgramArguments -array "$TMP_PLIST"
/usr/bin/plutil -insert ProgramArguments.0 -string "$INSTALL_DIR/wifi-wake-monitor" "$TMP_PLIST"
/usr/bin/plutil -insert RunAtLoad -bool YES "$TMP_PLIST"
/usr/bin/plutil -insert KeepAlive -bool YES "$TMP_PLIST"
/usr/bin/plutil -insert ProcessType -string Background "$TMP_PLIST"
/usr/bin/plutil -insert ThrottleInterval -integer 10 "$TMP_PLIST"
/usr/bin/plutil -insert StandardOutPath -string "$HOME/Library/Logs/WiFiWakeRecovery.launchd.log" "$TMP_PLIST"
/usr/bin/plutil -insert StandardErrorPath -string "$HOME/Library/Logs/WiFiWakeRecovery.launchd.log" "$TMP_PLIST"
install -m 0644 "$TMP_PLIST" "$PLIST"

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Installed and started $LABEL."
echo "Private configuration: $CONFIG"
echo "Log: $HOME/Library/Logs/WiFiWakeRecovery.log"
