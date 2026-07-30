---
project: DataTrack for macOS
task: Per-Wi-Fi-network data usage tracking on macOS
effort: E4
phase: complete
progress: 72/73
mode: algorithm
started: 2026-07-29T19:40:00Z
updated: 2026-07-29T22:35:00Z
---

## Problem

macOS does not report data usage per Wi-Fi network. It exposes cumulative byte
counters per *interface* — `en0` carries one running total spanning every network
ever joined — with no breakdown by network, by day, or by responsible process.

The concrete failure this causes: when a Mac is tethered to a phone with a capped
data bundle, background system activity (`softwareupdated`, `nsurlsessiond`,
asset caches, cloud sync) can consume gigabytes with no visible signal and no
after-the-fact accounting. The bundle is depleted before the user knows anything
happened, and afterwards there is no way to establish what spent it.

Two further obstacles make naive approaches fail:

1. As of macOS 26 the Wi-Fi SSID is gated behind Location Services
   authorization. An unsigned CLI receives `nil` from `CWInterface.ssid()`,
   `"You are not associated with an AirPort network"` from `networksetup`, and
   `<redacted>` from `system_profiler` — while demonstrably associated. Network
   *identity* therefore cannot be based on the network name.
2. The 64-bit kernel byte counters are not reachable through Swift's imported
   `if_msghdr2` on this OS version; the imported layout resolves to a 32-bit
   field that wraps every 4 GiB.

The existing HomeDataTrack repository solves the adjacent-but-different problem
of scraping a carrier portal for the provider's own usage figure. That is
after-the-fact and carrier-side; it cannot catch a runaway download in progress.

## Vision

The user glances at the menu bar before starting work on a hotspot and knows,
without clicking, how much of the bundle is gone. When something starts eating
data, a notification names the network and the amount while there is still
bundle left to protect. Afterwards, `datatrack top` names the process that did
it. Nothing had to be configured for the measurement to be correct, and nothing
had to be granted for it to work at all.

The euphoric surprise: the tool identifies and tracks networks correctly even
though macOS refuses to disclose their names — and the workaround (gateway MAC
as identity) turns out to be *more* robust than the SSID would have been.

## Out of Scope

Traffic **enforcement** is not included. This tool measures and warns; it does
not block, throttle, or firewall. Blocking traffic on macOS requires a
`NEFilterDataProvider` system extension, a paid Developer ID with the Network
Extension entitlement, and user approval of a system extension — a materially
different product with a materially different install story. macOS already ships
the enforcement primitive (per-network Low Data Mode); this tool detects and
reports whether it is on rather than reimplementing it.

Also excluded: per-domain or per-connection breakdown, historical backfill of
usage that occurred before installation, iOS/iPadOS companion apps, cloud sync of
usage history, and multi-user or system-wide (all-accounts) accounting.

## Principles

- **Measure from the machine, not the carrier.** Provider portals report late and
  in their own units. The kernel's own counters are immediate and authoritative
  for what this Mac actually sent.
- **Degrade, never fail.** Every privacy gate must have a permission-free
  fallback. Denying location costs a network's *name*, never its accounting.
- **Identity must be stable across permission states.** A network's history must
  not fork when the user grants or revokes an authorization.
- **Never invent bytes.** An arithmetic error that fabricates usage is worse than
  missing data, because it destroys trust in every number the tool reports.
- **Verify the measurement apparatus itself.** A silently-wrong counter makes the
  entire product worthless; the tool must be able to check its own source.

## Constraints

- macOS 14+ target; developed and verified on macOS 26.5 (build 25F84).
- **Xcode Command Line Tools only** — no full Xcode, therefore no `xcodebuild`,
  no `.xcodeproj`, and the `.app` bundle must be assembled by hand from SwiftPM
  output.
- **No sudo, no system extension, no kernel extension.** Install must stay
  entirely within `$HOME`.
- **No third-party dependencies** — the build must work offline and the installed
  binary must have nothing to resolve.
- Swift, not TypeScript: native macOS system APIs (CoreWLAN, SystemConfiguration,
  `getifaddrs`, launchd) are the substrate, and a native app was explicitly
  requested. Recorded as a deliberate deviation from the global bun/TypeScript
  default.
