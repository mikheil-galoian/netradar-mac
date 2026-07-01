# NetRadar

A tiny macOS **menu-bar radar** for your network. It lives in the top bar and
shows, at a glance, how many devices are on your LAN, whether a **new** device
just appeared, and how many **inbound** connections your Mac has — click it for
the full list of devices and live connections with reverse-DNS.

Self-contained native Swift/AppKit. No background daemon, no Node, no external
services. It only reads your own subnet via the standard `arp` and `lsof` tools.

## Menu bar

```
◐ 6        6 devices on the LAN
◐ 6!       a new device appeared (turns red)
```

Click to open:

```
LAN 6 · NEW 1 · IN 0
Devices
  192.168.0.1    router.local        — Apple · 98:00:6a:a2:ac:29
  192.168.0.27   —                   — 06:a6:92:cc:43:3d
Connections
  [out] Telegram   capablescene.ptr.network
  [out] Claude     160.79.104.10:443
Refresh now
Reset new-device baseline
Reveal data folder
Quit NetRadar
```

## Build

Requires macOS 12+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
sh scripts/build-app.sh
open build/NetRadar.app     # look at the top menu bar
```

The app is unsigned. On first launch macOS Gatekeeper may block it — right-click
the app → **Open**, or allow it in *System Settings → Privacy & Security*.

## Vendor names (optional, offline)

Vendor lookup uses the official IEEE OUI database. It is **not** bundled; fetch
it once (requires network), after which lookups are fully offline:

```sh
sh scripts/fetch-oui.sh
```

This writes `~/Library/Application Support/NetRadar/oui.txt`. Delete that file to
remove vendor data.

## How it works

Every 10 seconds NetRadar runs:

- `arp -an` — devices currently in your ARP table (your subnet). New MAC
  addresses that were not in the first snapshot are flagged as **NEW**. The
  baseline is stored in `~/Library/Application Support/NetRadar/baseline.json`;
  "Reset new-device baseline" re-seeds it from what is present now.
- `lsof -nP -iTCP -sTCP:LISTEN` / `-sTCP:ESTABLISHED` — established TCP
  connections, classified **IN** (to a port your Mac listens on) or **out**.

Reverse-DNS (`host`) resolves remote hosts, cached and rate-limited so the UI
never blocks. Nothing is sent to third-party services.

## Scope & limits

- `arp` only sees your own subnet — that is "your network". It cannot see past
  your router.
- One menu-bar summary + a dropdown list, not a full animated radar screen.
- Passive: it reads local system tables, it does not actively scan or probe.

## License

MIT — see [LICENSE](LICENSE).
