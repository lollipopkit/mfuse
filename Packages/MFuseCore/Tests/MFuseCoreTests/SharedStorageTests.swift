import XCTest
@testable import MFuseCore

final class SharedStorageTests: XCTestCase {

    private var legacyDefaults: UserDefaults!
    private var legacyDefaultsSuiteName: String!
    private var containerURL: URL!

    override func setUp() {
        super.setUp()
        legacyDefaultsSuiteName = "MFuseCore.SharedStorageTests.\(UUID().uuidString)"
        legacyDefaults = UserDefaults(suiteName: legacyDefaultsSuiteName)
        legacyDefaults.removePersistentDomain(forName: legacyDefaultsSuiteName)
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedStorageTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let legacyDefaultsSuiteName {
            legacyDefaults?.removePersistentDomain(forName: legacyDefaultsSuiteName)
        }
        if let containerURL {
            try? FileManager.default.removeItem(at: containerURL)
        }
        super.tearDown()
    }

    func testSaveAndLoadConnectionsFromFileBackedStorage() throws {
        let storage = SharedStorage(
            legacyDefaults: legacyDefaults,
            containerURL: containerURL
        )
        let config = ConnectionConfig(
            name: "tb",
            backendType: .sftp,
            host: "example.com",
            username: "lk"
        )

        try storage.saveConnections([config])

        XCTAssertEqual(storage.loadConnections(), [config])
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.connectionsFileURL.path))
    }

    func testLoadConnectionsMigratesLegacyDefaultsIntoFile() throws {
        let config = ConnectionConfig(
            name: "legacy",
            backendType: .sftp,
            host: "legacy.example.com"
        )
        let data = try XCTUnwrap(try? JSONEncoder().encode([config]))
        legacyDefaults.set(data, forKey: AppGroupConstants.connectionsKey)

        let storage = SharedStorage(
            legacyDefaults: legacyDefaults,
            containerURL: containerURL
        )

        XCTAssertEqual(storage.loadConnections(), [config])
        let fileData = try Data(contentsOf: storage.connectionsFileURL)
        XCTAssertEqual(try JSONDecoder().decode([ConnectionConfig].self, from: fileData), [config])
    }

    func testLoadConnectionsIgnoresLegacyDefaultsWhenMigrationDisabled() throws {
        let config = ConnectionConfig(
            name: "legacy-disabled",
            backendType: .sftp,
            host: "legacy-disabled.example.com"
        )
        let data = try XCTUnwrap(try? JSONEncoder().encode([config]))
        legacyDefaults.set(data, forKey: AppGroupConstants.connectionsKey)

        let storage = SharedStorage(
            legacyDefaults: nil,
            containerURL: containerURL
        )

        XCTAssertEqual(storage.loadConnections(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.connectionsFileURL.path))
    }

    func testSharedStorageUsesStandardAppGroupSubdirectories() {
        let storage = SharedStorage(
            legacyDefaults: legacyDefaults,
            containerURL: containerURL
        )

        XCTAssertTrue(storage.metadataCachePath.contains("Library/Application Support/MFuse/Databases"))
        XCTAssertTrue(storage.syncAnchorStorePath.contains("Library/Application Support/MFuse/Databases"))
        XCTAssertTrue(storage.temporaryFileURL(for: "item").path.contains("Library/Caches/MFuse/tmp"))
    }

    func testHostKeyStorePersistsToFileAndMigratesLegacyDefaults() {
        let fileURL = containerURL.appendingPathComponent("known_hosts.json")
        let legacyKey = "com.lollipopkit.mfuse.knownHostKeys"
        legacyDefaults.set(["example.com:22": "fingerprint-1"], forKey: legacyKey)

        let store = HostKeyStore(
            fileURL: fileURL,
            legacyDefaults: legacyDefaults
        )

        XCTAssertEqual(store.knownFingerprint(for: "example.com", port: 22), "fingerprint-1")

        store.store(fingerprint: "fingerprint-2", for: "second.example.com", port: 2222)
        XCTAssertEqual(store.knownFingerprint(for: "second.example.com", port: 2222), "fingerprint-2")

        store.remove(for: "example.com", port: 22)
        XCTAssertNil(store.knownFingerprint(for: "example.com", port: 22))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

#if canImport(FileProvider)
    func testBootstrapUserInfoRoundTripsConnectionConfig() throws {
        let config = ConnectionConfig(
            name: "tb",
            backendType: .sftp,
            host: "192.168.31.57",
            username: "lk"
        )

        let userInfo = try FileProviderDomainStateStore.bootstrapUserInfo(for: config)

        XCTAssertEqual(
            try FileProviderDomainStateStore.loadBootstrapConfig(from: userInfo),
            config
        )
    }
#endif
}
