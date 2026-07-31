import Foundation

struct StopSummary: Identifiable, Equatable, Hashable {
    let id: String
    let code: String?
    let name: String
    let lat: Double
    let lon: Double
}

/// Ranking for stop search. Split out from the query because SQL can filter but can't usefully order this:
/// `LIKE '%…%' LIMIT 30` handed back whichever thirty rows the table happened to store first, so a search
/// for a street returned an arbitrary third of the stops on it and the one you were standing at was rarely
/// among them.
enum StopSearch {
    /// Words to match, lowercased, punctuation dropped. Every token has to match *somewhere* in the stop
    /// (see the SQL), so "grenfell 12" and "12 grenfell" both find the same stop — the old single `%query%`
    /// pattern demanded the user's words be contiguous and in the feed's order.
    static func tokens(_ query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Lower is better. Whole-code match first (typing a stop number means you want that stop), then a token
    /// starting a word in the name, then anything else — a substring buried mid-word is the weakest hit.
    static func score(name: String, code: String?, tokens: [String]) -> Int {
        let lowerName = name.lowercased()
        let lowerCode = code?.lowercased()
        if let lowerCode, tokens.contains(lowerCode) { return 0 }
        let words = lowerName.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let allStartWords = tokens.allSatisfy { token in words.contains { $0.hasPrefix(token) } }
        if allStartWords { return 1 }
        let anyStartsWord = tokens.contains { token in words.contains { $0.hasPrefix(token) } }
        return anyStartsWord ? 2 : 3
    }

    /// Best matches first: score, then distance from the user when known — of the twenty "Grenfell St" stops
    /// the one you can see is the one you meant. Falls back to shorter names, which are the through-street
    /// stops rather than the interchange bays.
    static func rank(
        _ stops: [StopSummary], tokens: [String], near: (lat: Double, lon: Double)?, limit: Int = 30
    ) -> [StopSummary] {
        stops
            .map { (stop: $0, score: score(name: $0.name, code: $0.code, tokens: tokens)) }
            .sorted { a, b in
                if a.score != b.score { return a.score < b.score }
                if let near {
                    // Squared degrees: monotonic in real distance over a city, and no trig per row.
                    let da = pow(a.stop.lat - near.lat, 2) + pow(a.stop.lon - near.lon, 2)
                    let db = pow(b.stop.lat - near.lat, 2) + pow(b.stop.lon - near.lon, 2)
                    if da != db { return da < db }
                }
                if a.stop.name.count != b.stop.name.count { return a.stop.name.count < b.stop.name.count }
                return a.stop.id < b.stop.id
            }
            .prefix(limit)
            .map(\.stop)
    }
}
