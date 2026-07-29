# HomeDataTrack

Knowing how much data you have actually used, from both ends of the connection.

## [`macos/`](macos) — DataTrack for macOS

Tracks data usage **per Wi-Fi network** on the Mac itself, so tethering to a phone
with a capped bundle stops being a gamble. Native Swift: a menu bar app, a CLI,
and a launchd sampler.

macOS reports bytes per *interface*, never per network, and as of macOS 26 it will
not even disclose the Wi-Fi network's name without Location Services
authorization. DataTrack works around both — networks are identified by gateway
MAC address, which needs no permission at all — and adds per-process attribution,
so a 6 GB background update gets named rather than merely noticed.

- Per-network daily totals, kept indefinitely
- Budgets with alerts at 50 / 80 / 95 / 100 % of a monthly or rolling-30-day allowance
- Which process spent it (`softwareupdated`, `nsurlsessiond`, and friends)
- Automatic metered-network detection for phone hotspots
- No sudo, no system extension, no Xcode required

See [`macos/README.md`](macos/README.md) for install, and for the details of what
macOS will and will not tell you.

## [`legacy/`](legacy) — the original (2016), archived

`DataTrack.py` polled a Telkom web portal with PyQt4 and pushed the figures the
*carrier* reported into Firebase. Archived and no longer runnable: PyQt4 and
QtWebKit are gone, and Firebase's legacy database secrets were retired.

It measured the same quantity from the opposite end. The carrier's number is
authoritative for billing but arrives late; the Mac's own counters are immediate,
which is what you need to catch a runaway download while it is still running.

See [`legacy/README.md`](legacy/README.md) for what it did and why it stopped
working.
