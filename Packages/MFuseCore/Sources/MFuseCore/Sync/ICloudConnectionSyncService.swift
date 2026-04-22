import Foundation
import os.log

public struct ICloudSyncAvailability: Sendable, Equatable {
    public let isDriveAvailable: Bool
    public let isKeychainAvailable: Bool
    public let unavailableReasons: [String]

    public var canEnableSync: Bool {
        isDriveAvailable && isKeychainAvailable
    }

    public init(
        isDriveAvailable: Bool,
        isKeychainAvailable: Bool,
        unavailableReasons: [String]
    ) {
        self.isDriveAvailable = isDriveAvailable
        self.isKeychainAvailable = isKeychainAvailable
        self.unavailableReasons = unavailableReasons
    }
}

public struct ICloudConnectionRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public var config: ConnectionConfig?
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID,
        config: ConnectionConfig?,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.config = config
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var eventDate: Date {
        deletedAt ?? updatedAt
    }
}

public struct ICloudConnectionRecordSet: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var records: [ICloudConnectionRecord]

    public init(schemaVersion: Int = 1, records: [ICloudConnectionRecord]) {
        self.schemaVersion = schemaVersion
        self.records = records
    }
}

public struct ICloudConnectionSyncResult: Sendable, Equatable {
    public let records: ICloudConnectionRecordSet
    public let liveConnections: [ConnectionConfig]
    public let didUpdateLocalSnapshot: Bool
}