- Must not double-count when the launchd agent and the menu bar app run
  simultaneously.

## Goal

Ship a native macOS tool that attributes byte-accurate data usage to the specific
Wi-Fi network that carried it, persists it per day indefinitely, names the
processes responsible, and warns before a per-network budget is exhausted —
functioning correctly whether or not macOS discloses the network's name, and
installable without sudo or Xcode.

## Criteria

### Byte counter correctness

- [ ] ISC-1: `InterfaceCounters.read()` returns values exceeding 2^32 for `en0` on a machine whose lifetime traffic exceeds 4 GiB.
- [ ] ISC-2: Parser derives `Ibytes`/`Obytes` positions from the `netstat` header rather than hardcoding indices.
- [ ] ISC-3: Parser correctly reads rows whose `Address` column is empty (`lo0`).
- [ ] ISC-4: Parser attributes each interface exactly once despite repeated per-protocol rows.
- [ ] ISC-5: Parser tolerates an added trailing column without corrupting byte values.
- [ ] ISC-6: Parser throws rather than returning wrong numbers when the header lacks byte columns.
- [ ] ISC-7: `selfTest()` confirms netstat agrees with kernel 32-bit counters mod 2^32.
- [ ] ISC-8: `datatrack selftest` exits non-zero when the cross-check fails.
- [ ] ISC-9: Anti: no code path uses `if_msghdr2.ifm_data` as an accounting source.
- [ ] ISC-10: `lowWordCounters()` is referenced only by the self-test, never by accounting.

### Delta and reset arithmetic

- [ ] ISC-11: `resolveDelta` returns `.baseline` when no previous reading exists.
- [ ] ISC-12: `resolveDelta` returns the difference for a normal advance.
- [ ] ISC-13: `resolveDelta` returns `.reset` when either counter decreased.
- [ ] ISC-14: `resolveDelta` returns `.reset` when only one axis decreased.
- [ ] ISC-15: `resolveDelta` returns a zero delta (not a reset) for an idle interval.
- [ ] ISC-16: `resolveDelta` preserves deltas exceeding 2^32.
- [ ] ISC-17: Anti: no unsigned subtraction can underflow into a fabricated multi-exabyte delta.
- [ ] ISC-18: A counter reset discards the straddling interval rather than recording it.

### Network identity under privacy gating

- [ ] ISC-19: Fingerprint is identical whether or not the SSID is available.
- [ ] ISC-20: Fingerprint prefers gateway MAC over SSID.
- [ ] ISC-21: Fingerprint falls back to subnet when no gateway MAC exists.
- [ ] ISC-22: ARP parser extracts the gateway MAC from real `arp -n` output.
- [ ] ISC-23: ARP parser zero-pads short octets so one router yields one fingerprint.
- [ ] ISC-24: ARP parser rejects `(incomplete)` entries.
- [ ] ISC-25: ARP parser returns nil for "no entry" output.
- [ ] ISC-26: Primary interface and gateway are read via SystemConfiguration without elevated privilege.
- [ ] ISC-27: Subnet CIDR is computed from the interface address and netmask.
- [ ] ISC-28: A missing ARP entry triggers one gateway ping and a retry.
- [ ] ISC-29: `datatrack doctor` reports SSID availability explicitly rather than failing silently.
- [ ] ISC-30: Anti: SSID unavailability never prevents usage from being recorded.

### Metered detection

- [ ] ISC-31: iOS hotspot gateway `172.20.10.1` is classified as metered.
- [ ] ISC-32: Android hotspot gateways are classified as metered.
- [ ] ISC-33: The kernel `constrained` interface flag alone marks a network metered.
- [ ] ISC-34: An SSID containing a phone-vendor hint marks a network metered.
- [ ] ISC-35: An ordinary SSID is not marked metered.
- [ ] ISC-36: `datatrack doctor` reports the `constrained` flag state.

### Persistence

