import Foundation

enum TrackingState: Equatable {
    /// Live data hasn't arrived yet — distinct from `.scheduled`, which asserts the service *is* on time.
    /// Showing "Scheduled" before trip_updates lands was a claim the app couldn't back, and it visibly
    /// flipped to LIVE a second later.
    case pending
    case scheduled
    case live
    case stale(secondsAgo: Int)
    case ghost
    case cancelled
}

struct Departure: Identifiable, Equatable {
    var id: String { "\(tripID)#\(stopSequence)" }
    let tripID: String
    let stopSequence: Int
    let routeID: String
    let routeShortName: String
    let routeColor: String?
    let headsign: String
    let direction: Int?
    let scheduledTime: Date
    let liveTime: Date?
    let state: TrackingState

    var delta: TimeInterval? {
        guard let liveTime else { return nil }
        return liveTime.timeIntervalSince(scheduledTime)
    }

    var displayTime: Date { liveTime ?? scheduledTime }
}
