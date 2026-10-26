import CoreLocation
import Foundation

struct LiveVehicle: Identifiable, Sendable, Equatable {
    var id: String { tripID }
    let tripID: String
    let vehicleLabel: String?
    let routeID: String?
    let directionID: Int?
    let lat: Double
    let lon: Double
    let bearing: Double?
    let speedMS: Double?
    let timestamp: Date
    let currentStopSequence: UInt32?
    /// Crowding, on the minority of buses that report it (26/413 measured 2026-10-26; none earlier).
    /// `.noDataAvailable` is stored as nil so "unknown" has one spelling.
    var occupancy: Occupancy? = nil

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    var speedKMH: Double? { speedMS.map { $0 * 3.6 } }
}

typealias Occupancy = TransitRealtime_VehiclePosition.OccupancyStatus
