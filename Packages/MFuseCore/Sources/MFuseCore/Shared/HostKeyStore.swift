import Foundation
import os.log

/// Persists SSH host key fingerprints for Trust-On-First-Use (TOFU) validation.
/// Stored in the App Group container so both the app and File Provider extension share
/// the same known-hosts database.
public final class HostKeyStore: Sendable {

    private nonisolated(unsafe) let legacyDefaults: UserDefaults?
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.lollipopkit.mfuse.host-key-store")
    private static let storeKey = "com.lollipopkit.mfuse.knownHostKeys"
    private static let logger = Logger(
        subsystem: "com.lollipopkit.mfuse",
        category: "HostKeyStore"
    )

    public init(
        fileURL: URL? = nil,
        legacyDefaults: UserDefaults? = nil
    ) {
        self.legacyDefaults = legacyDefaults
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = SharedStorage(
                legacyDefaults: legacyDefaults
            )
            .containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MFuse", isDirectory: true)
            .appendingPathComponent("known_hosts.json")
        }
    }

    /// Return the stored fingerprint for a host:port pair, or nil if first connection.
    public func knownFingerprint(for host: String, port: Int) -> String? {
        queue.sync {
            let dict = loadStore()
            return dict["\(host):\(port)"]
        }
    }

    /// Store a fingerprint for a host:port pair.
    public func store(fingerprint: String, for host: String, port: Int) {
        queue.sync {
            var dict = loadStore()
            dict["\(host):\(port)"] = fingerprint
            persist(dict)
        }
    }

    /// Remove the stored fingerprint for a host:port pair.
    public func remove(for host: String, port: Int) {
        queue.sync {
            var dict = loadStore()
            dict.removeValue(forKey: "\(host):\(port)")
            persist(dict)
        }
    }

    private func loadStore() -> [String: String] {
        if let data = try? Data(contentsOf: fileURL),
           let store = try? JSONDecoder().decode([String: String].self, from: data) {
            return store
        }

        let store = legacyDefaults?.dictionary(forKey: Self.storeKey) as? [String: String] ?? [:]
        if !store.isEmpty {
            persist(store)
        }
        return store
    }

    private func persist(_ store: [String: String]) {
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            let data = try JSONEncoder().encode(store)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error(
                "Failed to persist host key store at \(self.fileURL.path, privacy: .public) via directory \(directoryURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}
