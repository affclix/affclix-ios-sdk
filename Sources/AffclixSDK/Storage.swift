import Foundation

/// The SDK's persisted state, in its own UserDefaults suite. iOS deletes it with
/// the app, so a reinstall starts over: new visitor ID, install reported again
/// (the MMP treats a reinstall within its window as the first install).
final class Storage {
    private let defaults: UserDefaults

    private enum Key {
        static let visitorID = "affclix_vid"
        static let installTime = "affclix_install_time_ms"
        static let installReported = "affclix_install_reported"
        static let clickID = "affclix_click_id"
        static let userID = "affclix_user_id"
        static let gdprApplies = "affclix_gdpr_applies"
        static let adUserData = "affclix_ad_user_data"
        static let adPersonalization = "affclix_ad_personalization"
        static let pushToken = "affclix_push_token"
        static let skanSchema = "affclix_skan_schema"
        static let skanSchemaFetchedAt = "affclix_skan_schema_fetched_at"
        static let skanProgress = "affclix_skan_progress"
        static let deferredChecked = "affclix_deferred_checked"
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The SDK's per-install ID (vid), created on first use.
    var visitorID: String {
        if let v = defaults.string(forKey: Key.visitorID), !v.isEmpty { return v }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: Key.visitorID)
        return id
    }

    /// First open, Unix milliseconds.
    var installTimeMs: Int64? {
        get { (defaults.object(forKey: Key.installTime) as? NSNumber)?.int64Value }
        set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: Key.installTime) }
    }

    /// The server has the install, or it is in the offline queue.
    var installReported: Bool {
        get { defaults.bool(forKey: Key.installReported) }
        set { defaults.set(newValue, forKey: Key.installReported) }
    }

    /// The first-launch deferred deep link lookup is over (found or not).
    var deferredChecked: Bool {
        get { defaults.bool(forKey: Key.deferredChecked) }
        set { defaults.set(newValue, forKey: Key.deferredChecked) }
    }

    /// Tracker click ID from the last deep link, sent with later events.
    var clickID: String? {
        get { defaults.string(forKey: Key.clickID) }
        set { defaults.set(newValue, forKey: Key.clickID) }
    }

    /// The push registration last accepted or queued: "hex token|sandbox".
    var pushToken: String? {
        get { defaults.string(forKey: Key.pushToken) }
        set { defaults.set(newValue, forKey: Key.pushToken) }
    }

    /// The SKAdNetwork conversion-value schema last fetched (nil: none).
    var skanSchema: SKANSchema? {
        get { defaults.data(forKey: Key.skanSchema).flatMap { try? JSONDecoder().decode(SKANSchema.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.skanSchema) }
    }

    /// When the schema was last asked for (seconds since 1970), answered or not.
    var skanSchemaFetchedAt: TimeInterval? {
        get { defaults.object(forKey: Key.skanSchemaFetchedAt) as? TimeInterval }
        set { defaults.set(newValue, forKey: Key.skanSchemaFetchedAt) }
    }

    /// The user's progress toward the schema's conversion values.
    var skanProgress: SKANProgress {
        get { defaults.data(forKey: Key.skanProgress).flatMap { try? JSONDecoder().decode(SKANProgress.self, from: $0) } ?? SKANProgress() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.skanProgress) }
    }

    var userID: String? {
        get { defaults.string(forKey: Key.userID) }
        set { defaults.set(newValue, forKey: Key.userID) }
    }

    /// Forgets the user's identifiers (visitor ID, click ID, user ID, push token,
    /// consent) but not the install state, so the next launch is not reported
    /// as a new install.
    func clearIdentifiers() {
        for key in [Key.visitorID, Key.clickID, Key.userID, Key.pushToken,
                    Key.gdprApplies, Key.adUserData, Key.adPersonalization] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Consent the app set explicitly. Stored as -1 (unset) / 0 / 1.
    var consent: ConsentData {
        get {
            func read(_ key: String) -> Bool? {
                switch defaults.object(forKey: key) as? Int {
                case 1: return true
                case 0: return false
                default: return nil
                }
            }
            return ConsentData(gdprApplies: read(Key.gdprApplies),
                               adUserData: read(Key.adUserData),
                               adPersonalization: read(Key.adPersonalization))
        }
        set {
            func code(_ b: Bool?) -> Int { b.map { $0 ? 1 : 0 } ?? -1 }
            defaults.set(code(newValue.gdprApplies), forKey: Key.gdprApplies)
            defaults.set(code(newValue.adUserData), forKey: Key.adUserData)
            defaults.set(code(newValue.adPersonalization), forKey: Key.adPersonalization)
        }
    }
}
