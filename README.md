<div align="center">

# Adelaide Transit

**A native iOS transit app for Adelaide Metro that answers one question fast: _do I need to leave now?_**

Live map · real-time departures · walk timing · service alerts — no accounts, no analytics, no backend, no API keys.

![Platform](https://img.shields.io/badge/platform-iOS%2026-black?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.2-F05138?style=flat-square&logo=swift&logoColor=white)
![Concurrency](https://img.shields.io/badge/strict%20concurrency-enabled-4B8BBE?style=flat-square)
![Warnings](https://img.shields.io/badge/warnings-0-success?style=flat-square)
![Tests](https://img.shields.io/badge/tests-65%20passing-success?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)

</div>

<div align="center">

<img src="docs/screenshots/favourites.png" width="270" alt="Favourites — starred stops grouped and sorted nearest first, each showing the next three departures with live status dots"> <img src="docs/screenshots/map.png" width="270" alt="Live map — every vehicle on the network with route colours and bearings, feed age badge, favourite stops as gold pins"> <img src="docs/screenshots/alerts.png" width="270" alt="Alerts — service alerts filtered by mode, split by whether they affect your starred routes and stops">

<sub>**Favourites** · **Live map** · **Alerts** — real screens, real Adelaide Metro data</sub>

</div>

---

## What it is

A single-purpose SwiftUI app built on Adelaide Metro's public GTFS feeds. The entire timetable — 9,171 stops, 31,379 trips, every route shape — is ingested into local SQLite on first launch and then works **offline, forever, at zero bytes**. Real-time data is layered on top only when a screen actually needs it.

It is deliberately small: one target, no accounts, no server, no third-party analytics, nothing to sign up for. The interesting part isn't the feature list — it's that almost every decision in it was made against a measurement rather than a guess.

## Features

| | |
|---|---|
| 🗺️ **Live map** | Every bus, tram and train on the network, culled to your viewport and eased between GPS pings. Stops thin intelligently as you zoom — the *most important* stop per grid cell, never a cluster bubble that re-partitions on every pan. |
| ⏱️ **Departures that tell the truth** | Every row carries a countdown **and** a clock time — "do I move" and "which service is this" are different questions. Live, scheduled, stale, ghost and cancelled are five distinct states, never conflated. |
| 🚶 **Walk timing** | Routed walking time via MapKit for the stop you're looking at, with an honest warning when you won't make it — and silence when the walk was never plausible. |
| 🔁 **Block continuation** | Answers a question no other app asks: *does this bus carry on under a different route number?* 14,895 of 31,379 trips do. Matched by position, not stop ID, because an interchange is many stops. |
| ⭐ **Favourites first** | Opens on your starred stops, nearest first, re-sorted live as your location updates. Closure and detour alerts surface on the stop row itself. |
| 🔔 **Alerts that stop nagging** | The tab badge counts *unseen* alerts, not active ones — so a fortnight of roadworks doesn't pin a permanent red dot to your tab bar. |
| 👻 **Ghost trips** | Services the real-time feed isn't tracking still appear, interpolated along the route shape and drawn faintly, so an untracked bus isn't an invisible one. |
| 📴 **Offline by default** | Timetable browsing costs zero network. The feed is re-downloaded only when the server's `ETag` actually changes. |

## Requirements

- **macOS** with **Xcode 26** or later (iOS 26 SDK)
- **iOS 26** device or simulator
- [**XcodeGen**](https://github.com/yonaskolb/XcodeGen) — the `.xcodeproj` is generated, not committed

## Install

```bash
# 1. Clone
git clone https://github.com/RatterAU/adelaide-transit.git
cd adelaide-transit/AdelaideTransit

# 2. Install the project generator (once)
brew install xcodegen

# 3. Generate the Xcode project from project.yml
xcodegen generate

# 4. Open it
open AdelaideTransit.xcodeproj
```

Then in Xcode:

1. Select the **AdelaideTransit** target → **Signing & Capabilities**.
2. Set **Team** to your own Apple ID. A free account is fine.
3. Change the **Bundle Identifier** to something unique to you (e.g. `com.yourname.adelaidetransit`) — bundle IDs are global, and the default won't be available to you.
4. Pick your iPhone or a simulator and hit **Run**.

> **First launch downloads the full timetable (~30 MB) and ingests it into SQLite.** Give it a minute on Wi-Fi. After that, everything except live vehicle positions works with the network off.

> **Free Apple accounts** re-sign apps every 7 days — the app will stop launching until you rebuild. A paid Developer Program account raises that to a year. Nothing in this app requires paid capabilities.

### Building from the command line

```bash
xcodebuild -project AdelaideTransit.xcodeproj -scheme AdelaideTransit \
  -destination 'generic/platform=iOS Simulator' -quiet build

xcodebuild -project AdelaideTransit.xcodeproj -scheme AdelaideTransit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

> **Never hand-edit the `.xcodeproj`.** `project.yml` is the source of truth; run `xcodegen generate` after adding any file. If Xcode offers "recommended settings", decline — those belong in `project.yml`, or the prompt returns forever.

## Architecture

```
App/          App entry, tab router, theme + shared formatting rules
Data/
  GTFS/       Zip reader, ingest, SQLite schema + migrations, query surface
  Models/     Departure, LiveVehicle, StopSummary
  Realtime/   Poll scheduler, protobuf decoding, HTML stripping, Merge
Features/
  Map/        MKMapView bridge, stop sheet, trip detail, walking estimates
  Favourites/ Starred stops, live-sorted
  Alerts/     Service alerts, split by what you've starred
  Settings/   Windows, thresholds, clock format
Tests/        Swift Testing — merge logic, poll schedule, formatting, HTML
```

Four rules hold the thing together:

- **`Merge` is the only place schedule and real-time combine.** Delays, cancellations, tracking state, service-day arithmetic, ghost interpolation — all pure, all tested, never in a view.
- **`GTFSStore` (an actor) is the only database surface.** No SQL anywhere else.
- **Two database files, and the split is load-bearing.** `network.sqlite` is a disposable feed cache that ingest replaces wholesale. `user.sqlite` holds your favourites and nothing else touches it. They were one file once, and a routine timetable update deleted every starred stop.
- **A staged feed is validated before the swap**, and the old database is moved aside rather than deleted — a truncated download is still valid SQLite.

## Things the feed doesn't document

Most of this app's design comes from measuring the real feeds rather than trusting the spec:

- **The real-time feeds publish every 15 seconds** and the payload is fetchable about 5 seconds after the timestamp it carries. Polling faster returns byte-identical data — so *cadence is the only lever on freshness*, and the scheduler is phase-locked to the source clock rather than ticking on a fixed interval from launch.
- **No `ETag`, no `Last-Modified`, no `Cache-Control`** on real-time, and `Accept-Encoding: gzip` is ignored — every poll is full and uncompressed (trip updates 242 KB, alerts 61 KB, vehicles 45 KB). That's why trip updates only pre-warm on unconstrained Wi-Fi.
- **Nothing carries `current_stop_sequence`** (0 of 627 entities). So "where is the bus" is derived instead from the *pruning boundary*: a stop's update disappears once the bus passes it, making the smallest published stop sequence the vehicle's position. Verified stable for 790 of 792 trips over five minutes.
- **Trip updates carry absolute arrival times, never a delay field** (14,098 of 14,098). A stop with no update of its own is *interpolated* between the nearest known delays either side — which is what lets a recovering bus track from 6 minutes down to 3 instead of freezing at the stale figure.
- **Vehicle positions have no occupancy data**, so there's no crowding UI — rather than a fabricated one.
- **All 9,171 stop IDs are numeric**, which matters because the SQLite R-tree spatial index keys on `INTEGER`.

## Performance notes

Every number here was measured, not assumed:

- **~235 map annotations at peak, under 2.2 ms** to resolve, at 9,171 stops. Stops are thinned at query time by an absolute-anchored grid — clustering was rejected because it re-partitions on every region change, turning a pan into endless merge/split churn.
- **Nothing in the map's `updateUIView` runs unconditionally.** It fires on every render, frame and pan tick, so configuration, polylines and annotations are all change-gated.
- **Departure queries bound their scan in SQL.** The naive version read an entire service day for a stop served by 62 routes and threw most of it away.
- **Search is debounced and cancellable** (`.task(id:)`, 250 ms) — the substring scan is unindexed across all 9,171 stops, and un-ordered replies once left the wrong list on screen.

## Privacy

Your location never leaves the device — it is used for map centring, nearest-stop sorting and walking estimates only. There is no backend, no account, no telemetry and no third-party SDK. The only network traffic is to Adelaide Metro's public GTFS endpoints and Apple's own map and directions services.

## Data & licence

Timetable and real-time data © Department for Infrastructure and Transport, South Australia, published as open GTFS feeds. This project is not affiliated with, endorsed by, or supported by Adelaide Metro.

Code is released under the [MIT Licence](LICENSE).