- [ ] ISC-37: Upserting the same network twice yields exactly one row.
- [ ] ISC-38: An SSID discovered later backfills onto the existing record.
- [ ] ISC-39: A known SSID is not erased by a later reading lacking one.
- [ ] ISC-40: Deltas accumulate into the daily rollup.
- [ ] ISC-41: Usage remains separated per network.
- [ ] ISC-42: Counter baselines round-trip values above 2^32 through signed SQLite integers.
- [ ] ISC-43: A user label takes display precedence over the SSID.
- [ ] ISC-44: Process usage aggregates and ranks by total bytes.
- [ ] ISC-45: WAL mode is enabled so the app can read while the agent writes.
- [ ] ISC-46: Schema is created idempotently on every open.
- [ ] ISC-47: Anti: two samplers sharing one baseline row do not double-count.

### Process attribution

- [ ] ISC-48: `nettop` CSV parses including the leading empty header field.
- [ ] ISC-49: PID suffix is stripped while names legitimately ending in digits survive.
- [ ] ISC-50: A first-sighted process contributes zero, not its pre-existing total.
- [ ] ISC-51: A backwards process counter is treated as a restart, not negative traffic.
- [ ] ISC-52: Multiple PIDs of one program aggregate under one name.
- [ ] ISC-53: Stale process baselines are pruned.

### Budgets and alerting

- [ ] ISC-54: A monthly cycle opens on its configured reset day.
- [ ] ISC-55: Before the reset day the cycle belongs to the previous month.
- [ ] ISC-56: A reset day of 31 clamps into a short month rather than overflowing.
- [ ] ISC-57: The cycle key rotates between cycles so alerts re-arm.
- [ ] ISC-58: A rolling-30 window spans 30 inclusive days.
- [ ] ISC-59: A threshold alert can be claimed exactly once per cycle.
- [ ] ISC-60: Anti: an SSID containing a quote cannot escape the AppleScript literal.

### Build, install, and interface

- [ ] ISC-61: `swift build` succeeds with zero errors using Command Line Tools only.
- [ ] ISC-62: `swift test` passes with zero failures.
- [ ] ISC-63: `datatrack doctor` runs and reports every diagnostic field.
- [ ] ISC-64: `datatrack status` renders the current network, today's usage, and budget.
- [ ] ISC-65: `datatrack once` records a real delta against a real network.
- [ ] ISC-66: `datatrack networks` lists recorded networks with totals.
- [ ] ISC-67: `datatrack budget set` accepts `5GB` and reports the resulting cycle.
- [ ] ISC-68: `datatrack name` labels a network whose SSID is hidden.
- [ ] ISC-69: `build-app.sh` produces a signed `DataTrack.app` bundle.
- [ ] ISC-70: The app bundle declares `LSUIElement` and a location usage description.
- [ ] ISC-71: `install-agent.sh` registers a launchd agent that survives a restart.
- [ ] ISC-72: Package has zero external dependencies.
- [ ] ISC-73: Anti: nothing in the install path requires sudo.

## Test Strategy

| isc | type | check | threshold | tool |
| --- | --- | --- | --- | --- |
| ISC-1..6 | unit | parse real netstat fixture incl. variable field counts | exact byte equality | `swift test` |
| ISC-7,8 | integration | live mod-2^32 cross-check on this machine | PASS | `datatrack selftest` |
| ISC-9,10 | static | source contains no accounting use of `if_msghdr2` | zero matches | `grep` |
| ISC-11..18 | unit | pure `resolveDelta` truth table incl. underflow case | all cases | `swift test` |
| ISC-19..30 | unit + live | fingerprint stability, ARP fixtures, doctor output | exact | `swift test`, `datatrack doctor` |
| ISC-31..36 | unit | metered classification matrix | all cases | `swift test` |
| ISC-37..47 | unit | temp-file SQLite store round trips | exact | `swift test` |
| ISC-48..53 | unit | nettop fixture and delta edge cases | exact | `swift test` |
| ISC-54..60 | unit | cycle boundary dates incl. 31-Feb clamp; escaping | exact | `swift test` |
| ISC-61,62,72 | build | compile and test with no network access | zero errors | `swift build`, `swift test` |
| ISC-63..68 | live CLI | run each subcommand, inspect stdout | non-empty, correct shape | `Bash` |
| ISC-69,70 | build | bundle exists, `codesign --verify`, plist keys present | verify passes | `Bash`, `plutil` |
| ISC-71,73 | install | agent loads under `launchctl print`, no sudo invoked | running | `Bash` |

## Features

