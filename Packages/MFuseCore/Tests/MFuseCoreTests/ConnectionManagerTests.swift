import XCTest
@testable import MFuseCore

// MARK: - Mock CredentialProvider

final class MockCredentialProvider: @unchecked Sendable, CredentialProvider {
    var credentials: [UUID: Credential] = [:]
    var deletedConnectionIDs: [UUID] = []

    func credential(for connectionID: UUID) async throws -> Credential? {
        credentials[connectionID]
    }

    func store(_ credential: Credential, for connectionID: UUID) async throws {
        credentials[connectionID] = credential
    }

    func delete(for connectionID: UUID) async throws {
        deletedConnectionIDs.append(connectionID)
        credentials.removeValue(forKey: connectionID)
    }
}

// MARK: - Mock RemoteFileSystem

actor MockFileSystem: RemoteFileSystem {
    var isConnected: Bool = false
    var connectCalled = false
    var disconnectCalled = false
    var shouldFail = false
    var enumeratedPaths: [RemotePath] = []

    func connect() async throws {
        connectCalled = true
        if shouldFail {
            throw RemoteFileSystemError.connectionFailed("mock failure")
        }
        isConnected = true
    }

    func disconnect() async throws {
        disconnectCalled = true
        isConnected = false
    }

    func enumerate(at path: RemotePath) async throws -> [RemoteItem] {
        enumeratedPaths.append(path)
        return []
    }
    func itemInfo(at path: RemotePath) async throws -> RemoteItem {
        RemoteItem(path: path, type: .file)
    }
    func readFile(at path: RemotePath) async throws -> Data { Data() }
    func writeFile(at path: RemotePath, data: Data) async throws {}
    func createFile(at path: RemotePath, data: Data) async throws {}
    func createDirectory(at path: RemotePath) async throws {}
    func delete(at path: RemotePath) async throws {}
    func move(from source: RemotePath, to destination: RemotePath) async throws {}
}

enum MockFileSystemFactory {
    static var lastCreated: MockFileSystem?
}

// MARK: - Mock MountProvider

actor MockMountProvider: MountProvider {
    var mountedDomainIDs: [String] = []
    var mountInvocations: [String] = []
    var unmountInvocations: [String] = []
    var signalInvocations: [String] = []
    var mountURLs: [String: URL] = [:]
    var createSymlinkInvocations: [String] = []
    var removeSymlinkInvocations: [String] = []
    var removedDomains: [String] = []
    var nilMountURLCounts: [String: Int] = [:]
    var staleDomainsRemoved: [String] = []

    func setMountedDomainIDs(_ ids: [String]) {
        mountedDomainIDs = ids
    }

    func setMountURL(_ url: URL, for domainID: String) {
        mountURLs[domainID] = url
    }

    func setNilMountURLCount(_ count: Int, for domainID: String) {
        nilMountURLCounts[domainID] = count
    }

    func recordStaleDomainRemoval(_ domainID: String) {
        staleDomainsRemoved.append(domainID)
    }

    func mount(config: ConnectionConfig) async throws {
        mountInvocations.append(config.domainIdentifier)
        if !mountedDomainIDs.contains(config.domainIdentifier) {
            mountedDomainIDs.append(config.domainIdentifier)
        }
    }

    func unmount(config: ConnectionConfig) async throws {
        unmountInvocations.append(config.domainIdentifier)
        mountedDomainIDs.removeAll { $0 == config.domainIdentifier }
        removedDomains.append(config.domainIdentifier)
    }

    func mountedDomains() async throws -> [String] {
        mountedDomainIDs
    }

    func signalEnumerator(for config: ConnectionConfig) async throws {
        signalInvocations.append(config.domainIdentifier)
    }

    func mountURL(for config: ConnectionConfig) async throws -> URL? {
        if let remaining = nilMountURLCounts[config.domainIdentifier], remaining > 0 {
            nilMountURLCounts[config.domainIdentifier] = remaining - 1
            return nil
        }
        return mountURLs[config.domainIdentifier]
    }

    func createSymlink(for config: ConnectionConfig) async throws -> URL? {
        createSymlinkInvocations.append(config.domainIdentifier)
        guard let mountURL = mountURLs[config.domainIdentifier] else { return nil }
        let symlinkURL = FileProviderMountProvider.symlinkBaseURL
            .appendingPathComponent(FileProviderMountProvider.symlinkFilename(for: config))
        try? FileManager.default.removeItem(at: symlinkURL)
        try FileManager.default.createDirectory(
            at: FileProviderMountProvider.symlinkBaseURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: mountURL)
        return symlinkURL
    }

    func removeSymlink(for config: ConnectionConfig) async throws {
        removeSymlinkInvocations.append(config.domainIdentifier)
        let symlinkURL = FileProviderMountProvider.symlinkBaseURL
            .appendingPathComponent(FileProviderMountProvider.symlinkFilename(for: config))
        try? FileManager.default.removeItem(at: symlinkURL)
    }
}

