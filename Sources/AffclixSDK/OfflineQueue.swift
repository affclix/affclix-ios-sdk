import Foundation

/// Requests that failed for a transient reason, kept in a file in Application
/// Support and resent at the next start or return to the foreground. Entries
/// are resent byte for byte, so the MMP drops a duplicate by event_id. Capped
/// at `capacity` (oldest dropped); an entry is dropped after `maxAttempts`
/// failed resends. Not thread-safe: the core uses it from its serial queue.
///
/// On iOS the file is protected until the device's first unlock after boot
/// (`completeUntilFirstUserAuthentication`) and excluded from backups.
final class OfflineQueue {
    struct Entry: Codable, Equatable {
        let id: UUID
        let request: PreparedRequest
        var attempts: Int
    }

    private let fileURL: URL
    private let capacity: Int
    private let maxAttempts: Int
    private(set) var entries: [Entry]

    init(directory: URL, capacity: Int = 500, maxAttempts: Int = 10) {
        self.fileURL = directory.appendingPathComponent("affclix_queue.json")
        self.capacity = capacity
        self.maxAttempts = maxAttempts
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
    }

    /// The default location: Application Support/Affclix.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Affclix", isDirectory: true)
    }

    @discardableResult
    func enqueue(_ request: PreparedRequest) -> Bool {
        entries.append(Entry(id: UUID(), request: request, attempts: 0))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        return persist()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    /// Counts a failed resend; drops the entry once it has failed too often.
    func markFailed(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].attempts += 1
        if entries[i].attempts >= maxAttempts {
            entries.remove(at: i)
        }
        persist()
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            let data = try JSONEncoder().encode(entries)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try data.write(to: fileURL, options: options)
            #if os(iOS)
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            #endif
            return true
        } catch {
            Log.error("offline queue write failed: \(error)")
            return false
        }
    }
}