| name | satisfies | depends_on | parallelizable |
| --- | --- | --- | --- |
| InterfaceCounters | ISC-1..10 | — | yes |
| Sampler delta logic | ISC-11..18 | InterfaceCounters | no |
| NetworkIdentity | ISC-19..36 | — | yes |
| Store | ISC-37..47 | — | yes |
| ProcessAttribution | ISC-48..53 | Store | yes |
| Budgets + Notifier | ISC-54..60 | Store | no |
| CLI | ISC-63..68 | all core | no |
| Menu bar app | ISC-69,70 | all core | no |
| launchd agent | ISC-71,73 | CLI | no |

## Decisions

- **2026-07-29T19:45Z — Identity keyed on gateway MAC, not SSID.** macOS 26.5
  redacts the SSID from unprivileged callers (verified three independent ways).
  Keying on the ARP-resolved gateway MAC needs no permission, is stable across
  SSID renames, and — decisively — does not fork a network's history when
  Location Services is later granted. SSID is demoted to a display attribute
  that backfills when it becomes available.

- **2026-07-29T20:05Z — `netstat -ibn` is the counter source, not
  `sysctl(NET_RT_IFLIST2)`.** See Changelog entry 1. The native struct path is
  wrong on this OS; the shell-out is verifiably correct. Cost is one process
  spawn per poll (~15 ms at a 10 s interval), which is immaterial. The native
  32-bit path is retained solely as a self-test.

- **2026-07-29T20:10Z — Straddled intervals credit the *previous* network.** The
  counter baseline stores which network it was taken on. On a network change the
  interval's bytes accrued mostly before the switch, so crediting the newly
  joined network would make joining a metered hotspot instantly inherit the tail
  of the previous network's traffic — the exact false alarm that would destroy
  trust in the tool.

- **2026-07-29T20:15Z — Enforcement deliberately out of scope.** Blocking traffic
  needs a `NEFilterDataProvider` system extension plus a paid Network Extension
  entitlement, changing the product and the install story. macOS already ships
  Low Data Mode; the tool detects and reports it instead.

- **2026-07-29T20:20Z — Swift rather than TypeScript.** Deviation from the global
  bun/TypeScript default, justified by the explicit request for a native or
  system-level app and by the fact that the required APIs (CoreWLAN,
  SystemConfiguration, `getifaddrs`, launchd, SwiftUI `MenuBarExtra`) are native.

- **2026-07-29T20:25Z — Delegation floor not met (soft floor, E4 ≥2; actual 0).**
  Show-your-math: the session configuration for this run explicitly prohibits
  invoking the Agent tool unless requested, which forecloses Forge, Anvil, and
  the mandatory-at-E4 Cato cross-vendor audit. Had Cato run, its brief would have
  been to attack the counter-source decision and the straddle-attribution choice
  for Anthropic-family blind spots. Compensating control: the two highest-risk
  behaviours were instead root-caused empirically against the live kernel
  (measured mod-2^32 identity) and pinned by unit tests over pure functions,
  which is stronger evidence than a model review would have produced.

- **2026-07-29T20:30Z — ISC count 73 against an E4 floor of 128.** Show-your-math:
  the granularity rule was applied until every criterion had a single nameable
  probe, and it produced 73. Padding to 128 would require splitting criteria
  below the level at which a distinct probe exists, which would make the ISA
  falsely appear more verified than it is. Recorded as a deliberate deviation
  rather than satisfied with filler.

- **2026-07-29T20:32Z — Built in `macos/` inside the existing repository.** The
  request was for "a new related app" in the context of this repo. A subdirectory
  is the reversible choice and keeps the legacy Python untouched; the SwiftPM
  package is self-contained and can be extracted to its own repository with a
  directory move if wanted.

## Changelog

**1. The native 64-bit counter path**

- **conjectured:** `sysctl(NET_RT_IFLIST2)` walked as `if_msghdr2` yields 64-bit
  interface byte counters, making a fully native, dependency-free counter source
  available with no subprocess.
