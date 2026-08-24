#!/bin/bash

# Recover Wi-Fi after a wake-time DHCP stall. Before switching Wi-Fi off, an
# independent failsafe is scheduled to turn it back on. The EXIT/signal trap
# is a second safeguard.

set -u

NETWORKSETUP="/usr/sbin/networksetup"
IPCONFIG="/usr/sbin/ipconfig"
ROUTE="/sbin/route"
PING="/sbin/ping"

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

  if [[ -n "$gateway" ]] && "$PING" -q -c 1 -W 1000 "$gateway" >/dev/null 2>&1; then
    echo "Gateway: reachable ($gateway)"
  else
    echo "Gateway: not reachable"
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

if [[ "$(power_state)" != "on" ]]; then
  echo "Wi-Fi is off; turning it on."
  turn_on
else
  echo "Resetting Wi-Fi on $interface..."

  /usr/bin/nohup /bin/sh -c \
    'sleep 5; /usr/sbin/networksetup -setairportpower "$1" on >/dev/null 2>&1' \
    wifi-failsafe "$interface" >/dev/null 2>&1 &

  trap turn_on EXIT HUP INT TERM
  "$NETWORKSETUP" -setairportpower "$interface" off
  /bin/sleep 1
  turn_on
fi

echo "Waiting for an IPv4 address..."
for _ in {1..20}; do
  address="$($IPCONFIG getifaddr "$interface" 2>/dev/null || true)"
  gateway="$($ROUTE -n get default 2>/dev/null | /usr/bin/awk '/gateway:/ { print $2; exit }')"
  if [[ -n "$address" && -n "$gateway" ]] && \
    "$PING" -q -c 1 -W 1000 "$gateway" >/dev/null 2>&1; then
    echo "Wi-Fi is back online with IPv4 address $address."
    exit 0
  fi
  /bin/sleep 1
done

echo "Wi-Fi is on, but DHCP did not assign an IPv4 address within 20 seconds." >&2
echo "The router/DHCP service is still not responding." >&2
exit 1
