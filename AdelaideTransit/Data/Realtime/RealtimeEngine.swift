import Foundation
import Network

/// When to ask the server again.
///
/// The Adelaide Metro feeds publish on a fixed clock (measured: every 15s, fetchable ~5s after the timestamp
/// they carry) and offer neither `ETag` nor gzip. So a poll that lands mid-cycle re-downloads a byte-identical
/// payload at full size — cadence is the only lever there is. Rather than sleeping a fixed interval, which
/// drifts against the source clock, aim at just after the *next* publish.
enum PollSchedule {
    static let publishLag: TimeInterval = 5
    static let missRetry: TimeInterval = 3
    static let minCycle: TimeInterval = 5
    static let maxCycle: TimeInterval = 60

    static func nextDelay(
        lastHeader: Date?, cycle: TimeInterval, multiplier: Double, gotNewData: Bool, now: Date
    ) -> TimeInterval {
        let span = cycle * multiplier
        guard let lastHeader else {
            return gotNewData ? span : missRetry
        }
        let delay = lastHeader.addingTimeInterval(span + publishLag).timeIntervalSince(now)
        // Already past the expected publish: chase it with a short retry rather than idling a whole cycle.
        return delay > 0 ? delay : missRetry
    }

    /// Learn the source's real cadence from the gap between consecutive publish timestamps.
    /// Only valid when sampling every cycle — a deliberately slowed feed would otherwise learn its own
    /// skip rate and slow further on each pass.
    static func learnedCycle(
        previous: TimeInterval, lastHeader: Date?, newHeader: Date, multiplier: Double
    ) -> TimeInterval {
        guard multiplier <= 1.0, let lastHeader else { return previous }
        let delta = newHeader.timeIntervalSince(lastHeader)
        guard delta >= minCycle, delta <= maxCycle else { return previous }
        return delta
    }
}

enum ScreenDemand: Equatable {
    case none
    /// `showsVehicles` is the "Show all live buses" setting. With it off the map draws no vehicle markers at
    /// all until you open a trip, which is its own demand — so polling vehicle_positions under it was 45 KB
    /// every 15s fetched to be discarded.
    case map(stopSheetOpen: Bool, showsVehicles: Bool)
    case tripDetail
    case favourites
    case alertsTab
}

