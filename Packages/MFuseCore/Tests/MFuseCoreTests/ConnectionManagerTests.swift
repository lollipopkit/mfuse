import XCTest
@testable import MFuseCore

// MARK: - Mock CredentialProvider

final class MockCredentialProvider: @unchecked Sendable, CredentialProvider {
    var credentials: [UUID: Credential] = [:]
    var deletedConnectionIDs: [UUID] = []
    var storedConnectionIDs: [UUID] = []
    var deleteError: Error?
    var storeError: Error?
    var deleteRemovesCredentialBeforeThrow = false

    func credential(for connectionID: UUID) async throws -> Credential? {
        credentials[connectionID]
    }

    func store(_ credential: Credential, for connectionID: UUID) async throws {
        storedConnectionIDs.append(connectionID)
        if let storeError {
            throw storeError
        }
        credentials[connectionID] = credential
    }

    func delete(for connectionID: UUID) async throws {
        deletedConnectionIDs.append(connectionID)
        if deleteRemovesCredentialBeforeThrow {
            credentials.removeValue(forKey: connectionID)
        }
        if let deleteError {
            throw deleteError
        }
        credentials.removeValue(forKey: connectionID)
    }
}

// MARK: - Mock RemoteFileSystem

actor MockFileSystem: RemoteFileSystem {
    var isConnected: Bool = false
    var connectCalled = false
    var connectCallCount = 0
    var connectDelayNanoseconds: UInt64 = 0
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

    func setConnectDelay(nanoseconds: UInt64) {
        connectDelayNanoseconds = nanoseconds
    }

    func connect() async throws {
        connectCalled = true
        connectCallCount += 1
        if connectDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: connectDelayNanoseconds)
        }
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
    var registeredDomainIDs: Set<String> = []
    var disconnectedDomainIDs: Set<String> = []
    var ensureRegisteredInvocations: [String] = []
    var unregisterInvocations: [String] = []
    var reconnectInvocations: [String] = []
    var disconnectInvocations: [String] = []
    var signalInvocations: [String] = []
    var mountURLs: [String: URL] = [:]
    var createSymlinkInvocations: [String] = []
    var removeSymlinkInvocations: [String] = []
    var removedDomains: [String] = []
    var nilMountURLCounts: [String: Int] = [:]
    var staleDomainsRemoved: [String] = []
    var unmountShouldFail = false
    var unregisterShouldFail = false
    var removeSymlinkShouldFail = false

    init(symlinkBaseURL: URL) {
        self.symlinkBaseURL = symlinkBaseURL
    }

    func setDomainStates(_ states: [RegisteredDomainState]) {
        registeredDomainIDs = Set(states.map(\.identifier))
        disconnectedDomainIDs = Set(
            states.filter(\.isDisconnected).map(\.identifier)
        )
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

    func setUnregisterShouldFail(_ shouldFail: Bool) {
        unregisterShouldFail = shouldFail
    }

    func setRemoveSymlinkShouldFail(_ shouldFail: Bool) {
        removeSymlinkShouldFail = shouldFail
    }

    func ensureRegistered(config: ConnectionConfig) async throws {
        ensureRegisteredInvocations.append(config.domainIdentifier)
        registeredDomainIDs.insert(config.domainIdentifier)
    }

    func unregister(config: ConnectionConfig) async throws {
        guard registeredDomainIDs.contains(config.domainIdentifier) else {
            throw MountError.domainNotFound(config.domainIdentifier)
        }
        unregisterInvocations.append(config.domainIdentifier)
        if unregisterShouldFail {
            throw MountError.unmountFailed("mock unmount failure")
        }
        registeredDomainIDs.remove(config.domainIdentifier)
        disconnectedDomainIDs.remove(config.domainIdentifier)
        removedDomains.append(config.domainIdentifier)
    }

    func reconnect(config: ConnectionConfig) async throws {
        reconnectInvocations.append(config.domainIdentifier)
        guard registeredDomainIDs.contains(config.domainIdentifier) else {
            throw MountError.domainNotFound(config.domainIdentifier)
        }
        disconnectedDomainIDs.remove(config.domainIdentifier)
    }

    func disconnect(config: ConnectionConfig) async throws {
        guard registeredDomainIDs.contains(config.domainIdentifier) else {
            throw MountError.domainNotFound(config.domainIdentifier)
        }
        disconnectInvocations.append(config.domainIdentifier)
        if unmountShouldFail {
            throw MountError.unmountFailed("mock unmount failure")
        }
        disconnectedDomainIDs.insert(config.domainIdentifier)
    }

    func domainStates() async throws -> [RegisteredDomainState] {
        registeredDomainIDs.map {
            RegisteredDomainState(
                identifier: $0,
                isDisconnected: disconnectedDomainIDs.contains($0)
            )
        }
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

    func testRemoveConnectionRestoresStateWhenCredentialDeletionFails() async throws {
        let config = ConnectionConfig(
            name: "ToRestore",
            backendType: .sftp,
            host: "example.com"
        )
        try manager.add(config)
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        credentialProvider.deleteError = RemoteFileSystemError.operationFailed("mock delete failure")

        do {
            try await manager.remove(config)
            XCTFail("Expected remove to fail when credential deletion fails")
        } catch {
            // Expected
        }

        XCTAssertEqual(manager.connections, [config])
        XCTAssertEqual(manager.state(for: config.id), .disconnected)
        XCTAssertEqual(try storage.loadConnections(), [config])
        XCTAssertEqual(credentialProvider.credentials[config.id], Credential(password: "pass"))
        XCTAssertEqual(credentialProvider.deletedConnectionIDs, [config.id])
    }

    func testRemoveConnectionRestoresCredentialWhenDeleteFailsAfterRemovingIt() async throws {
        let config = ConnectionConfig(
            name: "RestoreCredential",
            backendType: .sftp,
            host: "example.com"
        )
        let credential = Credential(password: "pass")
        try manager.add(config)
        credentialProvider.credentials[config.id] = credential
        credentialProvider.deleteRemovesCredentialBeforeThrow = true
        credentialProvider.deleteError = RemoteFileSystemError.operationFailed("mock delete failure")

        do {
            try await manager.remove(config)
            XCTFail("Expected remove to fail when credential deletion fails")
        } catch {
            // Expected
        }

        XCTAssertEqual(manager.connections, [config])
        XCTAssertEqual(try storage.loadConnections(), [config])
        XCTAssertEqual(credentialProvider.credentials[config.id], credential)
        XCTAssertEqual(credentialProvider.deletedConnectionIDs, [config.id])
        XCTAssertEqual(credentialProvider.storedConnectionIDs, [config.id])
    }

    func testRemoveConnectionReportsCredentialRestoreFailureWhenDeleteFails() async throws {
        let config = ConnectionConfig(
            name: "RestoreCredentialFailure",
            backendType: .sftp,
            host: "example.com"
        )
        let credential = Credential(password: "pass")
        try manager.add(config)
        credentialProvider.credentials[config.id] = credential
        credentialProvider.deleteRemovesCredentialBeforeThrow = true
        credentialProvider.deleteError = RemoteFileSystemError.operationFailed("mock delete failure")
        credentialProvider.storeError = RemoteFileSystemError.operationFailed("mock store failure")

        do {
            try await manager.remove(config)
            XCTFail("Expected remove to fail when credential restoration fails")
        } catch let error as RemoteFileSystemError {
            guard case .operationFailed(let message) = error else {
                return XCTFail("Expected operationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains(config.id.uuidString))
            XCTAssertTrue(message.contains("mock delete failure"))
            XCTAssertTrue(message.contains("mock store failure"))
        } catch {
            XCTFail("Expected operationFailed, got \(error)")
        }

        XCTAssertEqual(manager.connections, [config])
        XCTAssertEqual(try storage.loadConnections(), [config])
        XCTAssertNil(credentialProvider.credentials[config.id])
        XCTAssertEqual(credentialProvider.deletedConnectionIDs, [config.id])
        XCTAssertEqual(credentialProvider.storedConnectionIDs, [config.id])
    }

    func testRemoveConnectionCleansUpErroredResidualFileSystem() async throws {
        let config = ConnectionConfig(
            name: "ResidualCleanup",
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

        guard case .error = manager.state(for: config.id) else {
            return XCTFail("Expected error state after failed disconnect")
        }
        XCTAssertNotNil(manager.fileSystem(for: config.id))

        await fileSystem.setDisconnectShouldFail(false)
        try await manager.remove(config)

        XCTAssertTrue(manager.connections.isEmpty)
        XCTAssertNil(manager.fileSystem(for: config.id))
        let isConnected = await fileSystem.isConnected
        XCTAssertFalse(isConnected)
        XCTAssertNil(credentialProvider.credentials[config.id])
    }

    func testRemoveConnectionAbortsWhenCleanupRemainsIncomplete() async throws {
        let config = ConnectionConfig(
            name: "CleanupFailure",
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

        do {
            try await manager.remove(config)
            XCTFail("Expected remove to fail when disconnect cleanup is incomplete")
        } catch let error as ConnectionManagerError {
            XCTAssertEqual(error, .cleanupFailed(config.id))
        } catch {
            XCTFail("Expected cleanupFailed error, got \(error)")
        }

        XCTAssertEqual(manager.connections, [config])
        guard case .error = manager.state(for: config.id) else {
            return XCTFail("Expected error state after failed cleanup")
        }
        XCTAssertNotNil(manager.fileSystem(for: config.id))
        XCTAssertEqual(credentialProvider.credentials[config.id], Credential(password: "pass"))
        XCTAssertTrue(credentialProvider.deletedConnectionIDs.isEmpty)
        XCTAssertEqual(try storage.loadConnections(), [config])
    }

    func testRemoveConnectionAbortsWhenUnmountLeavesMountStateError() async throws {
        let config = ConnectionConfig(
            name: "UnmountCleanupFailure",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mounted-remove-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        _ = await waitForMountState(config.id)
        await mountProvider.setUnmountShouldFail(true)

        do {
            try await manager.remove(config)
            XCTFail("Expected remove to fail when mount cleanup leaves error state")
        } catch let error as ConnectionManagerError {
            XCTAssertEqual(error, .cleanupFailed(config.id))
        } catch {
            XCTFail("Expected cleanupFailed error, got \(error)")
        }

        XCTAssertEqual(manager.connections, [config])
        guard case .error = manager.state(for: config.id) else {
            return XCTFail("Expected connection error state after failed unmount cleanup")
        }
        guard case .error(let message) = manager.mountState(for: config.id) else {
            return XCTFail("Expected mount error state after failed unmount cleanup")
        }
        XCTAssertTrue(message.contains("mock unmount failure"))
        XCTAssertNil(manager.fileSystem(for: config.id))
        XCTAssertEqual(credentialProvider.credentials[config.id], Credential(password: "pass"))
        XCTAssertTrue(credentialProvider.deletedConnectionIDs.isEmpty)
        XCTAssertEqual(try storage.loadConnections(), [config])
    }

    func testRemoveConnectionSucceedsWhenDomainAlreadyMissing() async throws {
        let config = ConnectionConfig(
            name: "MissingDomainRemoval",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        await mountProvider.setDomainStates([])

        try await manager.remove(config)

        XCTAssertTrue(manager.connections.isEmpty)
        XCTAssertNil(manager.fileSystem(for: config.id))
        XCTAssertNil(credentialProvider.credentials[config.id])
        XCTAssertTrue(try storage.loadConnections().isEmpty)
    }

    func testReloadConnectionsFromStorageSkipsCleanupWhenReloadFails() async throws {
        let config = ConnectionConfig(
            name: "ReloadFailure",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)
        await manager.connect(config.id)
        guard let fileSystem = lastCreatedFileSystem else {
            return XCTFail("Expected file system to be created")
        }

        try Data("not-json".utf8).write(to: storage.connectionsFileURL, options: .atomic)

        await manager.reloadConnectionsFromStorage()

        XCTAssertEqual(manager.connections, [config])
        XCTAssertEqual(manager.state(for: config.id), .connected)
        XCTAssertNotNil(manager.fileSystem(for: config.id))
        let disconnectCalled = await fileSystem.disconnectCalled
        XCTAssertFalse(disconnectCalled)
    }

    func testReloadConnectionsFromStoragePreservesRuntimeStateWhenDisconnectCleanupFails() async throws {
        let config = ConnectionConfig(
            name: "ReloadCleanupFailure",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)
        await manager.connect(config.id)
        guard let fileSystem = lastCreatedFileSystem else {
            return XCTFail("Expected file system to be created")
        }
        await fileSystem.setDisconnectShouldFail(true)
        try storage.saveConnections([])

        await manager.reloadConnectionsFromStorage()

        XCTAssertEqual(manager.connections, [config])
        guard case .error(let message) = manager.state(for: config.id) else {
            return XCTFail("Expected connection error state after failed cleanup during reload")
        }
        XCTAssertTrue(message.contains("mock disconnect failure"))
        XCTAssertNotNil(manager.fileSystem(for: config.id))
        let disconnectCalled = await fileSystem.disconnectCalled
        XCTAssertTrue(disconnectCalled)
    }

    func testReloadConnectionsFromStorageUnregistersRemovedDomainAfterCleanup() async throws {
        let config = ConnectionConfig(
            name: "ReloadRemoved",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)
        await manager.connect(config.id)
        try storage.saveConnections([])

        await manager.reloadConnectionsFromStorage()

        XCTAssertFalse(manager.connections.contains(where: { $0.id == config.id }))
        let unregisterInvocations = await mountProvider.unregisterInvocations
        XCTAssertEqual(unregisterInvocations, [config.domainIdentifier])
        let domainStates = try await mountProvider.domainStates()
        XCTAssertTrue(domainStates.isEmpty)
    }

    func testReloadConnectionsFromStoragePreservesRuntimeStateWhenUnregisterFails() async throws {
        let config = ConnectionConfig(
            name: "ReloadUnregisterFailure",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)
        await manager.connect(config.id)
        await mountProvider.setUnregisterShouldFail(true)
        try storage.saveConnections([])

        await manager.reloadConnectionsFromStorage()

        XCTAssertEqual(manager.connections, [config])
        XCTAssertEqual(manager.state(for: config.id), .disconnected)
        let unregisterInvocations = await mountProvider.unregisterInvocations
        XCTAssertEqual(unregisterInvocations, [config.domainIdentifier])
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

    func testConnectSkipsConcurrentAttemptForSameID() async throws {
        let config = ConnectionConfig(
            name: "Concurrent",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let fileSystem = MockFileSystem()
        await fileSystem.setConnectDelay(nanoseconds: 200_000_000)
        lastCreatedFileSystem = fileSystem
        registry.register(.sftp) { _, _ in
            fileSystem
        }
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        async let first: Void = manager.connect(config.id)
        async let second: Void = manager.connect(config.id)
        _ = await (first, second)

        XCTAssertEqual(manager.state(for: config.id), .connected)
        XCTAssertNotNil(manager.fileSystem(for: config.id))
        let connectCallCount = await fileSystem.connectCallCount
        XCTAssertEqual(connectCallCount, 1)
    }

    func testConnectInterruptedByDisconnect() async throws {
        let config = ConnectionConfig(
            name: "Interrupted",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let fileSystem = MockFileSystem()
        await fileSystem.setConnectDelay(nanoseconds: 200_000_000)
        lastCreatedFileSystem = fileSystem
        registry.register(.sftp) { _, _ in
            fileSystem
        }
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        let connectTask = Task { @MainActor in
            await manager.connect(config.id)
        }

        for _ in 0..<50 {
            if await fileSystem.connectCallCount == 1 {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let initialConnectCallCount = await fileSystem.connectCallCount
        XCTAssertEqual(initialConnectCallCount, 1)
        await manager.disconnect(config.id)
        _ = await connectTask.value

        XCTAssertEqual(manager.state(for: config.id), .disconnected)
        XCTAssertNil(manager.fileSystem(for: config.id))
        let connectCallCount = await fileSystem.connectCallCount
        XCTAssertEqual(connectCallCount, 1)
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

    func testDisconnectTreatsMissingDomainAsAlreadyCleanedUp() async throws {
        let config = ConnectionConfig(
            name: "MissingDomain",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        await mountProvider.setDomainStates([])
        await manager.disconnect(config.id)

        XCTAssertEqual(manager.state(for: config.id), .disconnected)
        XCTAssertEqual(manager.mountState(for: config.id), .unmounted)
        XCTAssertNil(manager.fileSystem(for: config.id))
    }

    func testSyncSavedConnectionRegistrationKeepsPreregisteredDomainUnmounted() async throws {
        let config = ConnectionConfig(
            name: "saved",
            backendType: .sftp,
            host: "example.com"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        manager.mountProvider = mountProvider
        try manager.add(config)

        try await manager.syncSavedConnectionRegistration(config, previousConfig: nil)

        XCTAssertEqual(manager.effectiveMountState(for: config.id), .unmounted)
        let domainStates = try await mountProvider.domainStates()
        XCTAssertEqual(
            domainStates,
            [RegisteredDomainState(identifier: config.domainIdentifier, isDisconnected: true)]
        )
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

    func testTestConnectionEnumeratesConfiguredRemotePath() async {
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
        let expectedPaths: [RemotePath] = [
            config.remotePath.isEmpty ? .root : RemotePath(config.remotePath)
        ]
        XCTAssertEqual(paths, expectedPaths)
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
        await mountProvider.setDomainStates([
            RegisteredDomainState(identifier: config.domainIdentifier, isDisconnected: false)
        ])
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
        await mountProvider.setDomainStates([
            RegisteredDomainState(identifier: config.domainIdentifier, isDisconnected: false),
            RegisteredDomainState(identifier: orphanDomainID, isDisconnected: false)
        ])
        let orphanSymlinkURL = testSymlinkBaseURL.appendingPathComponent("orphan-\(UUID().uuidString)")
        let orphanTargetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("CloudStorage", isDirectory: true)
            .appendingPathComponent("MFuse-Orphan", isDirectory: true)
        try? FileManager.default.createDirectory(at: testSymlinkBaseURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: orphanTargetURL, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(
            atPath: orphanSymlinkURL.path,
            withDestinationPath: orphanTargetURL.path
        )
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: orphanSymlinkURL.path))
        manager.mountProvider = mountProvider
        manager.staleDomainRemover = { domainID in
            await mountProvider.recordStaleDomainRemoval(domainID)
        }
        try manager.add(config)

        await manager.syncMounts()

        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: orphanSymlinkURL.path))
        let removedDomains = await mountProvider.staleDomainsRemoved
        XCTAssertEqual(removedDomains, [orphanDomainID])
    }

    func testAutoMountConfiguredConnectionsMountsOnlyFlaggedConnections() async throws {
        let autoConfig = ConnectionConfig(
            name: "auto",
            backendType: .sftp,
            host: "auto.example.com",
            username: "user",
            autoMountOnLaunch: true
        )
        let manualConfig = ConnectionConfig(
            name: "manual",
            backendType: .sftp,
            host: "manual.example.com",
            username: "user",
            autoMountOnLaunch: false
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let autoMountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-mounted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: autoMountURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        await mountProvider.setMountURL(autoMountURL, for: autoConfig.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[autoConfig.id] = Credential(password: "pass")
        credentialProvider.credentials[manualConfig.id] = Credential(password: "pass")
        try manager.add(autoConfig)
        try manager.add(manualConfig)

        await manager.autoMountConfiguredConnections()

        let mountedState = await waitForMountState(autoConfig.id)
        XCTAssertEqual(mountedState, .mounted(path: autoMountURL.path))
        XCTAssertEqual(manager.state(for: manualConfig.id), .disconnected)
        XCTAssertEqual(manager.mountState(for: manualConfig.id), .unmounted)
        let reconnectInvocations = await mountProvider.reconnectInvocations
        XCTAssertEqual(reconnectInvocations, [autoConfig.domainIdentifier])
    }

    func testAutoMountConfiguredConnectionsReconnectsDisconnectedRegisteredDomain() async throws {
        let config = ConnectionConfig(
            name: "auto-registered",
            backendType: .sftp,
            host: "auto.example.com",
            username: "user",
            autoMountOnLaunch: true
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-registered-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        await mountProvider.setDomainStates([
            RegisteredDomainState(identifier: config.domainIdentifier, isDisconnected: true)
        ])
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        XCTAssertEqual(manager.effectiveMountState(for: config.id), .unmounted)

        await manager.autoMountConfiguredConnections()

        let mountedState = await waitForMountState(config.id)
        XCTAssertEqual(mountedState, .mounted(path: mountURL.path))
        let reconnectInvocations = await mountProvider.reconnectInvocations
        XCTAssertEqual(reconnectInvocations, [config.domainIdentifier])
    }

    func testDisconnectKeepsDomainRegisteredButRemovesSymlink() async throws {
        let config = ConnectionConfig(
            name: "registered",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("disconnect-registered-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        _ = await waitForMountState(config.id)

        let symlinkURL = testSymlinkBaseURL
            .appendingPathComponent(FileProviderMountProvider.symlinkFilename(for: config))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlinkURL.path))

        await manager.disconnect(config.id)

        XCTAssertEqual(manager.mountState(for: config.id), .unmounted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: symlinkURL.path))
        let domainStates = try await mountProvider.domainStates()
        XCTAssertEqual(
            domainStates,
            [RegisteredDomainState(identifier: config.domainIdentifier, isDisconnected: true)]
        )
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
