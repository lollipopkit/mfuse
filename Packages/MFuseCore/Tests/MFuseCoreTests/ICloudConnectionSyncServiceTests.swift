import XCTest
@testable import MFuseCore

final class ICloudConnectionSyncServiceTests: XCTestCase {
    private final class DateBox: @unchecked Sendable {
        var value: Date

        init(_ value: Date) {
            self.value = value
        }
    }

    private final class BoolBox: @unchecked Sendable {
        var value: Bool

        init(_ value: Bool) {
            self.value = value
        }
    }

    private var containerURL: URL!
    private var cloudRootURL: URL!

    override func setUp() {
        super.setUp()
        SharedAppSettings.setICloudSyncEnabled(true)
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MFuseCoreICloudLocal-\(UUID().uuidString)", isDirectory: true)
        cloudRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MFuseCoreICloudCloud-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let containerURL {
            try? FileManager.default.removeItem(at: containerURL)
        }
        if let cloudRootURL {
            try? FileManager.default.removeItem(at: cloudRootURL)
        }
        SharedAppSettings.setICloudSyncEnabled(false)
        super.tearDown()
    }

    func testSynchronizeMergesLocalAndCloudOnFirstEnable() async throws {
        let storage = SharedStorage(containerURL: containerURL)
        let dateBox = DateBox(Date(timeIntervalSince1970: 1_000))
        let service = makeService(storage: storage, dateBox: dateBox)

        let localConfig = ConnectionConfig(
            name: "Local",
            backendType: .sftp,
            host: "local.example.com"
        )
        let cloudConfig = ConnectionConfig(
            name: "Cloud",
            backendType: .sftp,
            host: "cloud.example.com"
        )
        try storage.saveConnections([localConfig])
        try writeCloudRecordSet(
            ICloudConnectionRecordSet(records: [
                ICloudConnectionRecord(id: cloudConfig.id, config: cloudConfig, updatedAt: dateBox.value),
            ])
        )

        let result = try await service.synchronize()

        XCTAssertEqual(Set(result.liveConnections), Set([localConfig, cloudConfig]))
        XCTAssertEqual(Set(try storage.loadConnections()), Set([localConfig, cloudConfig]))
    }

    func testSynchronizePrefersNewerRecordForSameID() async throws {
        let storage = SharedStorage(containerURL: containerURL)
        let dateBox = DateBox(Date(timeIntervalSince1970: 1_000))
        let service = makeService(storage: storage, dateBox: dateBox)

        let connectionID = UUID()
        let localConfig = ConnectionConfig(
            id: connectionID,
            name: "Local",
            backendType: .sftp,
            host: "example.com"
        )
        let cloudConfig = ConnectionConfig(
            id: connectionID,
            name: "Cloud Newer",
            backendType: .sftp,
            host: "example.com"
        )

        try storage.saveConnections([localConfig])
        try await service.markCurrentStateAsBaseline()
        dateBox.value = Date(timeIntervalSince1970: 2_000)
        try writeCloudRecordSet(
            ICloudConnectionRecordSet(records: [
                ICloudConnectionRecord(id: connectionID, config: cloudConfig, updatedAt: dateBox.value),
            ])
        )

        let result = try await service.synchronize()

        XCTAssertEqual(result.liveConnections, [cloudConfig])
        XCTAssertEqual(try storage.loadConnections(), [cloudConfig])
    }

    func testSynchronizeWritesTombstoneSoDeletedConnectionDoesNotReappear() async throws {
        let storage = SharedStorage(containerURL: containerURL)
        let dateBox = DateBox(Date(timeIntervalSince1970: 1_000))
        let service = makeService(storage: storage, dateBox: dateBox)

        let config = ConnectionConfig(
            name: "Deleted",
            backendType: .sftp,
            host: "deleted.example.com"
        )

        try storage.saveConnections([config])
        try await service.markCurrentStateAsBaseline()

        try writeCloudRecordSet(
            ICloudConnectionRecordSet(records: [
                ICloudConnectionRecord(id: config.id, config: config, updatedAt: dateBox.value),
            ])
        )

        dateBox.value = Date(timeIntervalSince1970: 2_000)
        try storage.saveConnections([])

        let result = try await service.synchronize()
        let cloudRecordSet = try XCTUnwrap(readCloudRecordSet())
        let record = try XCTUnwrap(cloudRecordSet.records.first(where: { $0.id == config.id }))

        XCTAssertTrue(result.liveConnections.isEmpty)
        XCTAssertEqual(try storage.loadConnections(), [])
        XCTAssertEqual(record.deletedAt, dateBox.value)
        XCTAssertNil(record.config)
    }

