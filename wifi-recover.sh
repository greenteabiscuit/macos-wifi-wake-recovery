#!/bin/bash

# Recover Wi-Fi after a wake-time DHCP stall. If Cloudflare WARP was enabled,
# disconnect it before cycling Wi-Fi and reconnect it after the gateway is
# available. Independent failsafes and the EXIT/signal trap prevent either
# service from being left off if recovery is interrupted.

set -u

NETWORKSETUP="/usr/sbin/networksetup"
IPCONFIG="/usr/sbin/ipconfig"
ROUTE="/sbin/route"
PING="/sbin/ping"

find_warp_cli() {
  local candidate
  for candidate in \
    /usr/local/bin/warp-cli \
    /opt/homebrew/bin/warp-cli \
    "/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return
    fi
  done
}

WARP_CLI="$(find_warp_cli)"

wifi_device() {
  "$NETWORKSETUP" -listallhardwareports | /usr/bin/awk '
    $0 == "Hardware Port: Wi-Fi" { found = 1; next }
    found && /^Device: / { print $2; exit }
  '
}

interface="$(wifi_device)"

if [[ -z "$interface" ]]; then
  echo "Could not find the Wi-Fi interface." >&2
  exit 1
fi

power_state() {
  "$NETWORKSETUP" -getairportpower "$interface" 2>/dev/null |
    /usr/bin/awk '{ print tolower($NF) }'
}

turn_on() {
  "$NETWORKSETUP" -setairportpower "$interface" on >/dev/null 2>&1 || true
}

warp_should_reconnect() {
  local output="$1"
  local state reason
  state="$(echo "$output" | /usr/bin/sed -n 's/.*"status": "\([^"]*\)".*/\1/p')"
  reason="$(echo "$output" | /usr/bin/sed -n 's/.*"reason": "\([^"]*\)".*/\1/p')"

  case "$state" in
    Connected|Connecting|Unable)
      return 0
      ;;
    Disconnected)
      case "$reason" in
        Manual|ManualDisconnection|DisabledForWiFi|DisabledForEthernet|DisabledForNetwork|DisabledByOverride|Paused)
          return 1
          ;;
        *)
          return 0
          ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
}

reconnect_warp=0

restore_network() {
  turn_on
  if [[ "$reconnect_warp" -eq 1 ]]; then
    "$WARP_CLI" --no-ansi connect >/dev/null 2>&1 || true
  fi
}

status() {
  local state address gateway
  state="$(power_state)"
  address="$($IPCONFIG getifaddr "$interface" 2>/dev/null || true)"
  gateway="$($ROUTE -n get default 2>/dev/null | /usr/bin/awk '/gateway:/ { print $2; exit }')"

  echo "Wi-Fi interface: $interface"
  echo "Power: ${state:-unknown}"
  if [[ -n "$address" ]]; then
    echo "IPv4 address: $address"
  else
    echo "IPv4 address: not assigned"
  fi

  if [[ -z "$gateway" ]]; then
    echo "Gateway: not assigned"
  elif "$PING" -q -c 1 -W 1000 "$gateway" >/dev/null 2>&1; then
    echo "Gateway: reachable ($gateway)"
  else
    echo "Gateway: assigned but not responding to ping ($gateway)"
  fi

  if [[ -n "$WARP_CLI" ]]; then
    echo "Cloudflare WARP:"
    "$WARP_CLI" --no-ansi status 2>&1 | /usr/bin/sed 's/^/  /'
  else
    echo "Cloudflare WARP: not installed"
  fi
}

case "${1:-reset}" in
  status)
    status
    exit 0
    ;;
  reset)
    ;;
  *)
    echo "Usage: $0 [reset|status]" >&2
    exit 2
    ;;
esac

if [[ -n "$WARP_CLI" ]]; then
  warp_status="$("$WARP_CLI" --json status 2>/dev/null || true)"
  if warp_should_reconnect "$warp_status"; then
    reconnect_warp=1
    trap restore_network EXIT HUP INT TERM

    /usr/bin/nohup /bin/sh -c \
      'sleep 30; "$1" --no-ansi connect >/dev/null 2>&1' \
      warp-failsafe "$WARP_CLI" >/dev/null 2>&1 &

    echo "Disconnecting Cloudflare WARP..."
    if ! "$WARP_CLI" --no-ansi disconnect >/dev/null; then
      echo "Cloudflare WARP did not accept the disconnect request; continuing with Wi-Fi recovery." >&2
    fi
    /bin/sleep 1
  else
    echo "Cloudflare WARP is disabled or its state is unavailable; leaving it unchanged."
  fi
fi

if [[ "$(power_state)" != "on" ]]; then
  echo "Wi-Fi is off; turning it on."
  turn_on
else
  echo "Resetting Wi-Fi on $interface..."

  /usr/bin/nohup /bin/sh -c \
    'sleep 5; /usr/sbin/networksetup -setairportpower "$1" on >/dev/null 2>&1' \
    wifi-failsafe "$interface" >/dev/null 2>&1 &

  trap restore_network EXIT HUP INT TERM
  "$NETWORKSETUP" -setairportpower "$interface" off
  /bin/sleep 1
  turn_on
fi

echo "Waiting for an IPv4 address..."
wifi_online=0
for _ in {1..20}; do
  address="$($IPCONFIG getifaddr "$interface" 2>/dev/null || true)"
  gateway="$($ROUTE -n get default 2>/dev/null | /usr/bin/awk '/gateway:/ { print $2; exit }')"
  if [[ -n "$address" && -n "$gateway" ]]; then
    echo "Wi-Fi has IPv4 address $address and default gateway $gateway."
    wifi_online=1
    break
  fi
  /bin/sleep 1
done

if [[ "$wifi_online" -ne 1 ]]; then
  echo "Wi-Fi is on, but DHCP did not provide an IPv4 address and default route within 20 seconds." >&2
  exit 1
fi

if [[ "$reconnect_warp" -eq 1 ]]; then
  echo "Reconnecting Cloudflare WARP..."
  if ! "$WARP_CLI" --no-ansi connect >/dev/null; then
    echo "Cloudflare WARP did not accept the connect request." >&2
    exit 1
  fi

  for _ in {1..20}; do
    warp_status="$("$WARP_CLI" --json status 2>/dev/null || true)"
    if [[ "$warp_status" == *'"status": "Connected"'* ]]; then
      reconnect_warp=0
      echo "Cloudflare WARP is connected."
      exit 0
    fi
    /bin/sleep 1
  done

  echo "Cloudflare WARP did not reconnect within 20 seconds." >&2
  exit 1
fi

exit 0
