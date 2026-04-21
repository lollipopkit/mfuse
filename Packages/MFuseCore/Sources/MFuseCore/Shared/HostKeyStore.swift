import Foundation
import os.log
import Darwin

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
        legacyDefaults: UserDefaults? = UserDefaults(suiteName: AppGroupConstants.groupIdentifier)
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
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                clearTransientAttributesIfNeeded(at: fileURL)
                let data = try Data(contentsOf: fileURL)
                let decoded = try JSONDecoder().decode([String: String].self, from: data)
                persistToLegacyDefaults(decoded)
                return decoded
            } catch {
                if isAccessDenied(error) {
                    clearTransientAttributesIfNeeded(at: fileURL)
                    if let reloaded = tryDecodeStoreAfterMetadataRepair() {
                        persistToLegacyDefaults(reloaded)
                        return reloaded
                    }
                    Self.logger.error(
                        "Access denied reading host key store at \(self.fileURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                    return legacyDefaults?.dictionary(forKey: Self.storeKey) as? [String: String] ?? [:]
                }
                Self.logger.error(
                    "Failed to decode host key store at \(self.fileURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                backupCorruptStoreIfNeeded(using: fileManager)
            }
        }

        let store = legacyDefaults?.dictionary(forKey: Self.storeKey) as? [String: String] ?? [:]
        return store
    }

    private func persist(_ store: [String: String]) {
        persistToLegacyDefaults(store)
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            let data = try JSONEncoder().encode(store)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            clearTransientAttributesIfNeeded(at: directoryURL)
            clearTransientAttributesIfNeeded(at: fileURL)
            try data.write(to: fileURL, options: .atomic)
            clearTransientAttributesIfNeeded(at: fileURL)
        } catch {
            if isAccessDenied(error) {
                Self.logger.warning(
                    "Persisted host key store to app-group defaults after file access was denied at \(self.fileURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                return
            }
            Self.logger.error(
                "Failed to persist host key store at \(self.fileURL.path, privacy: .public) via directory \(directoryURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func persistToLegacyDefaults(_ store: [String: String]) {
        legacyDefaults?.set(store, forKey: Self.storeKey)
    }

    private func backupCorruptStoreIfNeeded(using fileManager: FileManager) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = fileURL.appendingPathExtension("corrupt.\(timestamp)")

        do {
            try fileManager.moveItem(at: fileURL, to: backupURL)
        } catch {
            Self.logger.error(
                "Failed to move corrupt host key store from \(self.fileURL.path, privacy: .public) to \(backupURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func isAccessDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileReadNoSuchFileError].contains(nsError.code) {
            return nsError.code != NSFileReadNoSuchFileError
        }

        if nsError.domain == NSPOSIXErrorDomain,
           [Int(EPERM), Int(EACCES)].contains(nsError.code) {
            return true
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           [Int(EPERM), Int(EACCES)].contains(underlying.code) {
            return true
        }

        return false
    }

    private func tryDecodeStoreAfterMetadataRepair() -> [String: String]? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private func clearTransientAttributesIfNeeded(at url: URL) {
        url.path.withCString { path in
            _ = removexattr(path, "com.apple.quarantine", 0)
            _ = removexattr(path, "com.apple.provenance", 0)
        }
    }
}
