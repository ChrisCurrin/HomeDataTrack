# Archived — the original HomeDataTrack (2016)

Kept for reference. **Not maintained, and it no longer runs.**

## What it did

`DataTrack.py` polled a Telkom self-service portal and recorded the usage figures
the *carrier* reported. Because the page rendered its numbers in JavaScript, it
drove a real browser engine — a PyQt4 `QWebPage` — waited for `loadFinished`,
then scraped the resulting HTML for three values:

- Included Telkom Mobile Night Surfer Data
- Inclusive SmartBroadband Data
- Wi-Fi Data Unlimited Speed

Each reading was pushed to a Firebase Realtime Database keyed
`/{YYYY-MM}/{DD}` → `{HH:MM}`, giving a usage-over-time series. It polled every
30 minutes, backing off to every two hours between midnight and 08:00.

Connection details (portal URL, Firebase URL, database secret) lived in an
untracked `config.py`.

`HomeDataTrack.iml` is the IntelliJ/PyCharm module descriptor from the same era.

## Why it stopped working

- **PyQt4 and QtWebKit are gone.** Qt 4 left support in 2015 and PyQt4 does not
  build against current Python or macOS. `QtWebKit` was removed from Qt
  entirely, so the rendering approach has no replacement in this codebase.
- **Firebase database secrets are deprecated.** The `FirebaseAuthentication`
  secret-plus-email pattern predates the Admin SDK and service-account
  credentials, and legacy secrets were retired.
- **The scraper was pinned to exact label strings.** `handle_data` matched
  literal text like `'Included Telkom Mobile Night Surfer Data'` and then took
  the third subsequent data node. Any portal redesign breaks it silently.

## What replaced it, and what didn't

[`../macos`](../macos) measures the same quantity from the opposite end: what the
Mac itself actually sent and received, attributed per Wi-Fi network. That is the
number you need to catch a runaway download *while it is happening*.

It is not a drop-in replacement. The two measure genuinely different things:

|  | This (archived) | `macos/` |
| --- | --- | --- |
| Source | Carrier portal | The Mac's own kernel counters |
| Authority | Billing-accurate | Machine-accurate |
| Latency | Whenever the portal updates | Seconds |
| Scope | Whole account, all devices | This Mac, per network |
| Attribution | None | Per network, per day, per process |

Nothing currently reads the carrier's own figure. If account-wide usage across
all devices matters again, that is a separate job from what `macos/` does — and
the modern approach would be a carrier API or an authenticated HTTP session, not
a headless browser scraping rendered HTML.