// MARK: - Tests

@MainActor
final class ConnectionManagerTests: XCTestCase {

    private var storage: SharedStorage!
    private var credentialProvider: MockCredentialProvider!
    private var manager: ConnectionManager!
    private var legacyDefaults: UserDefaults!
    private var legacyDefaultsSuiteName: String!
    private var originalSymlinkBaseURL: URL!
    private var testSymlinkBaseURL: URL!
    private var testContainerURL: URL!

    override func setUp() {
        super.setUp()
        legacyDefaultsSuiteName = "MFuseCoreTests.\(UUID().uuidString)"
        legacyDefaults = UserDefaults(suiteName: legacyDefaultsSuiteName)
        legacyDefaults.removePersistentDomain(forName: legacyDefaultsSuiteName)
        testContainerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MFuseCoreStorage-\(UUID().uuidString)", isDirectory: true)
        storage = SharedStorage(
            legacyDefaults: legacyDefaults,
            containerURL: testContainerURL
        )
        try? storage.saveConnections([])
        credentialProvider = MockCredentialProvider()
        originalSymlinkBaseURL = FileProviderMountProvider.symlinkBaseURL
        testSymlinkBaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MFuseCoreTests-\(UUID().uuidString)", isDirectory: true)
        FileProviderMountProvider.symlinkBaseURL = testSymlinkBaseURL

        // Register mock backend
        BackendRegistry.shared.register(.sftp) { _, _ in
            let fs = MockFileSystem()
            MockFileSystemFactory.lastCreated = fs
            return fs
        }

        manager = ConnectionManager(
            storage: storage,
            credentialProvider: credentialProvider,
            registry: .shared
        )
    }

    override func tearDown() {
        try? storage.saveConnections([])
        MockFileSystemFactory.lastCreated = nil
        if let legacyDefaultsSuiteName {
            legacyDefaults?.removePersistentDomain(forName: legacyDefaultsSuiteName)
        }
        if let testContainerURL {
            try? FileManager.default.removeItem(at: testContainerURL)
        }
        if let testSymlinkBaseURL {
            try? FileManager.default.removeItem(at: testSymlinkBaseURL)
        }
        if let originalSymlinkBaseURL {
            FileProviderMountProvider.symlinkBaseURL = originalSymlinkBaseURL
        }
        super.tearDown()
    }