    func testSynchronizeKeepsDuplicateEndpointsWhenIDsDiffer() async throws {
        let storage = SharedStorage(containerURL: containerURL)
        let dateBox = DateBox(Date(timeIntervalSince1970: 1_000))
        let service = makeService(storage: storage, dateBox: dateBox)

        let localConfig = ConnectionConfig(
            name: "Local",
            backendType: .sftp,
            host: "same.example.com",
            username: "lk"
        )
        let cloudConfig = ConnectionConfig(
            name: "Cloud",
            backendType: .sftp,
            host: "same.example.com",
            username: "lk"
        )

        try storage.saveConnections([localConfig])
        try writeCloudRecordSet(
            ICloudConnectionRecordSet(records: [
                ICloudConnectionRecord(id: cloudConfig.id, config: cloudConfig, updatedAt: dateBox.value),
            ])
        )

        let result = try await service.synchronize()

        XCTAssertEqual(result.liveConnections.count, 2)
        XCTAssertEqual(Set(result.liveConnections.map(\.id)), Set([localConfig.id, cloudConfig.id]))
    }

    func testSynchronizeRollsBackCloudAndLocalStateWhenPersistingConnectionsFails() async throws {
        let storage = SharedStorage(containerURL: containerURL)
        let dateBox = DateBox(Date(timeIntervalSince1970: 1_000))
        let localConfig = ConnectionConfig(
            name: "Local",
            backendType: .sftp,
            host: "local.example.com"
        )
        let cloudConfig = ConnectionConfig(
            name: "Cloud",
            backendType: .sftp,
            host: "cloud.example.com"
        )

        try storage.saveConnections([localConfig])
        let baselineService = makeService(storage: storage, dateBox: dateBox)
        try await baselineService.markCurrentStateAsBaseline()

        let previousLocalState = try XCTUnwrap(readLocalStateRecordSet())
        let previousCloudState = ICloudConnectionRecordSet(records: [
            ICloudConnectionRecord(id: cloudConfig.id, config: cloudConfig, updatedAt: dateBox.value),
        ])
        try writeCloudRecordSet(previousCloudState)

        let expectedError = NSError(domain: "ICloudConnectionSyncServiceTests", code: 99)
        let failingService = ICloudConnectionSyncService(
            storage: storage,
            ubiquityContainerURLProvider: { [cloudRootURL] in cloudRootURL },
            keychainAvailabilityProbe: { true },
            now: { dateBox.value },
            connectionSaver: { _ in
                throw expectedError
            }
        )

        do {
            _ = try await failingService.synchronize()
            XCTFail("Expected synchronize to fail when persisting merged connections fails")
        } catch {
            XCTAssertEqual((error as NSError).domain, expectedError.domain)
            XCTAssertEqual((error as NSError).code, expectedError.code)
        }

        XCTAssertEqual(try readCloudRecordSet(), previousCloudState)
        XCTAssertEqual(try readLocalStateRecordSet(), previousLocalState)
        XCTAssertEqual(try storage.loadConnections(), [localConfig])
    }

