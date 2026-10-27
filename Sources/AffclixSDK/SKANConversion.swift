import Foundation

/// The app's SKAdNetwork conversion-value schema, set in the Affclix dashboard
/// and served by the MMP (`/m/skan-schema`). A rule matches once the user has
/// sent `event` since installing (`"*"`: any in-app event) and, with
/// `min_revenue`, their revenue since installing (in `currency`) reaches it.
/// The fine value is the highest matching fine rule's, the coarse value the
/// highest matching coarse rule's.
struct SKANSchema: Codable, Equatable {
    struct FineRule: Codable, Equatable {
        let value: Int
        let event: String
        let min_revenue: Double?
    }

    struct CoarseRule: Codable, Equatable {
        let value: String
        let event: String
        let min_revenue: Double?
    }

    let version: Int
    let currency: String
    let fine: [FineRule]
    let coarse: [CoarseRule]
}

/// What the user did since installing, as far as the schema cares.
struct SKANProgress: Codable, Equatable {
    var events: Set<String> = []
    var revenue: Double = 0
    /// The values last set, so an update is sent only when one goes up.
    var fine: Int = 0
    var coarse: String?
}

enum SKANConversion {
    /// Apple measures SKAdNetwork 4 conversions for 35 days after install.
    static let measurementWindow: TimeInterval = 35 * 24 * 3600

    /// Events the SDK sends by itself: not in-app actions, so `"*"` ignores them.
    static let systemEvents: Set<String> = ["session_start", "deep_link", "install"]

    private static let coarseRank = ["low": 1, "medium": 2, "high": 3]

    /// Adds an event to the progress: its name, and its revenue when it is in the
    /// schema's currency (or names none).
    static func record(_ name: String, params: [String: Any], schema: SKANSchema, into progress: inout SKANProgress) {
        guard !systemEvents.contains(name) else { return }
        progress.events.insert(name)
        let currency = (params["currency"] as? String)?.uppercased()
        if let revenue = number(params["revenue"]), currency == nil || currency == schema.currency.uppercased() {
            progress.revenue += revenue
        }
    }

    /// The fine and coarse values the progress earns under the schema.
    static func evaluate(_ schema: SKANSchema, _ progress: SKANProgress) -> (fine: Int, coarse: String?) {
        func matches(_ event: String, _ minRevenue: Double?) -> Bool {
            let eventOK = event == "*" ? !progress.events.isEmpty : progress.events.contains(event)
            return eventOK && progress.revenue + 1e-9 >= (minRevenue ?? 0)
        }
        let fine = schema.fine.filter { matches($0.event, $0.min_revenue) }.map(\.value).max() ?? 0
        let coarse = schema.coarse
            .filter { matches($0.event, $0.min_revenue) && coarseRank[$0.value] != nil }
            .max { coarseRank[$0.value]! < coarseRank[$1.value]! }?.value
        return (min(max(fine, 0), 63), coarse)
    }

    /// The update to send, if either value went up; marks it in the progress.
    static func nextUpdate(_ schema: SKANSchema, _ progress: inout SKANProgress) -> (fine: Int, coarse: CoarseConversionValue?)? {
        let (fine, coarse) = evaluate(schema, progress)
        let fineUp = fine > progress.fine
        let coarseUp = (coarse.flatMap { coarseRank[$0] } ?? 0) > (progress.coarse.flatMap { coarseRank[$0] } ?? 0)
        guard fineUp || coarseUp else { return nil }
        progress.fine = max(fine, progress.fine)
        if coarseUp { progress.coarse = coarse }
        let value: CoarseConversionValue?
        switch progress.coarse {
        case "low": value = .low
        case "medium": value = .medium
        case "high": value = .high
        default: value = nil
        }
        return (progress.fine, value)
    }

    private static func number(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
}
