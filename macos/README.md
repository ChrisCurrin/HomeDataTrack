# DataTrack for macOS

Tracks how much data your Mac has used **per Wi-Fi network**, so tethering to a
phone with a capped bundle stops being a gamble.

macOS itself will not tell you this. It reports bytes per *interface* — `en0`
holds one running total across every network you have ever joined — and it does
not break that total down by network, by day, or by what spent it. So when
`softwareupdated` quietly pulls a 6 GB update over your hotspot, there is nothing
after the fact that says where the data went.

```
$ datatrack status
Current network
  Name      iPhone Hotspot   ⚠︎ metered
  Interface en0 (macOS marks this link constrained)
  Gateway   172.20.10.1 · 9a:1f:04:c2:88:e1
  Id        3   (gw:9a:1f:04:c2:88:e1)

Today
  ↓ 1.84 GB   ↑ 122 MB   total 1.96 GB

  Budget    ████████████░░░░░░░░░░░░ 49%
            1.96 GB of 4.00 GB (2.04 GB left) · monthly cycle from 2026-07-15

Top processes today
  softwareupdated              1.61 GB
  Safari                        212 MB
  nsurlsessiond                  94 MB
```

## What you get

- **Per-network totals**, daily, kept indefinitely.
- **Budgets with alerts** at 50 / 80 / 95 / 100 % of a monthly or rolling-30-day
  allowance. Each threshold notifies once per cycle.
- **Per-process attribution** — which program actually spent it. This is the part
  that names `softwareupdated` before you get the bill instead of after.
- **Automatic metered detection** for phone hotspots, via the gateway address and
  the kernel's own `constrained` interface flag.
- **A menu bar readout** showing today's usage, or percent-of-budget once a limit
  is set.

## Install

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).
Full Xcode is not needed.

```bash
cd macos

# Background sampler: records usage whether or not the UI is open.
./Scripts/install-agent.sh

# Menu bar app (optional).
./Scripts/build-app.sh
open build/DataTrack.app
```

The agent runs as a per-user launchd job under `$HOME`. No sudo, no system
extension, nothing installed outside your account. To remove it:

```bash
launchctl bootout gui/$(id -u)/com.chriscurrin.datatrack
rm ~/Library/LaunchAgents/com.chriscurrin.datatrack.plist ~/.local/bin/datatrack
```

The app alone is also a complete install — if the launchd agent is not present,
the app samples in-process while it is running.

## Usage

```bash
datatrack doctor                 # what this Mac will and will not disclose
datatrack status                 # current network, today, budget
datatrack networks               # every network seen, with lifetime totals
datatrack history 3 --days 30    # daily breakdown for network 3
datatrack top --days 7           # which processes used the data
datatrack name current "iPhone Hotspot"
datatrack budget set current 5GB --cycle monthly --start-day 15
datatrack meter current on
datatrack reset-processes        # discard per-process history, keep network totals
```

Start with `datatrack doctor`. Privacy gating varies by macOS version and by how
the binary is signed, and `doctor` reports exactly what your machine allows.

## The two things that make this hard

### macOS hides the Wi-Fi network name

As of macOS 26, the SSID is gated behind Location Services authorization. From an
unsigned CLI, every route to it fails:

| Method | Result |
| --- | --- |
| `CWInterface.ssid()` | `nil` |
| `networksetup -getairportnetwork en0` | "You are not associated with an AirPort network" — while associated |
| `system_profiler SPAirPortDataType` | `<redacted>` |

Signal strength, channel, and PHY mode are *not* gated. Only the name is.

So networks are identified by **gateway MAC address** instead, read from the ARP
table, which needs no permission at all. That turns out to be the better key
regardless: it is stable across SSID renames, it distinguishes two networks that
share a name, and it does not change when you grant or revoke location access.
If identity were keyed on the SSID, granting Location Services later would fork
one network's history into two records.

The cost is that a new network shows up as `Network at 172.20.10.1` rather than by
name. Two ways to fix that:

- `datatrack name current "iPhone Hotspot"` — takes five seconds, works forever.
- Run the menu bar app and grant location access. As a signed bundle it *can*
  read the SSID, and it backfills the name onto the existing record.

### Byte counters are per-interface, and the 64-bit ones are not where you'd expect

Attribution is a differencing problem: read `en0`'s total, subtract the previous
reading, credit the difference to whichever network was active. Two traps:

**Counter resets.** A reboot or an interface teardown sends the counter back to
zero. Subtracting naively underflows to roughly 18 exabytes and trips every alarm
you own. A decrease is therefore treated as a reset, and the interval is dropped.

