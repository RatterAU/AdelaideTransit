import Foundation

struct StopSummary: Identifiable, Equatable, Hashable {
    let id: String
    let code: String?
    let name: String
    let lat: Double
    let lon: Double
}
