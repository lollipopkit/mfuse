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
    var connectCallCount = 0
    var disconnectCalled = false
    var shouldFail = false
    var connectFailures: [RemoteFileSystemError] = []
    var enumerateShouldFail = false
    var disconnectShouldFail = false
    var enumeratedPaths: [RemotePath] = []

    func setEnumerateShouldFail(_ shouldFail: Bool) {
        enumerateShouldFail = shouldFail
    }

    func setDisconnectShouldFail(_ shouldFail: Bool) {
        disconnectShouldFail = shouldFail
    }

    func setConnectFailures(_ failures: [RemoteFileSystemError]) {
        connectFailures = failures
    }

    func connect() async throws {
        connectCalled = true
        connectCallCount += 1
        if !connectFailures.isEmpty {
            throw connectFailures.removeFirst()
        }
        if shouldFail {
            throw RemoteFileSystemError.connectionFailed("mock failure")
        }
        isConnected = true
    }

    func disconnect() async throws {
        disconnectCalled = true
        if disconnectShouldFail {
            throw RemoteFileSystemError.operationFailed("mock disconnect failure")
        }
        isConnected = false
    }

    func enumerate(at path: RemotePath) async throws -> [RemoteItem] {
        enumeratedPaths.append(path)
        if enumerateShouldFail {
            throw RemoteFileSystemError.permissionDenied(path)
        }
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

// MARK: - Mock MountProvider

actor MockMountProvider: MountProvider {
    let symlinkBaseURL: URL
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
    var unmountShouldFail = false
    var removeSymlinkShouldFail = false

    init(symlinkBaseURL: URL) {
        self.symlinkBaseURL = symlinkBaseURL
    }

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

    func setUnmountShouldFail(_ shouldFail: Bool) {
        unmountShouldFail = shouldFail
    }

    func setRemoveSymlinkShouldFail(_ shouldFail: Bool) {
        removeSymlinkShouldFail = shouldFail
    }

    func mount(config: ConnectionConfig) async throws {
        mountInvocations.append(config.domainIdentifier)
        if !mountedDomainIDs.contains(config.domainIdentifier) {
            mountedDomainIDs.append(config.domainIdentifier)
        }
    }

    func unmount(config: ConnectionConfig) async throws {
        unmountInvocations.append(config.domainIdentifier)
        if unmountShouldFail {
            throw MountError.unmountFailed("mock unmount failure")
        }
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
        let symlinkURL = symlinkBaseURL
            .appendingPathComponent(FileProviderMountProvider.symlinkFilename(for: config))
        try? FileManager.default.removeItem(at: symlinkURL)
        try FileManager.default.createDirectory(
            at: symlinkBaseURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: mountURL)
        return symlinkURL
    }

    func removeSymlink(for config: ConnectionConfig) async throws {
        removeSymlinkInvocations.append(config.domainIdentifier)
        if removeSymlinkShouldFail {
            throw RemoteFileSystemError.operationFailed("mock remove symlink failure")
        }
        let symlinkURL = symlinkBaseURL
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
    private var testSymlinkBaseURL: URL!
    private var testContainerURL: URL!
    private var registry: BackendRegistry!
    private var lastCreatedFileSystem: MockFileSystem?

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
        testSymlinkBaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MFuseCoreTests-\(UUID().uuidString)", isDirectory: true)

        registry = BackendRegistry()
        registry.register(.sftp) { [weak self] _, _ in
            let fs = MockFileSystem()
            MainActor.assumeIsolated {
                self?.lastCreatedFileSystem = fs
            }
            return fs
        }

        manager = ConnectionManager(
            storage: storage,
            credentialProvider: credentialProvider,
            registry: registry
        )
    }

    override func tearDown() {
        try? storage.saveConnections([])
        lastCreatedFileSystem = nil
        registry = nil
        if let legacyDefaultsSuiteName {
            legacyDefaults?.removePersistentDomain(forName: legacyDefaultsSuiteName)
        }
        if let testContainerURL {
            try? FileManager.default.removeItem(at: testContainerURL)
        }
        if let testSymlinkBaseURL {
            try? FileManager.default.removeItem(at: testSymlinkBaseURL)
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

    func testConnectRetriesTransientNetworkFailure() async throws {
        let config = ConnectionConfig(
            name: "Retry",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let fileSystem = MockFileSystem()
        await fileSystem.setConnectFailures([
            .connectionFailed("No route to host")
        ])
        lastCreatedFileSystem = fileSystem
        registry.register(.sftp) { _, _ in
            fileSystem
        }
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)

        XCTAssertEqual(manager.state(for: config.id), .connected)
        XCTAssertNotNil(manager.fileSystem(for: config.id))
        let connectCallCount = await fileSystem.connectCallCount
        XCTAssertEqual(connectCallCount, 2)
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

    func testDisconnectReportsErrorWhenFileSystemDisconnectFails() async throws {
        let config = ConnectionConfig(
            name: "DisconnectFail",
            backendType: .sftp,
            host: "example.com"
        )
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        guard let fileSystem = lastCreatedFileSystem else {
            return XCTFail("Expected file system to be created")
        }
        await fileSystem.setDisconnectShouldFail(true)

        await manager.disconnect(config.id)

        guard case .error(let message) = manager.state(for: config.id) else {
            return XCTFail("Expected error state after disconnect failure")
        }
        XCTAssertTrue(message.contains("mock disconnect failure"))
        XCTAssertNotNil(manager.fileSystem(for: config.id))
    }

    func testDisconnectReportsErrorWhenUnmountFails() async throws {
        let config = ConnectionConfig(
            name: "UnmountFail",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        await mountProvider.setUnmountShouldFail(true)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        await manager.disconnect(config.id)

        guard case .error(let message) = manager.state(for: config.id) else {
            return XCTFail("Expected error state after unmount failure")
        }
        XCTAssertTrue(message.contains("mock unmount failure"))
        XCTAssertNil(manager.fileSystem(for: config.id))
        XCTAssertEqual(manager.mountState(for: config.id), .error(message))
    }

    func testReconnectSkipsConnectWhenAlreadyConnectedBeforeRetryFires() async throws {
        let config = ConnectionConfig(
            name: "ReconnectSkip",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let sharedFileSystem = MockFileSystem()
        lastCreatedFileSystem = sharedFileSystem
        registry.register(.sftp) { _, _ in
            sharedFileSystem
        }
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        manager.reconnect(config.id)
        await manager.connect(config.id)
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        XCTAssertEqual(manager.state(for: config.id), .connected)
        let connectCallCount = await sharedFileSystem.connectCallCount
        XCTAssertEqual(connectCallCount, 1)
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

        guard let fs = lastCreatedFileSystem else {
            XCTFail("lastCreatedFileSystem is nil")
            return
        }
        let paths = await fs.enumeratedPaths
        XCTAssertEqual(paths, [.root])
    }

    func testTestConnectionDisconnectsWhenEnumerationFails() async {
        let config = ConnectionConfig(
            name: "Test",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let credential = Credential(password: "pass")

        let fileSystem = MockFileSystem()
        await fileSystem.setEnumerateShouldFail(true)
        lastCreatedFileSystem = fileSystem
        registry.register(.sftp) { _, _ in
            return fileSystem
        }

        let result = await manager.testConnection(config, credential: credential)

        if case .success = result {
            XCTFail("Expected failure when enumeration fails")
        }
        let disconnectCalled = await fileSystem.disconnectCalled
        XCTAssertTrue(disconnectCalled)
    }

    func testConnectDoesNotReportMountedUntilMountURLIsReady() async throws {
        let config = ConnectionConfig(
            name: "tb",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let mountURL = FileManager.default.temporaryDirectory.appendingPathComponent("mounted-tb")
        try? Data().write(to: mountURL)
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        await mountProvider.setNilMountURLCount(5, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)

        XCTAssertEqual(manager.state(for: config.id), .disconnected)
        let mountedState = await waitForMountState(config.id)
        XCTAssertEqual(mountedState, .mounted(path: mountURL.path))
        XCTAssertEqual(manager.effectiveMountState(for: config.id), .mounted(path: mountURL.path))
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
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
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
        XCTAssertEqual(manager.effectiveMountState(for: config.id), .mounted(path: mountURL.path))
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
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
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
        let maxAttempts = 20
        let retryDelay: UInt64 = 500_000_000

        for _ in 0..<maxAttempts {
            let state = manager.mountState(for: id)
            if case .mounting = state {
                try? await Task.sleep(nanoseconds: retryDelay)
                continue
            }
            return state
        }
        return manager.mountState(for: id)
    }
}
