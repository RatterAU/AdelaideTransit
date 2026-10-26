import Testing
import Foundation
@testable import AdelaideTransit

struct FleetTests {
    private func bus(seating: String?, built: String?, photo: String? = nil) throws -> FleetBus {
        var json: [String: Any] = ["chassis": "Scania L94UA", "body": "Custom Coaches 'CB60 Combo'",
                                   "operator": "Torrens Connect", "model": "Scania L94UA / CB60 Combo"]
        json["seating"] = seating
        json["built"] = built
        json["photo"] = photo
        return try JSONDecoder().decode(FleetBus.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func seatsAreTheNumberInTheSeatingCode() throws {
        #expect(try bus(seating: "AB67TW", built: nil).seats == 67)
        #expect(try bus(seating: "B45FW", built: nil).seats == 45)
        #expect(try bus(seating: nil, built: nil).seats == nil)
    }

    @Test func ageReadsTheYearFromEitherDateShape() throws {
        let now = try #require(AdelaideTZ.calendar.date(from: DateComponents(year: 2026, month: 10, day: 26)))
        #expect(try bus(seating: nil, built: "12/2004").age(now: now) == 22)
        #expect(try bus(seating: nil, built: "2002").age(now: now) == 24)
        #expect(try bus(seating: nil, built: "?").age(now: now) == nil)
    }

    /// The real bundled snapshot: present, plausibly complete, and every photo reference resolves — a
    /// dangling title would silently show no photo, and a model fallback must never claim to be the bus.
    /// Skipped on a fresh clone: the snapshot is git-ignored until `scripts/fleet_snapshot.py` builds it.
    @Test(.enabled(if: Bundle.main.url(forResource: "fleet", withExtension: "json") != nil))
    func bundledSnapshotLoadsAndPhotosResolve() throws {
        let known = try #require(Fleet.bus("1005"))
        #expect(known.rego != nil)
        #expect(Fleet.bus("not-a-bus") == nil)
        if let own = known.photo {
            #expect(Fleet.photo(for: known)?.isThisBus == true, "\(own) should resolve")
        }
        let sibling = try bus(seating: nil, built: nil)
        if let fallback = Fleet.photo(for: sibling) {
            #expect(fallback.isThisBus == false)
        }
    }
}
