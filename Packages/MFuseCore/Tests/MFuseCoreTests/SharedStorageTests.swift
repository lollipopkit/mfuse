import XCTest
@testable import MFuseCore

private final class InMemoryCredentialProvider: @unchecked Sendable, CredentialProvider {
    var credentials: [UUID: Credential] = [:]

    func credential(for connectionID: UUID) async throws -> Credential? {
        credentials[connectionID]
    }

    func store(_ credential: Credential, for connectionID: UUID) async throws {
        credentials[connectionID] = credential
    }

    func delete(for connectionID: UUID) async throws {
        credentials.removeValue(forKey: connectionID)
    }
}

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

    func testLoadConnectionsDefaultsAutoMountOnLaunchToFalseForLegacyData() throws {
        let rawJSON = """
        [
          {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "legacy",
            "backendType": "sftp",
            "host": "legacy.example.com",
            "port": 22,
            "username": "lk",
            "authMethod": "password",
            "remotePath": "/",
            "parameters": {}
          }
        ]
        """

        let storage = SharedStorage(
            legacyDefaults: legacyDefaults,
            containerURL: containerURL
        )
        try FileManager.default.createDirectory(
            at: storage.connectionsFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Data(rawJSON.utf8).write(to: storage.connectionsFileURL, options: .atomic)

        let configs = storage.loadConnections()

        XCTAssertEqual(configs.count, 1)
        XCTAssertFalse(configs[0].autoMountOnLaunch)
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

    func testSharedCredentialStorePersistsAndDeletesCredentials() throws {
        let store = SharedCredentialStore(containerURL: containerURL)
        let connectionID = UUID()
        let credential = Credential(
            password: "secret",
            privateKey: Data("key".utf8),
            passphrase: "passphrase",
            accessKeyID: "access",
            secretAccessKey: "secret-key",
            token: "token"
        )

        try store.store(credential, for: connectionID)

        XCTAssertEqual(try store.credential(for: connectionID), credential)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.credentialURL(for: connectionID).path))

        try store.delete(for: connectionID)

        XCTAssertNil(try store.credential(for: connectionID))
    }

    func testSharedCredentialStoreReadDoesNotCreateDirectory() throws {
        let store = SharedCredentialStore(containerURL: containerURL)
        let connectionID = UUID()
        let credentialsDirectory = containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MFuse", isDirectory: true)
            .appendingPathComponent("Credentials", isDirectory: true)

        XCTAssertNil(try store.credential(for: connectionID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: credentialsDirectory.path))
    }

    func testSharedCredentialStoreMigratesLegacyCredentialFileIntoKeychain() throws {
        let store = SharedCredentialStore(containerURL: containerURL)
        let connectionID = UUID()
        let credential = Credential(password: "legacy-secret", token: "legacy-token")
        let legacyURL = try store.credentialURL(for: connectionID)

        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try JSONEncoder().encode(credential).write(to: legacyURL, options: .atomic)

        XCTAssertEqual(try store.credential(for: connectionID), credential)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testMirroredCredentialProviderBackfillsMirrorFromPrimary() async throws {
        let primary = InMemoryCredentialProvider()
        let sharedStore = SharedCredentialStore(containerURL: containerURL)
        let provider = MirroredCredentialProvider(primary: primary, sharedStore: sharedStore)
        let connectionID = UUID()
        let credential = Credential(password: "primary-only")
        try await primary.store(credential, for: connectionID)

        let resolved = try await provider.credential(for: connectionID)

        XCTAssertEqual(resolved, credential)
        XCTAssertEqual(try sharedStore.credential(for: connectionID), credential)
    }

    func testMirroredCredentialProviderPrefersPrimaryAndRepairsMirror() async throws {
        let primary = InMemoryCredentialProvider()
        let sharedStore = SharedCredentialStore(containerURL: containerURL)
        let provider = MirroredCredentialProvider(primary: primary, sharedStore: sharedStore)
        let connectionID = UUID()
        let primaryCredential = Credential(token: "fresh-token")
        let mirroredCredential = Credential(token: "stale-token")
        try sharedStore.store(mirroredCredential, for: connectionID)
        try await primary.store(primaryCredential, for: connectionID)

        let resolved = try await provider.credential(for: connectionID)
        let repairedMirror = try sharedStore.credential(for: connectionID)

        XCTAssertEqual(resolved, primaryCredential)
        XCTAssertEqual(repairedMirror, primaryCredential)
    }

    func testMirroredCredentialProviderFallsBackToMirrorWhenPrimaryMissing() async throws {
        let primary = InMemoryCredentialProvider()
        let sharedStore = SharedCredentialStore(containerURL: containerURL)
        let provider = MirroredCredentialProvider(primary: primary, sharedStore: sharedStore)
        let connectionID = UUID()
        let mirroredCredential = Credential(token: "mirror-only")
        try sharedStore.store(mirroredCredential, for: connectionID)

        let resolved = try await provider.credential(for: connectionID)
        let primaryCredential = try await primary.credential(for: connectionID)

        XCTAssertEqual(resolved, mirroredCredential)
        XCTAssertNil(primaryCredential)
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

    func testBootstrapUserInfoCorruptedPayloadReturnsNil() throws {
        let corruptedUserInfo: [AnyHashable: Any] = [
            FileProviderDomainStateStore.bootstrapUserInfoKey: Data("not-json".utf8)
        ]

        XCTAssertNil(try FileProviderDomainStateStore.loadBootstrapConfig(from: corruptedUserInfo))
    }

    func testProviderStateStorageURLUsesAppGroupApplicationSupportLayout() throws {
        let stateURL = try FileProviderDomainStateStore.providerStateStorageURL(
            containerURL: containerURL,
            domainIdentifier: "test-domain"
        )

        XCTAssertEqual(
            stateURL,
            containerURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("MFuse", isDirectory: true)
                .appendingPathComponent("FileProviderState", isDirectory: true)
                .appendingPathComponent("test-domain", isDirectory: true)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
    }

    @available(macOS 15.0, *)
    func testPrepareManagedDirectoryURLCreatesDirectoryDirectly() throws {
        let managedURL = containerURL
            .appendingPathComponent("Library/Containers/com.lollipopkit.mfuse.provider/Data/tmp", isDirectory: true)

        let preparedURL = try FileProviderDomainStateStore.prepareManagedDirectoryURL(managedURL)

        XCTAssertEqual(preparedURL, managedURL)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    @available(macOS 15.0, *)
    func testPrepareManagedDirectoryURLAllowsNil() throws {
        XCTAssertNil(try FileProviderDomainStateStore.prepareManagedDirectoryURL(nil))
    }
#endif
}