- **refuted_by:** Direct measurement on macOS 26.5. `MemoryLayout<if_msghdr2>.size`
  reports 160 while the kernel emits `ifm_msglen == 180`. Reading `ifm_data` at
  the imported offset returned `945_435_648` for `en0` against a `netstat` truth
  of `69_664_912_535` — exactly the truth mod 2^32 (945_435_799, a 151-byte
  sampling drift). Cross-checked on `lo0` (5_571_821_451 → 1_276_854_155 expected,
  1_278_863_360 observed) and `awdl0` (628_317 → 627_712, below the wrap so
  near-identical), confirming the pattern rather than a one-off. A byte-wise scan
  of all 180 bytes of the en0 message found the true 64-bit value at no offset.
- **learned:** Swift's imported Darwin struct layouts are not guaranteed to track
  the running kernel's, and a layout mismatch fails *silently* by landing on an
  adjacent field of plausible magnitude. For a measurement tool this is the worst
  possible failure mode: the number looks reasonable and is wrong by a factor of
  the wrap count. An Apple-shipped userland tool with a documented output format
  is the more trustworthy source, and the apparatus must be able to verify itself.
- **criterion_now:** ISC-7 (mod-2^32 self-test), ISC-9 (anti-criterion forbidding
  `if_msghdr2` as an accounting source), ISC-1 (counters must exceed 2^32).

**2. SSID as network identity**

- **conjectured:** The SSID is the natural primary key for a Wi-Fi network, so
  per-network accounting requires reading it, and reading it requires Location
  Services authorization.
- **refuted_by:** `CWInterface.ssid()` returned `nil`, `networksetup
  -getairportnetwork en0` reported "You are not associated with an AirPort
  network" while `ifconfig en0` showed `status: active` with a bound address, and
  `system_profiler SPAirPortDataType` printed `<redacted>` — all on an associated
  interface. Meanwhile `arp -n` resolved the gateway MAC with no authorization at
  all.
- **learned:** Treating the privacy gate as a blocker was the wrong frame. The
  question is not "how do I read the SSID" but "what stably identifies this
  network", and the answer is better than the SSID: a gateway MAC survives SSID
  renames, distinguishes same-named networks, and does not change when
  permissions do. Keying on the SSID would have introduced a latent data-integrity
  bug where granting location later forks one network's history in two.
- **criterion_now:** ISC-19 (fingerprint identical with and without SSID), ISC-20
  (gateway MAC preferred), ISC-30 (anti: SSID unavailability never blocks
  recording), ISC-38 (SSID backfills onto the existing record).

**3. Substring matching for hotspot SSIDs**

- **conjectured:** An SSID containing a phone vendor's name indicates tethering,
  so `ssid.contains("pixel")` and friends are a sound metered-network heuristic.
- **refuted_by:** Running the app on the principal's actual network, whose SSID is
  `Pixelated`. The substring check flagged an ordinary network as a phone hotspot.
  The failure only appeared because the app bundle could read an SSID the CLI
  could not — the unit tests used invented names like `Pixel_Hotspot` and all
  passed.
- **learned:** Substring matching on short device names has a false-positive rate
  that real-world names actually hit, and the two error directions are not
  symmetric: marking an unmetered network metered generates budget warnings the
  user never asked for, which trains them to ignore the warnings that matter.
  Whole-token matching for device names, substring only for self-describing
  phrases like "hotspot". More broadly: fixture data drawn from imagination misses
  the cases the real world supplies for free.
- **criterion_now:** ISC-35 tightened, plus a new case pinning `Pixelated`,
  `Androidian Cafe`, and `Galaxybrain` as *not* metered while `Pixel 8` and
  `android-ap` still are.

**4. `swift test` as the verification harness**

- **conjectured:** `swift test` with swift-testing is available in the toolchain,
  so the ISA's unit-test criteria can be verified by running it.
- **refuted_by:** The SDK ships no `XCTest.framework`, and `Testing.framework`,
  though present, is built against a `swift-6.2` path under a 6.3.3 toolchain.
  After fixing the framework search path and two rpaths, `swift test` built
  successfully and **exited 0 having executed zero tests** — no output, no
  failures, nothing.
- **learned:** A green exit code is not evidence that tests ran; it is evidence
  that nothing reported a failure, which a harness executing zero tests satisfies
  trivially. This is the same class of silent-success failure as the truncated
  counter: plausible-looking output concealing no measurement at all. The
  assertion count is now printed on every run so "did it actually run" is visible
  rather than inferred.
- **criterion_now:** ISC-62 rewritten against `swift run datatrack-tests`, which
  reports both test names and a total assertion count.

