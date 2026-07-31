import SwiftUI
import BackgroundTasks

private let refreshTaskID = "com.adelaidetransit.app.refresh"
private let lastRefreshCheckDayKey = "lastTimetableCheckDay"

private struct GTFSStoreKey: EnvironmentKey {
    static let defaultValue = GTFSStore.shared
}
private struct RealtimeEngineKey: EnvironmentKey {
    static let defaultValue = RealtimeEngine()
}
extension EnvironmentValues {
    var gtfsStore: GTFSStore {
        get { self[GTFSStoreKey.self] }
        set { self[GTFSStoreKey.self] = newValue }
    }
    var realtimeEngine: RealtimeEngine {
        get { self[RealtimeEngineKey.self] }
        set { self[RealtimeEngineKey.self] = newValue }
    }
}

@MainActor
@Observable
final class AppBootstrap {
    var isReady = false
    var isDownloading = false
    var progressMessage = "Downloading network — about 30 MB"
    var errorMessage: String?

    func start(store: GTFSStore) async {
        isReady = await store.isReady
        if isReady {
            // Detached: a database migrated in place needs its `importance` values computed, which is a
            // GROUP BY over every stop_time. The map works without it (just thins arbitrarily), so it must
            // never sit between launch and first paint.
            Task.detached(priority: .utility) {
                try? await store.backfillStopImportanceIfNeeded()
                try? await store.rearmIngestIfBlocksMissing()
            }
            return // hot path: existing db, no network needed to become interactive
        }
        isDownloading = true
        do {
            try await store.refreshIfNeeded()
            isReady = await store.isReady
        } catch {
            errorMessage = error.localizedDescription
        }
        isDownloading = false
    }

    func retry(store: GTFSStore) async {
        errorMessage = nil
        await start(store: store)
    }
}

@main
struct AdelaideTransitApp: App {
    @State private var store = GTFSStore.shared
    @State private var engine = RealtimeEngine()
    @State private var bootstrap = AppBootstrap()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            Self.handleBackgroundRefresh(task: task as! BGAppRefreshTask)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if bootstrap.isReady {
                    RootTabView()
                } else {
                    FirstLaunchView(bootstrap: bootstrap, store: store)
                }
            }
            .environment(\.gtfsStore, store)
            .environment(\.realtimeEngine, engine)
            .task {
                await engine.start()
                await bootstrap.start(store: store)
                // `onChange(of: scenePhase)` does not fire for the initial `.active`, so on a cold launch
                // neither of these ran at all — the "once per Adelaide day" timetable check only happened
                // if you backgrounded and returned, and the BG refresh task was never resubmitted.
                Self.scheduleBackgroundRefresh()
                dailyRefreshCheck()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await engine.setBackgrounded(phase != .active) }
            guard phase == .active else { return }
            Self.scheduleBackgroundRefresh()
            dailyRefreshCheck()
        }
    }

    private static func handleBackgroundRefresh(task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()
        let operation = Task {
            // The app's own store, not a second one on the same files — see `GTFSStore.shared`.
            let allowCellular = UserDefaults.standard.bool(forKey: "allowCellularUpdates")
            try? await GTFSStore.shared.refreshIfNeeded(allowCellular: allowCellular)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { operation.cancel() }
    }

    private static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Timetable check runs at most once per Adelaide calendar day, on the first open of that day, detached
    /// so the UI never waits on it. `refreshIfNeeded` does a conditional-GET first, so a day with no new feed
    /// costs one small request rather than the 30 MB download.
    private func dailyRefreshCheck() {
        let today = AdelaideTZ.yyyymmdd(.now)
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: lastRefreshCheckDayKey) != today else { return }
        defaults.set(today, forKey: lastRefreshCheckDayKey)

        Task.detached(priority: .utility) {
            let allowCellular = defaults.bool(forKey: "allowCellularUpdates")
            do {
                try await store.refreshIfNeeded(allowCellular: allowCellular)
            } catch {
                // Leave the day unmarked so the next open retries rather than skipping until tomorrow.
                defaults.removeObject(forKey: lastRefreshCheckDayKey)
            }
        }
    }
}

private struct FirstLaunchView: View {
    let bootstrap: AppBootstrap
    let store: GTFSStore

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bus.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            if let error = bootstrap.errorMessage {
                Text("Couldn't download timetable data")
                    .font(.headline)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Retry") { Task { await bootstrap.retry(store: store) } }
                    .buttonStyle(.borderedProminent)
            } else {
                ProgressView()
                Text(bootstrap.progressMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