    func testSynchronizeRejectsLiveRecordWithoutConfig() async throws {
        let storage = SharedStorage(containerURL: containerURL)
        let dateBox = DateBox(Date(timeIntervalSince1970: 1_000))
        let service = makeService(storage: storage, dateBox: dateBox)
        let malformedID = UUID()

        try writeCloudRecordSet(
            ICloudConnectionRecordSet(records: [
                ICloudConnectionRecord(id: malformedID, config: nil, updatedAt: dateBox.value),
            ])
        )

        do {
            _ = try await service.synchronize()
            XCTFail("Expected synchronize to fail for a live iCloud record without config")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(malformedID.uuidString))
        }
    }

    func testSynchronizeRetriesWhenLocalConnectionsChangeBeforeWrite() async throws {
        let storage = SharedStorage(containerURL: containerURL)
        let dateBox = DateBox(Date(timeIntervalSince1970: 1_000))
        let didInjectConcurrentChange = BoolBox(false)
        let localConfig = ConnectionConfig(
            name: "Local",
            backendType: .sftp,
            host: "local.example.com"
        )
        let concurrentConfig = ConnectionConfig(
            name: "Concurrent",
            backendType: .sftp,
            host: "concurrent.example.com"
        )
        let cloudConfig = ConnectionConfig(
            name: "Cloud",
            backendType: .sftp,
            host: "cloud.example.com"
        )

        try storage.saveConnections([localConfig])
        try writeCloudRecordSet(
            ICloudConnectionRecordSet(records: [
                ICloudConnectionRecord(id: cloudConfig.id, config: cloudConfig, updatedAt: dateBox.value),
            ])
        )

        let service = ICloudConnectionSyncService(
            storage: storage,
            ubiquityContainerURLProvider: { [cloudRootURL] in cloudRootURL },
            keychainAvailabilityProbe: { true },
            now: { dateBox.value },
            beforeWritingAttempt: {
                guard !didInjectConcurrentChange.value else {
                    return
                }
                didInjectConcurrentChange.value = true
                try storage.saveConnections([localConfig, concurrentConfig])
            }
        )

        let result = try await service.synchronize()

        XCTAssertEqual(Set(result.liveConnections), Set([localConfig, concurrentConfig, cloudConfig]))
        XCTAssertEqual(Set(try storage.loadConnections()), Set([localConfig, concurrentConfig, cloudConfig]))
        XCTAssertTrue(didInjectConcurrentChange.value)
    }

    func testSynchronizeThrowsWhenICloudSyncIsDisabled() async throws {
        let storage = SharedStorage(containerURL: containerURL)
        let dateBox = DateBox(Date(timeIntervalSince1970: 1_000))
        let service = makeService(storage: storage, dateBox: dateBox)
        SharedAppSettings.setICloudSyncEnabled(false)

        do {
            _ = try await service.synchronize()
            XCTFail("Expected synchronize to fail when iCloud sync is disabled")
        } catch {
            XCTAssertEqual((error as NSError).domain, "ICloudConnectionSyncService")
            XCTAssertEqual((error as NSError).code, 0)
        }
    }

    private func makeService(
        storage: SharedStorage,
        dateBox: DateBox
    ) -> ICloudConnectionSyncService {
        ICloudConnectionSyncService(
            storage: storage,
            ubiquityContainerURLProvider: { [cloudRootURL] in cloudRootURL },
            keychainAvailabilityProbe: { true },
            now: { dateBox.value }
        )
    }

    private func writeCloudRecordSet(_ recordSet: ICloudConnectionRecordSet) throws {
        let url = cloudRecordsURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(recordSet)
        try data.write(to: url, options: .atomic)
    }

    private func readCloudRecordSet() throws -> ICloudConnectionRecordSet? {
        let url = cloudRecordsURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try JSONDecoder().decode(ICloudConnectionRecordSet.self, from: Data(contentsOf: url))
    }

    private func readLocalStateRecordSet() throws -> ICloudConnectionRecordSet? {
        let url = localStateURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try JSONDecoder().decode(ICloudConnectionRecordSet.self, from: Data(contentsOf: url))
    }

    private func cloudRecordsURL() -> URL {
        cloudRootURL
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("MFuse", isDirectory: true)
            .appendingPathComponent("connections-records.json")
    }

    private func localStateURL() -> URL {
        containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MFuse", isDirectory: true)
            .appendingPathComponent("iCloud", isDirectory: true)
            .appendingPathComponent("connections-sync-state.json")
    }
}