**5. One rule, implemented twice**

- **conjectured:** The reset rule for interface counters and the reset rule for
  per-process counters are similar enough to write separately. The interface path
  discarded the interval on a decrease; the process path used
  `sample.bytesIn >= prev.bytesIn ? sample.bytesIn - prev.bytesIn : sample.bytesIn`,
  adding the whole cumulative counter on a decrease.
- **refuted_by:** The principal noticed `mDNSResponder` reported at 146 MB inside a
  62 MB daily total. Querying the live database: recorded outbound for
  `mDNSResponder` was 119 880 319 against a lifetime counter of 29 864 915 —
  a ratio of 4.01, i.e. the full cumulative total re-injected on four separate
  sampling dips. Inbound was 1.006x, counted correctly. A second, independent
  defect compounded it: `nettop -t wifi` does not scope byte totals to the
  accounting interface (measured identical to unfiltered, 85.8 MB), and the
  per-flow breakdown showed 40 856 648 bytes of it on `awdl0` — AirDrop and
  Continuity on a virtual interface the `en0` counters never include.
- **learned:** Duplicating a rule duplicates the *opportunity* to get it wrong,
  and the copy that is harder to verify is the one that will be wrong. Worse, the
  two failure modes were opposites — the interface path erred toward losing data,
  the process path toward inventing it — so no single review of either file in
  isolation would have flagged the inconsistency. The fix is not "correct the
  second copy" but "have one copy": `MonotonicCounter` is now the only place a
  byte counter becomes a delta, and a test asserts both call sites agree on
  identical input. Separately, per-*process* totals are not monotonic counters at
  all — they fall whenever a socket closes — so attribution is now keyed per
  *flow*, which genuinely is monotonic for its lifetime.
- **criterion_now:** ISC-51 rewritten as an explicit regression (a 5-byte dip must
  yield nothing, not 29.9 MB), plus ISC-74..80 below covering the shared rule, the
  interface filter, the first-sample baseline pass, and space-containing process
  names.

### Added criteria (post-merge fix)

- [x] ISC-74: A decrease of any magnitude yields no delta, never the cumulative total.
- [x] ISC-75: `Sampler.resolveDelta` and `MonotonicCounter.resolve` agree on identical input.
- [x] ISC-76: Only flows on the accounting interface are attributed; `awdl0` is excluded.
- [x] ISC-77: The first process sample establishes baselines and records nothing.
- [x] ISC-78: A newly-opened socket counts its full total.
- [x] ISC-79: Process names containing spaces are not parsed as connection rows.
- [x] ISC-80: `resetProcessHistory()` clears attribution while leaving `usage_daily` intact.

**6. A long-running agent leaking one resource per tick**

- **conjectured:** `Shell.run` could rely on `Pipe` releasing its file descriptors
  when it went out of scope, so no explicit close was needed.
- **refuted_by:** The freshness reporting added in the same session immediately
  showed `agent process running` alongside `sampling STALLED — last reading 14m
  ago`. The log held 14 minutes of identical `could not locate Ibytes/Obytes
  columns in netstat header: <empty output>`, and `lsof` showed **2 553 open PIPE
  descriptors** against a launchd `maxfiles` soft limit of 256. The agent had
  exhausted its descriptors after roughly 90 minutes, could no longer spawn
  `netstat`, and failed every tick while remaining alive and apparently healthy.
  After the fix, descriptor count stayed flat at 14 total / 0 pipes across three
  minutes of normal sampling.
- **learned:** Two lessons, and the second is the larger one. First, a resource
  that leaks once per iteration is not a small bug in a process designed to run
  for weeks — it is a guaranteed failure with a fuse on it, and this one would
  have silently killed the tool a couple of hours after every install. Second,
  the defect was found only because observability was added for unrelated
  reasons: nothing in the ISA's criteria could have caught it, because every
  criterion was verified against a freshly-started process. Correctness over time
  is a distinct property from correctness, and it needs its own probe. The
  `Notifier` escalation on consecutive failures now makes the tool complain
  instead of dying quietly.
- **criterion_now:** ISC-81..87 below, including a regression that asserts the
  descriptor count does not grow across 150 invocations, and probes for the
  pipe-buffer deadlock and hung-child paths that the same rewrite touches.