**The 64-bit counters.** The obvious native route is `sysctl(NET_RT_IFLIST2)`
walked as `if_msghdr2`, whose `ifm_data` carries 64-bit byte counts. On macOS
26.5 that silently returns the wrong number: Swift's imported `if_msghdr2` is 160
bytes while the kernel emits `ifm_msglen == 180`, so reading at the imported
offset lands on a 32-bit field. Measured, the value came back as
`945,435,648` against a true total of `69,664,912,535` — exactly the truth mod
2³², and a byte-wise scan of all 180 bytes found the real 64-bit value nowhere.

A 32-bit counter wraps every 4 GiB, which is well inside a single macOS update —
precisely the event this tool exists to catch. So `netstat -ibn` is the source of
record: Apple-shipped, unprivileged, and demonstrably correct. `datatrack
selftest` cross-checks it against the kernel's 32-bit counters mod 2³², and will
tell you if the column mapping ever drifts on a future macOS.

## Accuracy and limits

- **Resolution is the poll interval** (10 s by default). Traffic in an interval
  that straddles a network change is credited to the *previous* network, since the
  switch happened at an unknown point inside it. Without that, joining a hotspot
  would immediately inherit the tail of the previous network's traffic.
- **Sleep is invisible.** No sampling happens while the Mac is asleep. Traffic
  either side is captured; the counter keeps running, so nothing is lost — it is
  just attributed to the network active when sampling resumes.
- **Interface totals include everything** on that link: VPN tunnels ride over
  `en0`, so they are counted once, correctly, and not double-counted.
- **Process attribution is sampled and is not a second ledger.** It runs once a
  minute, so a process that opens and closes a socket between samples is missed.
  It is a ranking of who is responsible, not an accounting of the total, and it
  will not sum to the network figure. Three reasons it cannot:
  - **Multicast is counted per recipient.** One mDNS frame arrives once on the
    wire but is delivered to every subscribed socket, so it is legitimately
    charged to several processes. `mDNSResponder` absorbs most Bonjour chatter and
    will often look large for this reason alone.
  - **Sampling gaps.** A socket's final partial interval is lost when it closes.
  - **The first sample only establishes baselines**, so attribution starts one
    interval after the network total does.

  The network total itself is unaffected by all of this — it comes from `netstat`,
  and budgets and alerts are computed from it, not from process attribution.
- **It tells you when it has stopped measuring.** A tool like this fails worst by
  freezing a number that looks current, so `datatrack status`, `datatrack doctor`
  and the menu bar all report how long ago the last reading was and warn once
  sampling has stalled. `doctor` distinguishes the three states that actually
  differ: agent installed, agent running, and agent *sampling*.
- **This measures, it does not enforce.** It will not block traffic. To actually
  stop macOS from downloading updates over a hotspot, turn on **Low Data Mode**
  for that network (System Settings → Wi-Fi → Details → Low Data Mode). When it
  is on, the kernel marks the link `constrained` and `datatrack doctor` reports it.

## Layout

```
Sources/DataTrackCore/
  InterfaceCounters.swift    64-bit byte counters + mod-2^32 self-test
  NetworkIdentity.swift      SSID / gateway-MAC / subnet identity resolution
  Store.swift                SQLite: networks, daily rollups, samples, budgets
  Sampler.swift              differencing, reset handling, straddle attribution
  ProcessAttribution.swift   nettop sampling and per-process deltas
  Formatting.swift           byte formatting, size parsing, budget cycle maths
  Notifier.swift             threshold notifications
Sources/datatrack/           CLI
Sources/DataTrackMenuBar/    SwiftUI MenuBarExtra app
Sources/datatrack-tests/     test runner (see below)
```

Run the tests with:

```bash
swift run datatrack-tests
```

40 tests / 100 assertions covering the parsers, the delta and reset arithmetic,
network identity under privacy gating, budget cycle boundaries, and the store.

Not `swift test`, deliberately. Neither test framework works with only the
Command Line Tools installed: the SDK ships no `XCTest.framework`, and while
`Testing.framework` is present it is built against a `swift-6.2` toolchain path
and its helper **exits 0 having run nothing**. A harness that silently reports
success while running zero tests is worse than no harness, so the runner is a
plain executable with no framework dependency — which also means it behaves
identically whether or not you later install Xcode.

## Relationship to the original HomeDataTrack

The archived Python in [`../legacy`](../legacy) polled a Telkom web portal for the
usage figure the *carrier* reports. This measures the same quantity from the
opposite end — what the Mac actually sent and received — which is what you need
to catch a runaway download while it is happening rather than the next day.
