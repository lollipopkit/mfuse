import Foundation
import os.log

/// Cross-process storage for connection configurations.
/// Uses files inside the App Group container so both the app and File Provider extension
/// can read/write connection data reliably.
public final class SharedStorage: Sendable {

    private nonisolated(unsafe) let legacyDefaults: UserDefaults?
    private static let logger = Logger(
        subsystem: "com.lollipopkit.mfuse",
        category: "SharedStorage"
    )

    /// The shared container URL for databases and file storage.
    public let containerURL: URL

    public init(
        legacyDefaults: UserDefaults? = nil,
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupConstants.groupIdentifier
        )
    ) {
        self.legacyDefaults = legacyDefaults
        if let containerURL {
            self.containerURL = containerURL
        } else {
            // Fallback for testing
            self.containerURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MFuseShared")
        }
        ensureDirectories()
    }

    public static func withLegacyMigration(
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupConstants.groupIdentifier
        )
    ) -> SharedStorage {
        SharedStorage(
            legacyDefaults: UserDefaults(suiteName: AppGroupConstants.groupIdentifier),
            containerURL: containerURL
        )
    }

    // MARK: - Connections

    public func loadConnections() -> [ConnectionConfig] {
        if let data = try? Data(contentsOf: connectionsFileURL),
           let connections = try? JSONDecoder().decode([ConnectionConfig].self, from: data) {
            return connections
        }

        guard let data = legacyDefaults?.data(forKey: AppGroupConstants.connectionsKey),
              let connections = try? JSONDecoder().decode([ConnectionConfig].self, from: data) else {
            return []
        }

        persistConnections(connections)
        return connections
    }

    public func saveConnections(_ connections: [ConnectionConfig]) {
        persistConnections(connections)
    }

    /// Find a single connection by its domain identifier.
    public func connection(forDomain domainID: String) -> ConnectionConfig? {
        loadConnections().first { $0.domainIdentifier == domainID }
    }

    // MARK: - Database Paths

    public var metadataCachePath: String {
        databasesURL.appendingPathComponent(AppGroupConstants.metadataCacheDB).path
    }

    public var syncAnchorStorePath: String {
        databasesURL.appendingPathComponent(AppGroupConstants.syncAnchorDB).path
    }

    // MARK: - Temporary Files

    public func temporaryFileURL(for identifier: String, extension ext: String = "tmp") -> URL {
        let dir = cachesURL.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(identifier).\(ext)")
    }

    // MARK: - Private

    var connectionsFileURL: URL {
        applicationSupportURL.appendingPathComponent("connections.json")
    }

    private var databasesURL: URL {
        applicationSupportURL.appendingPathComponent(AppGroupConstants.databasesDir, isDirectory: true)
    }

    private var applicationSupportURL: URL {
        containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MFuse", isDirectory: true)
    }

    private var cachesURL: URL {
        containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("MFuse", isDirectory: true)
    }

    private func ensureDirectories() {
        try? FileManager.default.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: databasesURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cachesURL, withIntermediateDirectories: true)
    }

    private func persistConnections(_ connections: [ConnectionConfig]) {
        do {
            ensureDirectories()
            var coordinationError: NSError?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(writingItemAt: connectionsFileURL, options: .forReplacing, error: &coordinationError) { coordinatedURL in
                do {
                    let latestConnections = self.readConnectionsFromDisk(at: coordinatedURL)
                    let mergedConnections = self.mergeConnections(latest: latestConnections, incoming: connections)
                    let data = try JSONEncoder().encode(mergedConnections)
                    try data.write(to: coordinatedURL, options: .atomic)
                } catch {
                    Self.logger.error(
                        "Failed to persist connections to \(coordinatedURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
            }

            if let coordinationError {
                throw coordinationError
            }
        } catch {
            Self.logger.error(
                "Failed to persist connections to \(self.connectionsFileURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func readConnectionsFromDisk(at url: URL) -> [ConnectionConfig] {
        guard let data = try? Data(contentsOf: url),
              let connections = try? JSONDecoder().decode([ConnectionConfig].self, from: data) else {
            return []
        }
        return connections
    }

    private func mergeConnections(
        latest: [ConnectionConfig],
        incoming: [ConnectionConfig]
    ) -> [ConnectionConfig] {
        _ = latest
        return incoming
    }
}