/// Polls only what the visible screen needs, at the interval that screen needs it (§2.2, §4).
/// Raw protobuf never leaves this actor — everything is converted to small Sendable structs on arrival.
actor RealtimeEngine {
    /// One engine per process, for the same reason `GTFSStore.shared` is one store.
    ///
    /// The environment key's default value and the app's `@State` were two separate `RealtimeEngine()`
    /// calls, so anything rendered before the injection lands — or any view that loses the environment —
    /// gets a *second* actor that starts its own three poll loops against the same three feeds. Two full
    /// uncompressed downloads per publish cycle for data the other one already has, with neither able to
    /// see the other's demand, backoff or learned cadence.
    static let shared = RealtimeEngine()

    private(set) var vehicles: [String: LiveVehicle] = [:]
    private(set) var predictions: [String: [UInt32: Prediction]] = [:]
    private(set) var cancelledTripIDs: Set<String> = []
    private(set) var alerts: [ServiceAlert] = []
    private(set) var lastFrame: RealtimeFrame?

    /// One stream per consumer. A single shared AsyncStream would let whichever screen awaited first
    /// *steal* each frame from the others — with Map, Favourites and Alerts all subscribed, every screen
    /// saw roughly a third of the data.
    private var subscribers: [UUID: AsyncStream<RealtimeFrame>.Continuation] = [:]

    nonisolated var frames: AsyncStream<RealtimeFrame> {
        // bufferingNewest(1): frames are whole snapshots, so a queued older one is pure staleness.
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            continuation.onTermination = { _ in
                Task { await self.removeSubscriber(id) }
            }
            Task { await self.addSubscriber(id, continuation) }
        }
    }

    private func addSubscriber(_ id: UUID, _ continuation: AsyncStream<RealtimeFrame>.Continuation) {
        subscribers[id] = continuation
        // Hand over what we already have so a newly-shown screen isn't blank until the next poll.
        if let lastFrame { continuation.yield(lastFrame) }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private var demand: ScreenDemand = .none
    private var backgrounded = false
    private var dataSaver = false
    private var speedScale: TimeInterval = 1.0
    private var started = false

    private var etags: [Feed: String] = [:]
    private var lastVehiclesHeaderTimestamp: UInt64?
    private var lastTripUpdatesHeaderTimestamp: UInt64?
    private var lastAlertsHeaderTimestamp: UInt64?
    /// False until the first successful trip_updates poll. Before that we genuinely don't know whether a
    /// service is running to time, and must not claim otherwise.
    private var hasTripUpdates = false
    /// The feed's own publish time — what "data Ns old" must report. Local `Date()` would always read ~0s
    /// and hide exactly the staleness the badge exists to surface.
    private var feedTimestamp: Date?

    private enum Feed: CaseIterable { case vehicles, tripUpdates, alerts }

    // Measured against the live feeds; `PollSchedule` re-derives it if the publisher ever changes cadence.
    private static let defaultPublishCycle: TimeInterval = 15

    private var lastHeaderDate: [Feed: Date] = [:]
    private var learnedCycle: [Feed: TimeInterval] = [:]
    private var loopTasks: [Task<Void, Never>] = []
    private var onWiFi = false
    /// iOS Low Data Mode / a hotspot marked expensive. Treated exactly like the Data Saver toggle, which is
    /// what Settings already promises.
    private var pathConstrained = false
    /// Consecutive failed fetches per feed, so an outage backs off instead of retrying every 3s forever.
    private var failures: [Feed: Int] = [:]
    /// When a failing feed is next allowed to hit the network. Survives a loop restart, which the backoff
    /// otherwise didn't — see `loop`. Nil while the feed is healthy.
    private var nextAttempt: [Feed: Date] = [:]

    private enum Endpoint {
        static let tripUpdates = URL(string: "https://gtfs.adelaidemetro.com.au/v1/realtime/trip_updates")!
        static let vehiclePositions = URL(string: "https://gtfs.adelaidemetro.com.au/v1/realtime/vehicle_positions")!
        static let serviceAlerts = URL(string: "https://gtfs.adelaidemetro.com.au/v1/realtime/service_alerts")!
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// Screens call this from .onAppear/.onDisappear with their demand; engine polls only what's needed.
    func setDemand(_ demand: ScreenDemand) {
        guard demand != self.demand else { return }
        self.demand = demand
        // A newly-opened screen shouldn't wait out an idle tick for its first data.
        refreshNow()
    }

    /// Backgrounded apps keep running for a while before iOS suspends them — without this the trip-detail
    /// screen carries on hitting the network every 5s in your pocket.
    func setBackgrounded(_ value: Bool) {
        let wasBackgrounded = backgrounded
        backgrounded = value
        if wasBackgrounded && !value { refreshNow() }
    }

    /// Poll every demanded feed immediately instead of waiting out the loop's current sleep.
    ///
    /// Coming back to the app was showing "83s old" for up to another 10s, because the idle loop was
    /// mid-sleep. Whatever is on screen when you unlock is the thing you want current.
    func refreshNow() {
        startLoops()
    }

    /// Restarts the loops, like every other input to `cycleMultiplier` does. Without that a loop already
    /// parked in a sleep kept the old cadence until it happened to wake, and the backstop below is free to
    /// be a slow tick precisely because every real change restarts. Guarded because Settings re-asserts
    /// both of these on every appear.
    func setDataSaver(_ enabled: Bool) {
        guard enabled != dataSaver else { return }
        dataSaver = enabled
        startLoops()
    }

    /// 0.5 = Fast, 1.0 = Normal, 2.0 = Relaxed — user-selectable in Settings.
    func setSpeedScale(_ scale: TimeInterval) {
        guard scale != speedScale else { return }
        speedScale = scale
        startLoops()
    }

    func start() {
        guard !started else { return }
        started = true
        startMonitoringPath()
        startLoops()
    }

    /// Restarts every feed loop. Each loop polls immediately on entry, so this *is* the refresh — no separate
    /// one-shot path that could double-fetch, and any loop parked in a long sleep is torn down rather than
    /// left to wake up later and poll again on a stale schedule.
    private func startLoops() {
        for task in loopTasks { task.cancel() }
        loopTasks = Feed.allCases.map { feed in
            Task { await self.loop(feed) }
        }
    }

    /// Held as a stored property: the previous local was released as soon as `startMonitoringPath` returned.
    private let pathMonitor = NWPathMonitor()

    private func startMonitoringPath() {
        pathMonitor.pathUpdateHandler = { path in
            let isWiFi = path.status == .satisfied && !path.usesInterfaceType(.cellular)
            // `isConstrained` is exactly iOS Low Data Mode. Deliberately not `isExpensive`, which is true of
            // all cellular and would quietly halve the refresh rate off Wi-Fi.
            Task { await self.setPath(wifi: isWiFi, constrained: path.isConstrained) }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func setPath(wifi: Bool, constrained: Bool) {
        guard wifi != onWiFi || constrained != pathConstrained else { return }
        onWiFi = wifi
        pathConstrained = constrained
        startLoops() // warm-cache eligibility just changed
    }

    /// How many publish cycles to skip for a given screen, or nil to not poll this feed at all.
    ///
    /// This is deliberately expressed in *cycles*, not seconds. The upstream publishes on a fixed clock, so
    /// asking more often than that cannot return anything fresher — it just re-downloads identical bytes.
    /// The old table asked for vehicles every 5s against a 15s feed, so two of every three fetches were waste.
    private func cycleMultiplier(for feed: Feed) -> Double? {
        guard !backgrounded else { return nil }
        let saver: Double = (dataSaver || pathConstrained) ? 2 : 1
        let scale = saver * speedScale

        // Alerts are polled slowly under every foreground screen, not just the Alerts tab, so the tab badge
        // for an alert on a favourite route stays current without opening the tab. 61 KB uncompressed and no
        // ETag, so gated off under Data Saver / Low Data — there the badge simply updates when you open Alerts.
        let backgroundAlerts: Double? = (dataSaver || pathConstrained) ? nil : 20 * scale

        switch (demand, feed) {
        case (.none, _): return nil
        case (.map(_, let showsVehicles), .vehicles): return showsVehicles ? 1 * scale : nil
        case (.map(let sheetOpen, _), .tripUpdates):
            if sheetOpen { return 1 * scale }
            // Warm the predictions cache so the first tap on a stop already has live times, but only where
            // the bytes are free — trip_updates is 240 KB uncompressed and this server offers no ETag.
            return (onWiFi && !dataSaver && !pathConstrained) ? 4 * scale : nil
        case (.map, .alerts): return backgroundAlerts
        case (.tripDetail, .vehicles): return 1 * scale
        case (.tripDetail, .tripUpdates): return 1 * scale
        case (.tripDetail, .alerts): return backgroundAlerts
        case (.favourites, .tripUpdates): return 1 * scale
        case (.favourites, .vehicles): return nil
        case (.favourites, .alerts): return backgroundAlerts
        case (.alertsTab, .alerts): return 4 * scale
        case (.alertsTab, _): return nil
        }
    }

    private func nextDelay(for feed: Feed, multiplier: Double, gotNewData: Bool) -> TimeInterval {
        PollSchedule.nextDelay(
            lastHeader: lastHeaderDate[feed],
            cycle: learnedCycle[feed] ?? Self.defaultPublishCycle,
            multiplier: multiplier,
            gotNewData: gotNewData,
            now: .now
        )
    }

    private func loop(_ feed: Feed) async {
        while !Task.isCancelled {
            guard let multiplier = cycleMultiplier(for: feed) else {
                // Nothing wants this feed. Every input to `cycleMultiplier` — demand, backgrounding, Data
                // Saver, refresh speed, the network path — restarts the loops, so a wanted feed never has to
                // wait for this tick. It was 5s awake, which had two idle loops waking twelve times a minute
                // on the Alerts tab to decide they had nothing to do.
                try? await Task.sleep(for: .seconds(30))
                continue
            }
            // Every loop restart — demand change, Wi-Fi flap, unlock — re-enters here and polls on entry.
            // That is what makes unlock-to-fresh instant, but opening and closing a stop sheet restarts the
            // loops too, and the source publishes on a fixed clock: re-fetching before it has published
            // again returns byte-identical bytes at full size (no ETag, no gzip). So wait out the remainder
            // of the current cycle instead. Freshness is unchanged — there is nothing newer to get.
            if let last = lastHeaderDate[feed] {
                let cycle = learnedCycle[feed] ?? Self.defaultPublishCycle
                let due = last.addingTimeInterval(cycle * multiplier + PollSchedule.publishLag)
                let wait = due.timeIntervalSinceNow
                if wait > 0.5 {
                    try? await Task.sleep(for: .seconds(wait))
                    continue
                }
            }
            // The same wait, for the backoff an outage has earned. `lastHeaderDate` can't cover this: during
            // an outage there may never have been a header, and the poll-on-entry above is unconditional. So
            // a network that flaps — which is when the endpoint is unreachable in the first place — restarted
            // the loops through `setPath` and had all three feeds hammer a dead server, over and over,
            // discarding the backoff each time it was about to take effect.
            if let earliest = nextAttempt[feed], earliest.timeIntervalSinceNow > 0.5 {
                try? await Task.sleep(for: .seconds(earliest.timeIntervalSinceNow))
                continue
            }
            let gotNewData = await poll(feed)
            let backoff = Self.backoff(failures: failures[feed] ?? 0)
            // Only the backoff survives a restart. Carrying the normal cadence too pinned a feed to the
            // *previous* screen's rate: warming trip_updates at 4 cycles on the map, then opening a stop,
            // left the sheet on minute-old predictions for up to another minute. `lastHeaderDate` above
            // already covers "nothing new published yet" at the new rate.
            nextAttempt[feed] = backoff > 0 ? Date().addingTimeInterval(backoff) : nil
            try? await Task.sleep(for: .seconds(max(
                nextDelay(for: feed, multiplier: multiplier, gotNewData: gotNewData), backoff
            )))
        }
    }

    /// With the network down, `missRetry` alone means three feeds hammering a dead endpoint every 3s for as
    /// long as the screen is up. Nothing is gained by asking faster when nothing is answering.
    static func backoff(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(60, PollSchedule.missRetry * pow(2, Double(failures - 1)))
    }

    /// Records the publish time of a newly-seen frame and, when we're sampling every cycle, learns the
    /// source's actual cadence. Only learns at multiplier 1 — a deliberately slowed feed would otherwise
    /// "learn" its own skip rate and slow further each time.
    private func noteHeader(_ date: Date, for feed: Feed, multiplier: Double) {
        // "Data Ns old" is about the departure data on screen. Alerts publish on their own schedule and
        // would drag the badge backwards; vehicles and trip_updates are the two that back it. Previously
        // only `pollVehicles` set this, so any screen that doesn't poll vehicles had no age at all.
        if feed != .alerts, date > (feedTimestamp ?? .distantPast) {
            feedTimestamp = date
        }
        learnedCycle[feed] = PollSchedule.learnedCycle(
            previous: learnedCycle[feed] ?? Self.defaultPublishCycle,
            lastHeader: lastHeaderDate[feed],
            newHeader: date,
            multiplier: multiplier
        )
        lastHeaderDate[feed] = date
    }

    /// Returns whether the poll produced a frame we hadn't already seen.
    private func poll(_ feed: Feed) async -> Bool {
        switch feed {
        case .vehicles: return await pollVehicles()
        case .tripUpdates: return await pollTripUpdates()
        case .alerts: return await pollAlerts()
        }
    }

    private func pollVehicles() async -> Bool {
        guard let message = await fetch(Endpoint.vehiclePositions, feed: .vehicles) else { return false }
        guard message.header.timestamp != lastVehiclesHeaderTimestamp else { return false }
        lastVehiclesHeaderTimestamp = message.header.timestamp
        if let published = Self.publishDate(of: message) {
            noteHeader(published, for: .vehicles, multiplier: cycleMultiplier(for: .vehicles) ?? 1)
        }

        var updated: [String: LiveVehicle] = [:]
        for entity in message.entity where entity.hasVehicle {
            let vp = entity.vehicle
            let tripID = vp.trip.tripID
            guard !tripID.isEmpty else { continue }
            updated[tripID] = LiveVehicle(
                tripID: tripID,
                vehicleLabel: vp.vehicle.label.isEmpty ? nil : vp.vehicle.label,
                routeID: vp.trip.routeID.isEmpty ? nil : vp.trip.routeID,
                directionID: vp.trip.hasDirectionID ? Int(vp.trip.directionID) : nil,
                lat: Double(vp.position.latitude), lon: Double(vp.position.longitude),
                bearing: vp.position.hasBearing ? Double(vp.position.bearing) : nil,
                speedMS: vp.position.hasSpeed ? Double(vp.position.speed) : nil,
                timestamp: vp.hasTimestamp ? Date(timeIntervalSince1970: TimeInterval(vp.timestamp)) : Date(),
                currentStopSequence: vp.hasCurrentStopSequence ? vp.currentStopSequence : nil
            )
        }
        vehicles = updated
        emitFrame()
        return true
    }

    private func pollTripUpdates() async -> Bool {
        guard let message = await fetch(Endpoint.tripUpdates, feed: .tripUpdates) else { return false }
        guard message.header.timestamp != lastTripUpdatesHeaderTimestamp else { return false }
        lastTripUpdatesHeaderTimestamp = message.header.timestamp
        if let published = Self.publishDate(of: message) {
            noteHeader(published, for: .tripUpdates, multiplier: cycleMultiplier(for: .tripUpdates) ?? 1)
        }

        var updated: [String: [UInt32: Prediction]] = [:]
        var cancelled: Set<String> = []
        for entity in message.entity where entity.hasTripUpdate {
            let tu = entity.tripUpdate
            let tripID = tu.trip.tripID
            guard !tripID.isEmpty else { continue }
            if tu.trip.hasScheduleRelationship, tu.trip.scheduleRelationship == .canceled {
                cancelled.insert(tripID)
            }
            var byStop: [UInt32: Prediction] = [:]
            for stu in tu.stopTimeUpdate {
                // Arrival delay preferred over departure: it's what a waiting rider experiences.
                let delay: TimeInterval? =
                    stu.hasArrival && stu.arrival.hasDelay ? TimeInterval(stu.arrival.delay)
                    : stu.hasDeparture && stu.departure.hasDelay ? TimeInterval(stu.departure.delay)
                    : nil
                byStop[stu.stopSequence] = Prediction(
                    stopID: stu.stopID,
                    arrival: stu.hasArrival && stu.arrival.hasTime ? Date(timeIntervalSince1970: TimeInterval(stu.arrival.time)) : nil,
                    departure: stu.hasDeparture && stu.departure.hasTime ? Date(timeIntervalSince1970: TimeInterval(stu.departure.time)) : nil,
                    delay: delay,
                    scheduleRelationship: stu.hasScheduleRelationship ? stu.scheduleRelationship : .scheduled
                )
            }
            updated[tripID] = byStop
        }
        predictions = updated
        cancelledTripIDs = cancelled
        hasTripUpdates = true
        emitFrame()
        return true
    }

    private func pollAlerts() async -> Bool {
        guard let message = await fetch(Endpoint.serviceAlerts, feed: .alerts) else { return false }
        guard message.header.timestamp != lastAlertsHeaderTimestamp else { return false }
        lastAlertsHeaderTimestamp = message.header.timestamp
        if let published = Self.publishDate(of: message) {
            noteHeader(published, for: .alerts, multiplier: cycleMultiplier(for: .alerts) ?? 1)
        }

        var result: [ServiceAlert] = []
        for entity in message.entity where entity.hasAlert {
            let a = entity.alert
            var routeIDs: Set<String> = []
            var stopIDs: Set<String> = []
            for selector in a.informedEntity {
                if !selector.routeID.isEmpty { routeIDs.insert(selector.routeID) }
                if !selector.stopID.isEmpty { stopIDs.insert(selector.stopID) }
            }
            // Every period, not just the first. A planned closure is routinely published as one alert with a
            // window per night, and reading `activePeriod.first` meant the whole alert expired — and was
            // filtered off the tab, the badge and the favourites banner — the morning after the first night.
            // Any period without an end makes the alert open-ended.
            let starts = a.activePeriod.compactMap {
                $0.hasStart ? Date(timeIntervalSince1970: TimeInterval($0.start)) : nil
            }
            let ends = a.activePeriod.compactMap {
                $0.hasEnd ? Date(timeIntervalSince1970: TimeInterval($0.end)) : nil
            }
            result.append(ServiceAlert(
                id: entity.id,
                // Flattened once here rather than per render — the feed ships HTML in both fields.
                headerText: HTMLText.plain(a.headerText.translation.first?.text ?? ""),
                descriptionText: HTMLText.plain(a.descriptionText.translation.first?.text ?? ""),
                effect: a.hasEffect ? a.effect : .unknownEffect,
                severity: a.hasSeverityLevel ? a.severityLevel : .unknownSeverity,
                informedRouteIDs: routeIDs, informedStopIDs: stopIDs,
                activeFrom: starts.min(),
                activeTo: ends.count == a.activePeriod.count ? ends.max() : nil
            ))
        }
        // Filtered here, once, rather than in each of the three consumers — the Alerts tab, the tab badge and
        // the favourites banner have to agree on what "active" means.
        alerts = result.filter { $0.isActive() }
        emitFrame()
        return true
    }

    /// Shared fetch. `If-None-Match` is still sent because it costs nothing and this server may gain support
    /// later — but note it currently returns neither `ETag` nor `Content-Encoding: gzip`, so every poll is a
    /// full uncompressed payload. That is why cadence is the only lever that matters.
    ///
    /// No explicit `Accept-Encoding`. URLSession already advertises gzip and inflates the response for you —
    /// but *only* while it owns the header. Setting it by hand opts out of that transparent handling, so the
    /// day this server does start compressing, every poll would hand raw deflate bytes to the protobuf
    /// decoder and fail. Nothing was gained for the risk: the header we were setting is a subset of the one
    /// URLSession sends anyway.
    private func fetch(_ url: URL, feed: Feed) async -> TransitRealtime_FeedMessage? {
        var request = URLRequest(url: url)
        if let etag = etags[feed] { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        guard let (data, response) = try? await Self.session.data(for: request),
              let http = response as? HTTPURLResponse else {
            failures[feed, default: 0] += 1
            return nil
        }
        // 304 carries no body but is a success, not an outage — counting it as a failure would break
        // polling the day this server gains conditional-GET support.
        guard http.statusCode != 304 else {
            failures[feed] = 0
            return nil
        }
        // A 5xx error page is not a feed. It already failed to parse; what it also did was reset the
        // failure count, so an outage retried every 3s indefinitely instead of backing off.
        guard (200...299).contains(http.statusCode),
              let message = try? TransitRealtime_FeedMessage(serializedBytes: data) else {
            failures[feed, default: 0] += 1
            return nil
        }
        failures[feed] = 0
        etags[feed] = http.value(forHTTPHeaderField: "ETag")
        return message
    }

    private static func publishDate(of message: TransitRealtime_FeedMessage) -> Date? {
        guard message.header.hasTimestamp, message.header.timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(message.header.timestamp))
    }

    private func emitFrame() {
        let frame = RealtimeFrame(
            vehicles: vehicles, predictions: predictions, cancelledTripIDs: cancelledTripIDs,
            alerts: alerts, headerTimestamp: feedTimestamp, hasTripUpdates: hasTripUpdates
        )
        lastFrame = frame
        for continuation in subscribers.values { continuation.yield(frame) }
    }
}
