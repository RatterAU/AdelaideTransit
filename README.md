<div align="center">

<img src="docs/hero.svg" alt="Adelaide Transit — do I need to leave now? Live tracking for Adelaide Metro, built in SwiftUI" width="100%">

<br><br>

**An iPhone app that tracks Adelaide Metro buses, trams and trains in real time.**

It exists to answer one question: **do I need to leave now?**

<br>

![iOS 26](https://img.shields.io/badge/iOS-26-0B1B33?style=flat-square&logo=apple&logoColor=white)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?style=flat-square&logo=swift&logoColor=white)
![MIT](https://img.shields.io/badge/licence-MIT-555?style=flat-square)
![Liquid Glass](https://img.shields.io/badge/Liquid_Glass-native-1B3A6B?style=flat-square)
![No tracking](https://img.shields.io/badge/analytics-none-1F7A4D?style=flat-square)

[**Install it**](#install-it) · [**What it does**](#what-it-does) · [**Under the hood**](#under-the-hood) · [**Privacy**](#privacy)

</div>

---

## Why

Adelaide Metro's own app tells you when a bus is *scheduled*. Standing at a stop in the rain, that is the wrong number. I wanted the one that matters: where the bus actually is right now, how late it actually is, and whether I can still make it on foot.

So I built it. It's a personal project — one person, no company behind it, no accounts, no ads, no backend to pay for. Everything happens on your phone, talking straight to Adelaide Metro's public data feeds.

<br>

<div align="center">

<img src="docs/demo.gif" width="290" alt="Screen recording: tapping a stop on the map opens its live departures, tapping a departure draws the route and follows the bus as it moves along it in real time">

<sub>Tap a stop → live departures → tap one → follow the actual bus.</sub>

</div>

<br>

<div align="center">

<img src="docs/screenshots/departures.png" width="270" alt="Stop departures: route M44 to Marion, LIVE, at this stop, 2 min, 4:21 pm — with a red 2 min late tag and a warning that the 22 minute walk won't make it">
&nbsp;
<img src="docs/screenshots/trip.png" width="270" alt="Trip detail: the M44 drawn along its route with the live vehicle 1551 at 89 km/h, updated 18 seconds ago, and YOUR STOP marked one minute away">
&nbsp;
<img src="docs/screenshots/map-live.png" width="270" alt="Live map of central Adelaide showing dozens of vehicles as coloured route badges with heading arrows, and a 19s old feed age chip">

<sub><b>Departures</b> · <b>Follow the bus</b> · <b>Everything moving, right now</b></sub>

<br>

<sub>Real screenshots. Real Adelaide data. Nothing mocked up.</sub>

</div>

## What it does

**See where the bus actually is.** Every tracked vehicle on the network appears on the map as its route number with a heading arrow, sliding between GPS updates. Tap one and you follow it: its speed, how many seconds ago it reported, and every stop still ahead of it.

**Know which bus it is.** *(Built-from-source only — see [below](#option-b-build-it-with-xcode).)* Tap the vehicle number on a trip and it opens up: rego, chassis and body, when it was built and how old it is, seats, depot, operator and its history. There's a photo too — of that exact bus when one exists on Wikimedia Commons, otherwise one of the same model, and the caption tells you which. Where a bus reports how full it is, you'll see that as well: on the trip, and as a small icon on its departure row.

**Know if you'll make it.** Each departure shows a countdown *and* a clock time, because "5 min" and "4:21 pm" answer different questions. If you're too far away to catch it on foot, the app says so plainly instead of letting you jog for nothing.

**Know when it's late.** Delays come from the live feed and are colour-coded: on time, running early, running late. If a bus is recovering from a delay, the number counts down with it rather than freezing on a stale figure. A bus just past its predicted time but still on its way reads **Due**; one that has passed your stop reads **Departed**, even if it ran early. When live times stop arriving, the screen says how old they are instead of quietly showing them as live.

**Only buses you can catch.** A stop's list leaves out services that *end* there or only let people off there — at a terminus like Adelaide Railway Station that used to be half the board.

**Your stops first.** The app opens on the stops you've starred, sorted by how close you are, re-sorting as you move. Each shows the next three departures, so most of the time you're done before you've tapped anything.

**Alerts that don't nag.** Diversions and closures are listed and filtered by mode, and the tab badge counts alerts you *haven't seen* — so a fortnight of roadworks doesn't leave a permanent red dot on your screen.

**It looks like it belongs on iOS 26.** Built in SwiftUI against the current design language, so the search field, the feed-age chip and the locate button are real Liquid Glass — they pick up and refract the map moving underneath them instead of sitting on a flat grey slab. Nothing here is a custom re-skin of Apple's controls.

**Buses that aren't being tracked still show up.** When the feed loses a vehicle, the app estimates where it should be from the timetable and draws it faintly, rather than pretending the service doesn't exist.

<br>

<div align="center">

<table>
<tr>
<td align="center" width="20%"><img src="docs/screenshots/favourites-live.png" width="190" alt="Favourites list: starred stops with distances and the next three routes on each, each with a live status dot"></td>
<td align="center" width="20%"><img src="docs/screenshots/stop-sheet-map.png" width="190" alt="Map with a stop sheet open showing walking distance, a walking directions button and live departures"></td>
<td align="center" width="20%"><img src="docs/screenshots/stops-thinned.png" width="190" alt="Map zoomed over the city showing evenly spread stop pins with starred stops in gold"></td>
<td align="center" width="20%"><img src="docs/screenshots/alerts.png" width="190" alt="Alerts screen listing service alerts filtered by mode, each showing how long it has been in effect"></td>
<td align="center" width="20%"><img src="docs/screenshots/settings.png" width="190" alt="Settings: toggles for showing all live buses, auto-centring, keeping the screen awake, hiding modes, map style and marker size"></td>
</tr>
<tr>
<td align="center"><sub><b>Favourites</b><br>Nearest first</sub></td>
<td align="center"><sub><b>Any stop</b><br>Walk time included</sub></td>
<td align="center"><sub><b>9,171 stops</b><br>Thinned, never clustered</sub></td>
<td align="center"><sub><b>Alerts</b><br>Badged by unseen</sub></td>
<td align="center"><sub><b>Yours</b><br>Tune what shows</sub></td>
</tr>
</table>

</div>

## Install it

There's no App Store listing. Publishing needs a paid Apple developer account and this is a free side project. There are two ways to put it on an iPhone (iOS 26 or newer), both free:

- **[LiveContainer + SideStore](#option-a-livecontainer--sidestore)**: any computer, used once. After that you install and update from the phone, and the app doesn't take one of the 3 app slots a free Apple ID gets (LiveContainer takes one, once).
- **[Xcode](#option-b-build-it-with-xcode)**: needs a Mac. You build it yourself in about ten minutes, and re-run it from Xcode every 7 days.

### Option A: LiveContainer + SideStore

You need a computer (Mac, Windows or Linux) and a USB cable once, to put LiveContainer on the phone. After that, everything happens on the phone. Already have LiveContainer working? Skip to [Install AdelaideTransit](#install-adelaidetransit).

> [!WARNING]
> **Never delete LiveContainer to "fix" it.** Every app inside it, and all their data, is deleted with it. If it stops opening, reinstall it over the top (see [Keep it working](#keep-it-working)).

#### Part 1: Put LiveContainer+SideStore on the phone

1. On the computer, download the latest **[iloader](https://github.com/nab138/iloader/releases/latest)**. Older versions can't sign LiveContainer properly.
2. Plug the iPhone in, unlock it, and tap **Trust** if asked.
3. Open iloader, sign in with your Apple ID (a free one is fine, and the password is case-sensitive), and pick your iPhone.
4. Choose **LiveContainer+SideStore**, and pick the **Nightly** build. As of November 2026 the stable build's SideStore closes itself when you try to sign in.
5. On the iPhone: **Settings → General → VPN & Device Management →** your Apple ID **→ Trust**.
6. Still in Settings: **Privacy & Security → Developer Mode → On**. The phone restarts. Confirm with your passcode.

iloader then tells you to import a certificate and refresh. Don't yet: that only works after Parts 2 and 3.

#### Part 2: Make a pairing file

SideStore needs a *pairing file* to talk to the phone. **Use idevice_pair, not iloader's pairing file.** iloader's file holds two kinds of pairing at once, and SideStore rejects it with *"The pairing file format is ambiguous"*.

1. On the computer, download **[idevice_pair](https://github.com/jkcoxson/idevice_pair/releases/latest)**.
2. Keep the iPhone plugged in and unlocked, and pick it in idevice_pair.
3. Choose **Remote Pairing**. Not Lockdown: it imports, but refreshing fails later with *"Broken Pipe"*.
4. Click **Create** (it stays grey while the phone is locked), then save the file.
5. AirDrop it to the iPhone and choose **Save to Files**.

> [!CAUTION]
> The pairing file lets a device control your iPhone. Don't share it, and delete the copy on your computer once Part 3 is done.

#### Part 3: Set up SideStore

1. Install **LocalDevVPN** from the App Store and tap **Connect**. SideStore can only sign and refresh while it's connected.
2. Open LiveContainer and tap the **SideStore** button at the top left.
3. When it asks for a pairing file, tap **Select Pairing File** and pick the file from Part 2.
4. **Before you sign in**, open SideStore's **Settings** and:
   - turn **On-Device Anisette** off,
   - set the anisette server to **SideStore (New)**,
   - tap **Reset adi.pb**.
5. Force-close LiveContainer (swipe it away), open it again, go back into SideStore, and sign in with the same Apple ID you used in iloader.

Skip step 4 and sign-in usually crashes or fails.

#### Part 4: Refresh, then import the certificate

1. With LocalDevVPN connected, go to SideStore's **My Apps** and tap **Refresh All**. Only **LiveContainer** is listed. That's right: SideStore and every app you add live inside it, so refreshing LiveContainer keeps all of them alive. If it asks to revoke a certificate, tap **Yes**.
2. Force-close LiveContainer and open it again.
3. In LiveContainer's **Settings**, tap **Import Certificate from SideStore**, then **OK**. It worked when the button changes to **Remove Certificate**.

#### Install AdelaideTransit

The [latest release](https://github.com/RatterAU/AdelaideTransit/releases/latest) has one file, `AdelaideTransit.ipa`: an unsigned build that LiveContainer signs when it installs it. It has everything except the bus-details card (rego, model, photo), whose data can't be redistributed. [Build it yourself](#option-b-build-it-with-xcode) to get that too. There is no Android version.

1. Copy this link:

   ```
   https://github.com/RatterAU/AdelaideTransit/releases/latest/download/AdelaideTransit.ipa
   ```

2. Open LiveContainer, tap **+** at the top right of *My Apps*, choose **Install from URL**, paste the link, and tap **OK**.
3. Tap **AdelaideTransit** to open it. The first launch downloads the whole timetable (~20 MB), so give it a minute on Wi-Fi.

> [!IMPORTANT]
> **Don't AirDrop the `.ipa` to your phone.** iOS tries to install it as an ordinary app, leaves a grey icon on the home screen that won't open, and never saves the file. Use the link above instead. If you must move a file over, zip it first; a `.zip` is saved to Files.

> [!TIP]
> **Updating:** do the same again with the same link, which always points to the newest version. LiveContainer replaces the old one and keeps your settings.

#### Keep it working

A free Apple ID only signs apps for **7 days**, and that includes LiveContainer.

- **Refresh every 3–4 days:** connect LocalDevVPN, open SideStore inside LiveContainer, **My Apps → Refresh All**. Check the counter goes back to 7 days. To automate it, make a Shortcuts automation that connects LocalDevVPN, waits a few seconds, runs LiveContainer's **Refresh All Apps** action, then disconnects.
- **If a refresh made a new certificate**, import it again (**Settings → Import Certificate from SideStore**). Otherwise the apps inside won't open, even though LiveContainer does.
- **Write down the date you ran iloader.** There's a [known bug](https://github.com/LiveContainer/LiveContainer/issues/1243) where LiveContainer still expires 7 days after that, even though SideStore said it refreshed.
- **If LiveContainer won't open:** plug the phone in and run iloader again with the same Apple ID and the same build. It installs over the top and your apps survive. Then repeat Part 4.

<details>
<summary><b>If something goes wrong</b></summary>

<br>

| Problem | Fix |
|:--|:--|
| SideStore closes the moment you sign in | You're on the stable build, or skipped Part 3 step 4. Install the Nightly with iloader over the top, then do Part 3 |
| No **User Customizations** or anisette settings in SideStore | Same: that's the stable build. Use the Nightly |
| *"The pairing file format is ambiguous"* | That's iloader's pairing file. Make one with idevice_pair (Part 2) |
| Can't tap **Continue** on SideStore's pairing file screen | It needs a file selected first. **Set Up Later** works too, but nothing refreshes until you add one |
| *"Broken Pipe"* when refreshing | The pairing file is Lockdown. Make a **Remote Pairing** one |
| Refresh fails or hangs | Connect LocalDevVPN first |
| *"Certificate not found, did you log into built-in SideStore?"* | Sign in to SideStore first (Part 3). Or in SideStore **Settings → Export Signing Certificate...**, then LiveContainer **Settings → Import Certificate** |
| LiveContainer opens but AdelaideTransit won't | Re-import the certificate (Part 4, step 3). **Settings → JIT-Less Mode Diagnose** shows whether it's set up |
| LiveContainer won't open at all | Its 7 days ran out. Run iloader again, over the top. Don't delete it |
| Grey home-screen icon after AirDropping the `.ipa` | iOS tried to install it as a normal app. Delete that icon and use **Install from URL** instead |

</details>


### Option B: Build it with Xcode

#### What you need first

| | |
|:--|:--|
| **A Mac** | Any Mac running macOS Tahoe or later |
| **Xcode 26 or newer** | Free from the [Mac App Store](https://apps.apple.com/app/xcode/id497799835). It's a big download — start it now |
| **An iPhone on iOS 26** | Plus its USB cable, for the first install |
| **An Apple ID** | The free one you already have is fine. No paid developer account needed |

#### Step 1 — Get the code

Open **Terminal** and paste this in, one block:

```bash
git clone https://github.com/RatterAU/AdelaideTransit.git
cd AdelaideTransit/AdelaideTransit
```

#### Step 2 — Generate the Xcode project

The `.xcodeproj` isn't stored in this repo — it's generated from `project.yml`, so it has to be built once:

```bash
brew install xcodegen     # only needed the first time
xcodegen generate
open AdelaideTransit.xcodeproj
```

<sub>No Homebrew? Install it from <a href="https://brew.sh">brew.sh</a> first, then run the above.</sub>

<details>
<summary><b>Optional — bus details (rego, model, photo)</b></summary>

<br>

The live feed only says a bus's fleet number. Everything else comes from a snapshot of the [Australian Bus Fleet Lists](https://fleetlists.busaustralia.com/index-sa.php), an enthusiast-run site whose terms allow reference use, so the snapshot isn't published in this repo. Build your own copy, for your own phone:

```bash
python3 ../scripts/fleet_snapshot.py   # writes Resources/fleet.json, ~1,100 buses
xcodegen generate
```

Skip it and the app works exactly the same, minus the bus-details card. Re-run it now and then as the fleet changes.

</details>

#### Step 3 — Tell Xcode it's yours

Xcode is now open. In the left sidebar click the blue **AdelaideTransit** project icon at the very top, then:

1. Select the **AdelaideTransit** target → the **Signing & Capabilities** tab
2. Tick **Automatically manage signing**
3. **Team** → *Add an Account…* → sign in with your Apple ID → pick it from the dropdown
4. Change **Bundle Identifier** to something unique to you, e.g. `com.yourname.adelaidetransit`

<sub>Step 4 matters: bundle IDs are global, so the default one won't be available to your account.</sub>

#### Step 4 — Run it on your phone

1. Plug your iPhone in and unlock it. Tap **Trust** if asked
2. In Xcode's toolbar, click the device dropdown (next to the app name) and pick your iPhone
3. Press **⌘R**, or the ▶ button

The first build takes a few minutes.

#### Step 5 — Trust the app on your iPhone

The first launch will fail with *"Untrusted Developer"*. That's expected. On your iPhone:

**Settings → General → VPN & Device Management → your Apple ID → Trust**

Open the app again and it works.

> [!NOTE]
> **First launch downloads the whole timetable (~20 MB)** and files it away on your phone. Give it a minute on Wi-Fi. After that, screens open instantly and only live positions need the network.

> [!IMPORTANT]
> **With a free Apple ID, the app stops opening after 7 days.** This is Apple's rule, not the app's — free signing certificates expire weekly. To keep using it, plug the phone in and press **⌘R** again; your favourites and settings survive. A paid Apple Developer account extends this to a year.

<details>
<summary><b>If something goes wrong</b></summary>

<br>

| Problem | Fix |
|:--|:--|
| `xcodegen: command not found` | `brew install xcodegen`, then reopen Terminal |
| *"Failed to register bundle identifier"* | Someone already used that bundle ID. Change it to something more unique in Signing & Capabilities |
| *"Untrusted Developer"* on launch | Step 5 above — the trust setting on the iPhone |
| *"Developer Mode required"* on launch | **Settings → Privacy & Security → Developer Mode → On**, then let the phone restart |
| App won't open after a week | Expected on a free account. Rebuild with ⌘R |
| Xcode offers to *"Update to recommended settings"* | Decline. Project settings live in `project.yml`, and accepting makes the prompt come back forever |
| Build errors after you add a file | Run `xcodegen generate` again |

</details>

<details>
<summary><b>Running the tests</b></summary>

<br>

```bash
xcodebuild -project AdelaideTransit.xcodeproj -scheme AdelaideTransit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

139 tests, Swift Testing (one skips without the fleet snapshot). `project.yml` is the source of truth for the project — run `xcodegen generate` after adding any file, and never hand-edit the `.xcodeproj`.

</details>

## Under the hood

Two feeds, one junction. The timetable arrives once a day as a big ZIP and goes into local SQLite. The live picture arrives as three protobuf feeds: bus positions every 15 seconds, arrival predictions about once a minute. They're combined in exactly one place, `Merge`, which is pure code with tests around it — no view ever does this arithmetic itself.

```mermaid
flowchart LR
    ZIP["GTFS timetable ZIP<br/><i>~20 MB, daily</i>"] --> ING[Ingest]
    ING --> NET[("network.sqlite<br/><i>disposable cache</i>")]
    USR[("user.sqlite<br/><i>your favourites</i>")] --> STORE
    NET --> STORE(["GTFSStore<br/><i>the only SQL surface</i>"])

    TU[trip_updates] --> ENG
    VP[vehicle_positions] --> ENG
    AL[alerts] --> ENG["RealtimeEngine<br/><i>polls in step with the feed</i>"]

    STORE --> MERGE{{"Merge<br/><i>pure · tested</i>"}}
    ENG --> MERGE
    MERGE --> UI["Map · Stop · Trip<br/>Favourites · Alerts"]
```

Three decisions carry most of the weight:

- **Your favourites live in a separate database file from the timetable.** They were one file once, and a routine timetable update wiped every starred stop. Now ingest can replace the whole network database and never touch yours.
- **A new timetable is validated before it replaces the old one**, and the old file is moved aside rather than deleted. A half-finished download is still perfectly valid SQLite, which is exactly what makes it dangerous.
- **All the schedule/real-time reconciliation is in one tested file.** Delays, cancellations, service-day maths, "is this actually live", estimated positions for untracked buses — one place, so there's one place to be wrong.

<details>
<summary><b>Things the feed doesn't tell you, that I had to measure</b></summary>

<br>

Most of the app's design came from poking at the real feeds rather than trusting the spec.

| What's actually true | What the app does about it |
|:--|:--|
| **Each feed has its own clock**: positions every 15 seconds, predictions every ~60 (it was 15 until late 2026), readable 1–8.5 s after their timestamp. Polling faster returns byte-identical data | The poller learns each feed's cadence and locks onto its clock, so a refresh lands just after new data exists — and doesn't re-download the same minute of predictions seven times |
| **No `ETag`, no `Last-Modified`**, and gzip is ignored — but `Range` requests work, and the timestamp is in the first few bytes | Before downloading a feed it already holds, the app reads its first 256 bytes and stops there if nothing changed. Pre-fetching happens only on unconstrained Wi-Fi, never on cellular or Low Data |
| **A terminus lists every service ending there** — 829 of 1,657 rows at Adelaide Railway Station; 4,363 timetable rows are drop-off only | Neither is shown as a departure |
| **A stop drops out of the feed once the bus has passed it** — including when it passes *ahead* of schedule, which 72 of 893 passed stops were | That drop is what says "Departed", not the timetable clock. A stop still listed past its predicted minute reads "Due" — 44 of 529 were still coming a minute later |
| **The alerts feed stamps itself ~10.5 hours in the future**, and splits each bounded alert into a start-only and an end-only period | The app schedules alert refreshes off its own clock, and reads the split pair as one window — so "Until" dates show and finished alerts drop off |
| **Nothing reports which stop a bus is at** — 0 of 627 vehicles carry that field | Position is inferred from which stops have dropped out of the trip's update list: the lowest one still published *is* where the bus is. Held for 790 of 792 trips over five minutes |
| **Predicted arrival times are absolute, and a delay figure is never sent** — 14,098 out of 14,098 | Delay is computed, and stops without their own prediction are interpolated between the nearest known ones. That's what lets a recovering bus tick 6 min late → 3, instead of freezing |
| **Crowding is reported by only a few buses** — none until recently, 26 of 413 when last measured | Shown where a bus reports it, and nowhere else. No guesses for the rest |
| **The vehicle field is just a fleet number** — no rego, no model | Rego, model, age and photo come from a separate fleet snapshot, looked up by that number |
| **Route types aren't only the basic GTFS codes** — 319 bus routes, including every school route, are filed as 701 or 712 rather than 3 | They're folded back to "bus" in one place, so hiding buses or filtering alerts by mode catches all of them |
| 14,895 of 31,379 trips **continue under a different route number** (a 502 becomes a 110 at Grenfell St) | The app follows the vehicle through the change — matched by position rather than stop ID, because an interchange is a dozen stops with different IDs |

</details>

<details>
<summary><b>Why the map stays smooth with 9,171 stops</b></summary>

<br>

- Stops are **thinned, not clustered**: the busiest stop in each grid square survives, and the grid is anchored to fixed coordinates. Clustering re-partitions on every pan, which turns a drag into endless merge/split churn. Starred stops always survive the thinning.
- The map view does **no unconditional work** on redraw — it's called on every frame and every pan tick, so everything it does is gated on something having actually changed.
- Departure queries are **bounded in SQL**. The naive version read an entire service day for a stop served by 62 routes and threw nearly all of it away.
- Search is **debounced and cancellable**, because it's an unindexed substring scan over every stop and out-of-order replies used to leave the wrong list on screen.

</details>

<details>
<summary><b>Source layout</b></summary>

<br>

```
App/          App entry, tab router, theme + shared formatting
Data/
  GTFS/       Zip reader, ingest, SQLite schema + migrations, queries
  Models/     Departure, LiveVehicle, StopSummary, Fleet
  Realtime/   Poll scheduler, protobuf decoding, HTML stripping, Merge
Features/
  Map/        MKMapView bridge, stop sheet, trip detail, walk estimates
  Favourites/ Starred stops, live-sorted
  Alerts/     Service alerts
  Settings/   Windows, thresholds, clock format
Tests/        Swift Testing
../scripts/   fleet_snapshot.py — builds the optional fleet snapshot
```

</details>

## Privacy

Your location never leaves your phone. It's used for centring the map, sorting stops by distance and estimating walk times — nothing else. There is no account, no backend, no analytics and no third-party SDK. The only network traffic is to Adelaide Metro's public feeds, to Apple for maps and walking directions, and to Wikimedia Commons when you open a bus's details and its photo loads.

## Data & licence

Timetable and real-time data © Department for Infrastructure and Transport, South Australia, published as open GTFS feeds. This project is not affiliated with or endorsed by Adelaide Metro.

Bus details come from the [Australian Bus Fleet Lists](https://fleetlists.busaustralia.com/), built locally and not redistributed here. Bus photos are from [Wikimedia Commons](https://commons.wikimedia.org/wiki/Category:Buses_in_Adelaide) under their own free licences (CC0, CC BY, CC BY-SA). The app shows each photographer and licence and links to the original.

Code is MIT licensed — see [LICENSE](LICENSE).

<div align="center">
<br>
<sub>Built in Adelaide 🇦🇺</sub>
</div>