    func testAddConnection() throws {
        let config = ConnectionConfig(
            name: "Test",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        try manager.add(config)
        XCTAssertEqual(manager.connections.count, 1)
        XCTAssertEqual(manager.connections.first?.name, "Test")
        XCTAssertEqual(manager.state(for: config.id), .disconnected)
    }

    func testUpdateConnection() throws {
        var config = ConnectionConfig(
            name: "Original",
            backendType: .sftp,
            host: "example.com"
        )
        try manager.add(config)
        config.name = "Updated"
        try manager.update(config)
        XCTAssertEqual(manager.connections.first?.name, "Updated")
    }

    func testRemoveConnection() async throws {
        let config = ConnectionConfig(
            name: "ToRemove",
            backendType: .sftp,
            host: "example.com"
        )
        try manager.add(config)
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        XCTAssertEqual(manager.connections.count, 1)
        try await manager.remove(config)
        XCTAssertTrue(manager.connections.isEmpty)
        XCTAssertNil(credentialProvider.credentials[config.id])
        XCTAssertEqual(credentialProvider.deletedConnectionIDs, [config.id])
    }

    func testConnectSuccess() async throws {
        let config = ConnectionConfig(
            name: "Test",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        XCTAssertEqual(manager.state(for: config.id), .connected)
        XCTAssertNotNil(manager.fileSystem(for: config.id))
    }

    func testDisconnect() async throws {
        let config = ConnectionConfig(
            name: "Test",
            backendType: .sftp,
            host: "example.com"
        )
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        XCTAssertEqual(manager.state(for: config.id), .connected)

        await manager.disconnect(config.id)
        XCTAssertEqual(manager.state(for: config.id), .disconnected)
        XCTAssertNil(manager.fileSystem(for: config.id))
    }

    func testConnectUnsupportedBackend() async throws {
        let config = ConnectionConfig(
            name: "WebDAV",
            backendType: .webdav,
            host: "example.com"
        )
        try manager.add(config)

        await manager.connect(config.id)
        if case .error = manager.state(for: config.id) {
            // Expected
        } else {
            XCTFail("Should be in error state for unsupported backend")
        }
    }

    func testTestConnectionEnumeratesFromRoot() async {
        let config = ConnectionConfig(
            name: "Test",
            backendType: .sftp,
            host: "example.com",
            username: "user",
            remotePath: "/home/lk"
        )
        let credential = Credential(password: "pass")

        let result = await manager.testConnection(config, credential: credential)

        switch result {
        case .success:
            break
        case .failure(let error):
            XCTFail("Expected success, got \(error)")
        }

        guard let fs = MockFileSystemFactory.lastCreated else {
            XCTFail("MockFileSystemFactory.lastCreated is nil")
            return
        }
        let paths = await fs.enumeratedPaths
        XCTAssertEqual(paths, [.root])
    }

    func testConnectDoesNotReportMountedUntilMountURLIsReady() async throws {
        let config = ConnectionConfig(
            name: "tb",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider()
        let mountURL = FileManager.default.temporaryDirectory.appendingPathComponent("mounted-tb")
        try? Data().write(to: mountURL)
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        await mountProvider.setNilMountURLCount(5, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)

        XCTAssertEqual(manager.state(for: config.id), .connected)
        let mountedState = await waitForMountState(config.id)
        XCTAssertEqual(mountedState, .mounted(path: mountURL.path))
        let symlinkURL = testSymlinkBaseURL
            .appendingPathComponent(FileProviderMountProvider.symlinkFilename(for: config))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlinkURL.path))
    }

    func testSyncMountsRestoresMountedStateAndSymlink() async throws {
        let config = ConnectionConfig(
            name: "tb",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider()
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mounted-restore-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        await mountProvider.setMountedDomainIDs([config.domainIdentifier])
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        try manager.add(config)

        await manager.syncMounts()

        XCTAssertEqual(manager.state(for: config.id), .disconnected)
        XCTAssertNil(manager.fileSystem(for: config.id))
        let mountedState = await waitForMountState(config.id)
        XCTAssertEqual(mountedState, .mounted(path: mountURL.path))
        let symlinkURL = testSymlinkBaseURL
            .appendingPathComponent(FileProviderMountProvider.symlinkFilename(for: config))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlinkURL.path))
    }

    func testSyncMountsRemovesOrphanedDomainAndSymlink() async throws {
        let config = ConnectionConfig(
            name: "known",
            backendType: .sftp,
            host: "example.com"
        )
        let mountProvider = MockMountProvider()
        let orphanDomainID = UUID().uuidString
        await mountProvider.setMountedDomainIDs([config.domainIdentifier, orphanDomainID])
        let orphanSymlinkURL = testSymlinkBaseURL.appendingPathComponent("orphan-\(UUID().uuidString)")
        let orphanTargetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("CloudStorage", isDirectory: true)
            .appendingPathComponent("MFuse-Orphan", isDirectory: true)
        try? FileManager.default.createDirectory(at: testSymlinkBaseURL, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(
            atPath: orphanSymlinkURL.path,
            withDestinationPath: orphanTargetURL.path
        )
        manager.mountProvider = mountProvider
        manager.staleDomainRemover = { domainID in
            await mountProvider.recordStaleDomainRemoval(domainID)
        }
        try manager.add(config)

        await manager.syncMounts()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanSymlinkURL.path))
        let removedDomains = await mountProvider.staleDomainsRemoved
        XCTAssertEqual(removedDomains, [orphanDomainID])
    }

    private func waitForMountState(_ id: UUID) async -> MountState {
        for _ in 0..<30 {
            let state = manager.mountState(for: id)
            if case .mounting = state {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            return state
        }
        return manager.mountState(for: id)
    }
}