### Added criteria (reliability pass)

- [x] ISC-81: `Shell.run` does not grow the open descriptor count across repeated calls.
- [x] ISC-82: Output exceeding a pipe buffer does not deadlock.
- [x] ISC-83: A child exceeding its timeout is killed and flagged, not awaited forever.
- [x] ISC-84: Exit status is propagated.
- [x] ISC-85: `status`/`doctor`/menu bar report last-sample age and warn when stalled.
- [x] ISC-86: `doctor` distinguishes agent installed, running, and sampling.
- [x] ISC-87: A transient ARP miss resolves to the existing network, not a new record.
- [x] ISC-88: A stale subnet match is not reused for a genuinely different network.

## Verification

Verified on macOS 26.5.2 (build 25F84), Swift 6.3.3, Command Line Tools only.

- ISC-1..6, 11..25, 31..35, 37..60: `swift run datatrack-tests` — 40 tests, 100
  assertions, zero failures. Includes the netstat fixture with a variable field
  count, the `.reset` underflow guard, gateway-MAC fingerprint stability with and
  without SSID, the 31-February cycle clamp, and AppleScript escaping.
- ISC-7, 8: `datatrack selftest` — `netstat mod 2^32 in=1205381937` against
  `getifaddrs in=1205407744`, a 25 807-byte sampling gap. `PASS`, exit 0. This
  simultaneously confirms the truncation diagnosis and the netstat mapping.
- ISC-9, 10: `grep -rn if_msghdr2 Sources/` returns two hits, both doc comments
  explaining why it is not used. Zero code references.
- ISC-26..29, 36, 63: `datatrack doctor` — resolved `en0`, gateway
  `10.139.153.111`, gateway MAC `da:f7:ed:85:e7:d5`, subnet `10.139.153.0/24`,
  `Constrained flag SET`, `SSID UNAVAILABLE` reported explicitly, `Process
  attribution OK — 29 processes visible`.
- ISC-30, 40, 65: three successive `datatrack once` calls —
  `baselineEstablished`, then `recorded ↓136 KB ↑101 KB`, then
  `recorded ↓731 KB ↑97.09 KB`. Recorded with SSID unavailable throughout.
- ISC-38: the menu bar app read `ssid = "Pixelated"` where the CLI got `nil`, and
  backfilled it onto the **existing** row (`id 1`, fingerprint still
  `gw:da:f7:ed:85:e7:d5`). The identity-stability decision is confirmed live.
- ISC-43, 64, 66, 67, 68: `datatrack name/budget set/status/networks/history/top`
  all render correctly; per-process attribution surfaced `OneDrive Sync S 671 KB`,
  `Vivaldi Helper 47.41 KB`.
- ISC-59: with a deliberately-exceeded 1 MB budget, `alerts_fired` contains
  exactly one row per threshold (50/80/95/100, cycle key `monthly:2026-07-15`) and
  a second tick added none.
- ISC-61, 72: `swift build` completes with zero errors and zero warnings;
  `Package.swift` declares no `.package(` dependencies and no `Package.resolved`
  is produced.
- ISC-69, 70: `build-app.sh` produced `DataTrack.app`; `codesign --verify`
  reports "satisfies its Designated Requirement"; `plutil -lint` OK;
  `LSUIElement = true`. Launched live and `lsappinfo` reported
  `type="UIElement"` — menu bar only, no Dock icon.
- ISC-71: `[DEFERRED-VERIFY]` — the generated launchd plist passes `plutil -lint`,
  but the agent was not bootstrapped. Loading a permanent background job onto the
  principal's machine is a persistent change that belongs to them, not to this
  run. Follow-up: run `Scripts/install-agent.sh` and confirm
  `launchctl print gui/$(id -u)/com.chriscurrin.datatrack`.
- ISC-73: no command in the install path invokes `sudo`; everything targets
  `$HOME/.local/bin`, `$HOME/Library/LaunchAgents`, `$HOME/Library/Logs`.

**Not verified:** behaviour across a real network switch (requires physically
joining a second network), across a reboot counter reset, and across a sleep/wake
cycle. The arithmetic for all three is unit-tested, but the live transitions are
untested.

Test database created during verification was removed afterwards; the tool starts
with no history.
