import Foundation

/// One bus, from the bundled `fleet.json` snapshot keyed by fleet number — the realtime feed's `vehicle.label`
/// is that number and nothing more, so rego, model and age only exist here. Built by
/// `scripts/fleet_snapshot.py` from the Australian Bus Fleet Lists and Wikimedia Commons; re-run it by hand.
struct FleetBus: Decodable, Sendable, Equatable {
    let rego: String?
    let chassis: String
    let vin: String?
    let body: String
    let bodyNumber: String?
    /// Body build date as the list gives it: "12/2004" or just "2002".
    let built: String?
    /// Australian seating code, e.g. "B45FW" — the number is seats.
    let seating: String?
    let livery: String?
    let depot: String?
    let `operator`: String
    /// "chassis / body model", the key model photos are shared under.
    let model: String
    /// History from the list ("ex …", "Owned by …") — what makes this bus unlike its siblings.
    let notes: String?
    /// Commons file title of a photo of *this* bus, when one exists.
    let photo: String?

    var seats: Int? {
        seating.flatMap { code in code.firstMatch(of: #/\d+/#).flatMap { Int($0.output) } }
    }

    /// Whole years since the body was built, nil when the year doesn't parse.
    func age(now: Date = .now) -> Int? {
        guard let built, let year = built.firstMatch(of: #/\d{4}/#).flatMap({ Int($0.output) }) else { return nil }
        let current = AdelaideTZ.calendar.component(.year, from: now)
        return max(0, current - year)
    }
}

struct FleetPhoto: Decodable, Sendable, Equatable {
    let url: URL
    /// The Commons file page — the licence asks for a link back.
    let page: URL
    let artist: String
    let licence: String
}

enum Fleet {
    private struct Snapshot: Decodable, Sendable {
        let buses: [String: FleetBus]
        let modelPhotos: [String: String]
        let images: [String: FleetPhoto]
    }

    /// Decoded on first use (~1100 buses, a few ms), never again. A missing or malformed file is no details,
    /// not a crash — the rest of the app never needed it.
    private static let snapshot: Snapshot? = {
        guard let url = Bundle.main.url(forResource: "fleet", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }()

    static func bus(_ fleetNumber: String) -> FleetBus? { snapshot?.buses[fleetNumber] }

    /// A photo of this bus if Commons has one, else one of the same model — `isThisBus` says which, and
    /// the UI must say so: a sibling's photo shown as "this bus" would be a claim about rego and livery.
    static func photo(for bus: FleetBus) -> (photo: FleetPhoto, isThisBus: Bool)? {
        guard let snapshot else { return nil }
        if let title = bus.photo, let photo = snapshot.images[title] { return (photo, true) }
        if let title = snapshot.modelPhotos[bus.model], let photo = snapshot.images[title] { return (photo, false) }
        return nil
    }
}
