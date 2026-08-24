# macOS Wi-Fi Wake Recovery

A small launch agent for Macs that get stuck with a stale DHCP connection
after opening the lid. It listens for a user-triggered lid-open wake and, only
on configured networks, safely power-cycles Wi-Fi and waits for the default
gateway to become available. When Cloudflare WARP is installed and enabled,
it disconnects WARP before cycling Wi-Fi and reconnects it afterward.

## How it works

- Detects wake events with `NSWorkspace`.
- Ignores background wakes and wakes while the lid is closed.
- Matches locally configured SSIDs or router IPs before sleep and after wake,
  so recovery still runs when the broken connection loses its route on wake.
- Preserves the Cloudflare WARP toggle state: an enabled or failed connection
  is restarted, while an intentionally disabled connection remains disabled.
- Schedules a failsafe before turning Wi-Fi off, so an interruption cannot
  leave Wi-Fi or WARP disabled.
- Waits up to 20 seconds each for DHCP/default routing and WARP to recover.

## Requirements

- macOS
- Apple's Command Line Tools (`xcode-select --install`) to compile the Swift
  monitor during installation
- Optional: Cloudflare WARP. The recovery script automatically uses
  `warp-cli` when the app is installed.

## Install

Clone the repository, then provide one or more network identifiers:

```bash
./install.sh --ssid "Your Wi-Fi Name" --router "192.168.1.1"
```

Either type is optional as long as at least one value is supplied. Repeat an
option to match multiple values. The launch agent starts immediately and on
each login.

Network identifiers are written with mode `0600` to:

```text
~/Library/Application Support/WiFiWakeRecovery/config.plist
```

They are never written into the repository. Runtime logs remain under
`~/Library/Logs/` and are not part of the repository either.

## Manual recovery and status

After installation:

```bash
~/Library/Application\ Support/WiFiWakeRecovery/wifi-recover.sh status
~/Library/Application\ Support/WiFiWakeRecovery/wifi-recover.sh reset
```

## Uninstall

```bash
./uninstall.sh
```

The uninstaller removes the launch agent, executable, source copy, and private
configuration. It intentionally leaves logs in place.

## Privacy

This repository contains no SSIDs, router addresses, usernames, absolute home
paths, compiled binaries, generated launch-agent files, or runtime logs. Your
network configuration exists only on the machine where you run the installer.

## License

[MIT](LICENSE)