public actor ICloudConnectionSyncService {
    private static let logger = Logger(
        subsystem: "com.lollipopkit.mfuse",
        category: "ICloudConnectionSyncService"
    )

    private let storage: SharedStorage
    private let fileManager: FileManager
    private let ubiquityContainerURLProvider: @Sendable () -> URL?
    private let keychainAvailabilityProbe: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let connectionSaver: @Sendable ([ConnectionConfig]) throws -> Void

    public init(
        storage: SharedStorage,
        fileManager: FileManager = .default,
        ubiquityContainerURLProvider: @escaping @Sendable () -> URL? = {
            FileManager.default.url(
                forUbiquityContainerIdentifier: AppGroupConstants.ubiquityContainerIdentifier
            )
        },
        keychainAvailabilityProbe: @escaping @Sendable () -> Bool = {
            KeychainService.isSynchronizableKeychainAvailable()
        },
        now: @escaping @Sendable () -> Date = { Date() },
        connectionSaver: (@Sendable ([ConnectionConfig]) throws -> Void)? = nil
    ) {
        self.storage = storage
        self.fileManager = fileManager
        self.ubiquityContainerURLProvider = ubiquityContainerURLProvider
        self.keychainAvailabilityProbe = keychainAvailabilityProbe
        self.now = now
        self.connectionSaver = connectionSaver ?? { connections in
            try storage.saveConnections(connections)
        }
    }

    public func availability() -> ICloudSyncAvailability {
        let hasDrive = ubiquityContainerURLProvider() != nil
        let hasKeychain = keychainAvailabilityProbe()
        var reasons: [String] = []

        if !hasDrive {
            reasons.append("iCloud Drive is unavailable for MFuse.")
        }
        if !hasKeychain {
            reasons.append("iCloud Keychain is unavailable for MFuse.")
        }

        return ICloudSyncAvailability(
            isDriveAvailable: hasDrive,
            isKeychainAvailable: hasKeychain,
            unavailableReasons: reasons
        )
    }

    public func synchronize() throws -> ICloudConnectionSyncResult {
        guard let cloudRootURL = ubiquityContainerURLProvider() else {
            throw NSError(
                domain: "ICloudConnectionSyncService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "iCloud Drive is unavailable for MFuse."]
            )
        }

        let localConnections = storage.loadConnections()
        let localRecords = try readRecordSet(at: localStateFileURL)
        let cloudRecords = try readRecordSet(at: cloudRecordsFileURL(in: cloudRootURL))
        let materializedLocalRecords = materializeLocalRecordSet(
            liveConnections: localConnections,
            base: localRecords
        )
        let mergedRecordSet = merge(local: materializedLocalRecords, cloud: cloudRecords)
        let mergedConnections = liveConnections(from: mergedRecordSet)
        let didUpdateLocalSnapshot = mergedConnections != localConnections
        let cloudURL = cloudRecordsFileURL(in: cloudRootURL)

        do {
            try writeRecordSet(mergedRecordSet, to: cloudURL)
            try writeRecordSet(mergedRecordSet, to: localStateFileURL)
            if didUpdateLocalSnapshot {
                try connectionSaver(mergedConnections)
            }
        } catch {
            rollbackRecordSet(
                cloudRecords,
                at: cloudURL,
                description: "cloud iCloud connection records"
            )
            rollbackRecordSet(
                localRecords,
                at: localStateFileURL,
                description: "local iCloud connection state"
            )
            throw error
        }

        return ICloudConnectionSyncResult(
            records: mergedRecordSet,
            liveConnections: mergedConnections,
            didUpdateLocalSnapshot: didUpdateLocalSnapshot
        )
    }

    public func markCurrentStateAsBaseline() throws {
        let snapshot = ICloudConnectionRecordSet(
            records: storage.loadConnections().map {
                ICloudConnectionRecord(id: $0.id, config: $0, updatedAt: now())
            }
        )
        try writeRecordSet(snapshot, to: localStateFileURL)
    }

    public func merge(
        local: ICloudConnectionRecordSet,
        cloud: ICloudConnectionRecordSet?
    ) -> ICloudConnectionRecordSet {
        var mergedByID: [UUID: ICloudConnectionRecord] = [:]
        for record in local.records {
            mergedByID[record.id] = record
        }

        for record in cloud?.records ?? [] {
            guard let existing = mergedByID[record.id] else {
                mergedByID[record.id] = record
                continue
            }
            if record.eventDate >= existing.eventDate {
                mergedByID[record.id] = record
            }
        }

        let records = mergedByID.values.sorted { lhs, rhs in
            if lhs.eventDate == rhs.eventDate {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.eventDate < rhs.eventDate
        }
        return ICloudConnectionRecordSet(records: records)
    }

    private var localStateFileURL: URL {
        storage.containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MFuse", isDirectory: true)
            .appendingPathComponent("iCloud", isDirectory: true)
            .appendingPathComponent("connections-sync-state.json")
    }

    private func cloudRecordsFileURL(in cloudRootURL: URL) -> URL {
        cloudRootURL
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("MFuse", isDirectory: true)
            .appendingPathComponent("connections-records.json")
    }

    private func materializeLocalRecordSet(
        liveConnections: [ConnectionConfig],
        base: ICloudConnectionRecordSet?
    ) -> ICloudConnectionRecordSet {
        let liveByID = Dictionary(uniqueKeysWithValues: liveConnections.map { ($0.id, $0) })
        var recordsByID = Dictionary(
            uniqueKeysWithValues: (base?.records ?? []).map { ($0.id, $0) }
        )
        let timestamp = now()

        for (id, config) in liveByID {
            if let existing = recordsByID[id] {
                if existing.deletedAt != nil || existing.config != config {
                    recordsByID[id] = ICloudConnectionRecord(
                        id: id,
                        config: config,
                        updatedAt: timestamp,
                        deletedAt: nil
                    )
                } else {
                    recordsByID[id] = existing
                }
            } else {
                recordsByID[id] = ICloudConnectionRecord(
                    id: id,
                    config: config,
                    updatedAt: timestamp,
                    deletedAt: nil
                )
            }
        }

        for (id, existing) in recordsByID where liveByID[id] == nil && existing.deletedAt == nil {
            recordsByID[id] = ICloudConnectionRecord(
                id: id,
                config: existing.config,
                updatedAt: existing.updatedAt,
                deletedAt: timestamp
            )
        }

        let records = recordsByID.values.sorted { lhs, rhs in
            if lhs.eventDate == rhs.eventDate {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.eventDate < rhs.eventDate
        }
        return ICloudConnectionRecordSet(records: records)
    }

    private func liveConnections(from recordSet: ICloudConnectionRecordSet) -> [ConnectionConfig] {
        recordSet.records.compactMap { record in
            guard record.deletedAt == nil else {
                return nil
            }
            return record.config
        }
    }

    private func readRecordSet(at url: URL) throws -> ICloudConnectionRecordSet? {
        var coordinationError: NSError?
        var readError: Error?
        var recordSet: ICloudConnectionRecordSet?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                let data = try Data(contentsOf: coordinatedURL)
                recordSet = try JSONDecoder().decode(ICloudConnectionRecordSet.self, from: data)
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain,
                   nsError.code == NSFileReadNoSuchFileError {
                    recordSet = nil
                    return
                }
                readError = error
            }
        }

        if let coordinationError {
            Self.logger.error(
                "Failed to coordinate reading iCloud records from \(url.path, privacy: .public): \(String(describing: coordinationError), privacy: .public)"
            )
            throw coordinationError
        }
        if let readError {
            Self.logger.error(
                "Failed to read iCloud records from \(url.path, privacy: .public): \(String(describing: readError), privacy: .public)"
            )
            throw readError
        }
        return recordSet
    }

    private func writeRecordSet(_ recordSet: ICloudConnectionRecordSet, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var coordinationError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                let data = try JSONEncoder().encode(recordSet)
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let coordinationError {
            Self.logger.error(
                "Failed to coordinate writing iCloud records to \(url.path, privacy: .public): \(String(describing: coordinationError), privacy: .public)"
            )
            throw coordinationError
        }
        if let writeError {
            Self.logger.error(
                "Failed to write iCloud records to \(url.path, privacy: .public): \(String(describing: writeError), privacy: .public)"
            )
            throw writeError
        }
    }

    private func rollbackRecordSet(
        _ previousRecordSet: ICloudConnectionRecordSet?,
        at url: URL,
        description: String
    ) {
        do {
            if let previousRecordSet {
                try writeRecordSet(previousRecordSet, to: url)
            } else {
                try deleteRecordSet(at: url)
            }
        } catch {
            Self.logger.error(
                "Failed to rollback \(description, privacy: .public) at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func deleteRecordSet(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        var coordinationError: NSError?
        var deleteError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            do {
                try fileManager.removeItem(at: coordinatedURL)
            } catch {
                deleteError = error
            }
        }

        if let coordinationError {
            Self.logger.error(
                "Failed to coordinate deleting iCloud records at \(url.path, privacy: .public): \(String(describing: coordinationError), privacy: .public)"
            )
            throw coordinationError
        }
        if let deleteError {
            Self.logger.error(
                "Failed to delete iCloud records at \(url.path, privacy: .public): \(String(describing: deleteError), privacy: .public)"
            )
            throw deleteError
        }
    }
}
