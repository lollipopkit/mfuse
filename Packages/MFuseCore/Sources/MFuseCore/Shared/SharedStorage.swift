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
        allowFallbackToTemporaryDirectory: Bool = false,
        createDirectoriesOnInit: Bool = true,
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupConstants.groupIdentifier
        )
    ) {
        self.legacyDefaults = legacyDefaults
        if let containerURL {
            self.containerURL = containerURL
        } else if allowFallbackToTemporaryDirectory {
            self.containerURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MFuseShared")
        } else {
            preconditionFailure(
                "SharedStorage failed to resolve App Group container for \(AppGroupConstants.groupIdentifier). " +
                "Pass allowFallbackToTemporaryDirectory: true only for tests, or inject an explicit containerURL."
            )
        }
        if createDirectoriesOnInit {
            do {
                try ensureDirectories()
            } catch {
                preconditionFailure(
                    "SharedStorage failed to create storage directories under \(self.containerURL.path): \(error)"
                )
            }
        }
    }

    public static func withLegacyMigration(
        allowFallbackToTemporaryDirectory: Bool = false,
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupConstants.groupIdentifier
        )
    ) -> SharedStorage {
        SharedStorage(
            legacyDefaults: UserDefaults(suiteName: AppGroupConstants.groupIdentifier),
            allowFallbackToTemporaryDirectory: allowFallbackToTemporaryDirectory,
            containerURL: containerURL
        )
    }

    // MARK: - Connections

    public func loadConnections() -> [ConnectionConfig] {
        let connectionsFileExists = FileManager.default.fileExists(atPath: connectionsFileURL.path)
        if let connections = readConnectionsFromDisk(at: connectionsFileURL) {
            return connections
        }
        guard !connectionsFileExists else {
            return []
        }

        guard let data = legacyDefaults?.data(forKey: AppGroupConstants.connectionsKey),
              let connections = try? JSONDecoder().decode([ConnectionConfig].self, from: data) else {
            return []
        }

        try? persistConnections(connections)
        return connections
    }

    public func saveConnections(_ connections: [ConnectionConfig]) throws {
        try persistConnections(connections)
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

    private func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: databasesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cachesURL, withIntermediateDirectories: true)
    }

    private func persistConnections(_ connections: [ConnectionConfig]) throws {
        do {
            try ensureDirectories()
            var coordinationError: NSError?
            var writeError: Error?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(writingItemAt: connectionsFileURL, options: .forReplacing, error: &coordinationError) { coordinatedURL in
                do {
                    let latestConnections = try self.decodeConnectionsFromDisk(at: coordinatedURL) ?? []
                    let mergedConnections = self.mergeConnections(latest: latestConnections, incoming: connections)
                    let data = try JSONEncoder().encode(mergedConnections)
                    try data.write(to: coordinatedURL, options: .atomic)
                } catch {
                    writeError = error
                    Self.logger.error(
                        "Failed to persist connections to \(coordinatedURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
            }

            if let coordinationError {
                throw coordinationError
            }
            if let writeError {
                throw writeError
            }
        } catch {
            Self.logger.error(
                "Failed to persist connections to \(self.connectionsFileURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    private func readConnectionsFromDisk(at url: URL) -> [ConnectionConfig]? {
        var coordinationError: NSError?
        var readError: Error?
        var connections: [ConnectionConfig]?
        let coordinator = NSFileCoordinator()

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                connections = try self.decodeConnectionsFromDisk(at: coordinatedURL)
            } catch {
                readError = error
            }
        }

        if let coordinationError {
            Self.logger.error(
                "Failed to coordinate reading connections from \(url.path, privacy: .public): \(String(describing: coordinationError), privacy: .public)"
            )
            return nil
        }

        if let readError {
            Self.logger.error(
                "Failed to read connections from \(url.path, privacy: .public): \(String(describing: readError), privacy: .public)"
            )
            return nil
        }

        return connections
    }

    private func decodeConnectionsFromDisk(at url: URL) throws -> [ConnectionConfig]? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try JSONDecoder().decode([ConnectionConfig].self, from: data)
    }

    private func mergeConnections(
        latest: [ConnectionConfig],
        incoming: [ConnectionConfig]
    ) -> [ConnectionConfig] {
        var mergedByID: [UUID: ConnectionConfig] = [:]

        for connection in latest {
            mergedByID[connection.id] = connection
        }

        for connection in incoming {
            mergedByID[connection.id] = connection
        }

        var merged = incoming
        let incomingIDs = Set(incoming.map(\.id))
        merged.append(contentsOf: latest.filter { !incomingIDs.contains($0.id) })
        return merged.filter { mergedByID.removeValue(forKey: $0.id) != nil }
    }
}
