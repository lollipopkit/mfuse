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
    var credentialLookupGate: TestGate?

    func credential(for connectionID: UUID) async throws -> Credential? {
        if let credentialLookupGate {
            await credentialLookupGate.wait()
        }
        return credentials[connectionID]
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

// MARK: - Test Gate

/// Holds a mock provider call at a chosen suspension point so a test can interleave
/// another operation with it.
actor TestGate {
    private var isOpen = false
    private var entered = false
    private var cancelledWaiterCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let pendingEntryWaiters = entryWaiters
        entryWaiters = []
        for continuation in pendingEntryWaiters {
            continuation.resume()
        }
        guard !isOpen else { return }
        // The call held here keeps running once the gate opens, exactly as it would
        // without cancellation — the handler only records that it arrived, which is what
        // lets a test see that the code under test has reached its cancel-and-await point.
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append($0) }
        } onCancel: {
            Task { await self.recordWaiterCancellation() }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    /// Wait until the call held here has been cancelled.
    ///
    /// A handshake, where yielding a fixed number of times only hopes: it resumes at the
    /// point where the code under test has cancelled this work and is awaiting it.
    func waitUntilWaiterCancelled() async {
        guard cancelledWaiterCount == 0 else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    private func recordWaiterCancellation() {
        cancelledWaiterCount += 1
        let pendingCancellationWaiters = cancellationWaiters
        cancellationWaiters = []
        for continuation in pendingCancellationWaiters {
            continuation.resume()
        }
    }

    func open() {
        isOpen = true
        let pendingWaiters = waiters
        waiters = []
        for continuation in pendingWaiters {
            continuation.resume()
        }
    }
}

// MARK: - Mock MountProvider

actor MockMountProvider: MountProvider {
    let symlinkBaseURL: URL
    var registeredDomainIDs: Set<String> = []
    var disconnectedDomainIDs: Set<String> = []
    var ensureRegisteredInvocations: [String] = []
    /// The configs, not just their ids: cleanup and rollback have to act on the same
    /// revision of a connection, and only the contents show which one they used.
    var ensureRegisteredConfigs: [ConnectionConfig] = []
    var unregisterInvocations: [String] = []
    var unregisterConfigs: [ConnectionConfig] = []
    var reconnectInvocations: [String] = []
    var disconnectInvocations: [String] = []
    var signalInvocations: [String] = []
    /// Provider calls in the order they *completed*, so a test can see work that ran
    /// while another call was still inside the provider.
    var operationLog: [String] = []
    var mountURLs: [String: URL] = [:]
    var createSymlinkInvocations: [String] = []
    var removeSymlinkInvocations: [String] = []
    var removedDomains: [String] = []
    var nilMountURLCounts: [String: Int] = [:]
    var staleDomainsRemoved: [String] = []
    var unmountShouldFail = false
    var unregisterShouldFail = false
    var signalShouldFail = false
    var removeSymlinkShouldFail = false
    var disconnectGate: TestGate?
    var createSymlinkGate: TestGate?
    var ensureRegisteredGate: TestGate?

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

    func setDisconnectGate(_ gate: TestGate?) {
        disconnectGate = gate
    }

    func setCreateSymlinkGate(_ gate: TestGate?) {
        createSymlinkGate = gate
    }

    func setEnsureRegisteredGate(_ gate: TestGate?) {
        ensureRegisteredGate = gate
    }

    /// Lets a test assert on what happened after a setup phase it does not care about.
    func clearInvocations() {
        operationLog = []
        ensureRegisteredInvocations = []
        ensureRegisteredConfigs = []
        unregisterInvocations = []
        unregisterConfigs = []
        reconnectInvocations = []
        disconnectInvocations = []
        signalInvocations = []
        createSymlinkInvocations = []
        removeSymlinkInvocations = []
    }

    func ensureRegistered(config: ConnectionConfig) async throws {
        ensureRegisteredInvocations.append(config.domainIdentifier)
        ensureRegisteredConfigs.append(config)
        if let ensureRegisteredGate {
            await ensureRegisteredGate.wait()
        }
        registeredDomainIDs.insert(config.domainIdentifier)
    }

    func unregister(config: ConnectionConfig) async throws {
        unregisterInvocations.append(config.domainIdentifier)
        unregisterConfigs.append(config)
        if unregisterShouldFail {
            throw MountError.unmountFailed("mock unmount failure")
        }
        registeredDomainIDs.remove(config.domainIdentifier)
        disconnectedDomainIDs.remove(config.domainIdentifier)
        removedDomains.append(config.domainIdentifier)
    }

    func reconnect(config: ConnectionConfig) async throws {
        guard registeredDomainIDs.contains(config.domainIdentifier) else {
            throw MountError.domainNotFound(config.domainIdentifier)
        }
        reconnectInvocations.append(config.domainIdentifier)
        disconnectedDomainIDs.remove(config.domainIdentifier)
        operationLog.append("reconnect")
    }

    func disconnect(config: ConnectionConfig) async throws {
        guard registeredDomainIDs.contains(config.domainIdentifier) else {
            throw MountError.domainNotFound(config.domainIdentifier)
        }
        disconnectInvocations.append(config.domainIdentifier)
        if let disconnectGate {
            await disconnectGate.wait()
        }
        if unmountShouldFail {
            throw MountError.unmountFailed("mock unmount failure")
        }
        disconnectedDomainIDs.insert(config.domainIdentifier)
        operationLog.append("disconnect")
    }

    func domainStates() async throws -> [RegisteredDomainState] {
        registeredDomainIDs.map {
            RegisteredDomainState(
                identifier: $0,
                isDisconnected: disconnectedDomainIDs.contains($0)
            )
        }
    }

    func setSignalShouldFail(_ shouldFail: Bool) {
        signalShouldFail = shouldFail
    }

    func signalEnumerator(for config: ConnectionConfig) async throws {
        signalInvocations.append(config.domainIdentifier)
        if signalShouldFail {
            throw MountError.domainNotFound(config.domainIdentifier)
        }
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
        if let createSymlinkGate {
            await createSymlinkGate.wait()
        }
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

    /// `remove` checks `isCleanupComplete` as soon as `disconnect` returns, so a caller
    /// that arrives while a teardown is already running has to wait for it — returning
    /// early would fail the removal of a connection that unmounts cleanly.
    func testRemoveWaitsForInFlightDisconnectBeforeCheckingCleanup() async throws {
        let config = ConnectionConfig(
            name: "OverlappingDisconnect",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mounted-overlap-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        _ = await waitForMountState(config.id)

        let gate = TestGate()
        await mountProvider.setDisconnectGate(gate)

        let firstDisconnect = Task { @MainActor in await manager.disconnect(config.id) }
        await gate.waitUntilEntered()

        let removal = Task { @MainActor in try await manager.remove(config) }
        // `remove` marks the id before it reaches the join with the in-flight teardown and
        // does not suspend in between, so this is the signal that it is waiting — rather
        // than yielding a fixed number of times and hoping.
        await waitUntilRemovalStarts(for: config.id)
        await gate.open()

        await firstDisconnect.value
        try await removal.value

        XCTAssertTrue(manager.connections.isEmpty)
        XCTAssertNil(manager.fileSystem(for: config.id))
        XCTAssertNil(credentialProvider.credentials[config.id])
        XCTAssertTrue(try storage.loadConnections().isEmpty)
        let disconnectInvocations = await mountProvider.disconnectInvocations
        XCTAssertEqual(disconnectInvocations, [config.domainIdentifier])
    }

    /// A mount repair suspended inside `createSymlink` must finish before the teardown
    /// removes the link, otherwise the link is recreated for a connection that is gone.
    func testDisconnectWaitsForSymlinkRepairBeforeRemovingTheSymlink() async throws {
        let config = ConnectionConfig(
            name: "RepairDuringTeardown",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mounted-repair-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        _ = await waitForMountState(config.id)

        let symlinkURL = testSymlinkBaseURL
            .appendingPathComponent(FileProviderMountProvider.symlinkFilename(for: config))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlinkURL.path))

        let gate = TestGate()
        await mountProvider.setCreateSymlinkGate(gate)

        let repair = Task { @MainActor in await manager.repairMountState(for: config.id) }
        await gate.waitUntilEntered()

        let disconnect = Task { @MainActor in await manager.disconnect(config.id) }
        // The teardown cancels the repair before it awaits it, so this resumes exactly
        // when the teardown is blocked on the gated `createSymlink` — the interleaving the
        // test is about. Yielding a fixed number of times instead let the whole test pass
        // on a schedule where the disconnect had not even started.
        await gate.waitUntilWaiterCancelled()
        let symlinkRemovalsBeforeTheRepairFinished = await mountProvider.removeSymlinkInvocations
        XCTAssertTrue(
            symlinkRemovalsBeforeTheRepairFinished.isEmpty,
            "the teardown removed the symlink while the repair was still inside createSymlink"
        )
        await gate.open()

        await repair.value
        await disconnect.value

        let symlinkRemovals = await mountProvider.removeSymlinkInvocations
        XCTAssertEqual(symlinkRemovals, [config.domainIdentifier])
        XCTAssertFalse(FileManager.default.fileExists(atPath: symlinkURL.path))
        XCTAssertEqual(manager.mountState(for: config.id), .unmounted)
        XCTAssertEqual(manager.state(for: config.id), .disconnected)
    }

    /// An edit remounts a connection so its domain serves the new config, but the user can
    /// unmount while the registration is still in flight. Deciding the remount from the
    /// state captured before it would bring back the mount they just took down.
    func testEditingAMountedConnectionDoesNotRemountAfterAConcurrentUnmount() async throws {
        let config = ConnectionConfig(
            name: "EditDuringUnmount",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mounted-edit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        _ = await waitForMountState(config.id)
        await mountProvider.clearInvocations()

        var edited = config
        edited.name = "EditDuringUnmountRenamed"
        let gate = TestGate()
        await mountProvider.setEnsureRegisteredGate(gate)
        let registration = Task { @MainActor in
            try await manager.syncSavedConnectionRegistration(edited, previousConfig: config)
        }
        await gate.waitUntilEntered()

        // Nothing the teardown needs is gated, so it runs to completion while the
        // registration is still suspended inside `ensureRegistered`.
        await manager.disconnect(config.id)
        await gate.open()
        try await registration.value

        XCTAssertEqual(manager.effectiveMountState(for: config.id), .unmounted)
        let reconnects = await mountProvider.reconnectInvocations
        XCTAssertTrue(reconnects.isEmpty, "the edit remounted a connection the user had unmounted")
    }

    /// A removal that finished while a save was in flight leaves nothing to update.
    /// Returning quietly told the editor the edit had been applied, and the credential the
    /// save had already written stayed behind for a connection nobody can see.
    func testUpdatingAConnectionThatIsGoneFails() throws {
        let config = ConnectionConfig(
            name: "AlreadyRemoved",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )

        XCTAssertThrowsError(try manager.update(config)) { error in
            XCTAssertEqual(error as? ConnectionManagerError, .connectionNotFound(config.id))
        }
        XCTAssertTrue(manager.connections.isEmpty)
        XCTAssertTrue(try storage.loadConnections().isEmpty)
    }

    /// Removal suspends between deleting the row and deleting its credential. A save
    /// landing in that window put the connection back after the deletion was persisted and
    /// then had its brand-new credential destroyed, leaving a row with no secret.
    func testSavingIsRejectedWhileRemovalIsInFlight() async throws {
        let config = ConnectionConfig(
            name: "SaveDuringRemoval",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mounted-save-removal-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        _ = await waitForMountState(config.id)

        let gate = TestGate()
        await mountProvider.setDisconnectGate(gate)
        let removal = Task { @MainActor in try await manager.remove(config) }
        await waitUntilRemovalStarts(for: config.id)

        var edited = config
        edited.name = "SaveDuringRemovalRenamed"
        XCTAssertThrowsError(try manager.update(edited)) { error in
            XCTAssertEqual(error as? ConnectionManagerError, .removalInProgress(config.id))
        }
        XCTAssertThrowsError(try manager.add(edited)) { error in
            XCTAssertEqual(error as? ConnectionManagerError, .removalInProgress(config.id))
        }

        await gate.open()
        try await removal.value

        XCTAssertTrue(manager.connections.isEmpty)
        XCTAssertTrue(try storage.loadConnections().isEmpty)
        XCTAssertNil(credentialProvider.credentials[config.id])
    }

    /// Quit-time cleanup carries a deadline per connection, so tearing them down one after
    /// another charged every connection behind a hanging backend another five seconds of
    /// quit. They are independent, so they run together and a hang costs only its own.
    func testShutdownTearsDownConnectionsConcurrently() async throws {
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        manager.mountProvider = mountProvider
        var configs: [ConnectionConfig] = []
        for index in 0..<2 {
            let config = ConnectionConfig(
                name: "ShutdownTarget\(index)",
                backendType: .sftp,
                host: "example.com",
                username: "user"
            )
            let mountURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("mounted-shutdown-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
            await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
            credentialProvider.credentials[config.id] = Credential(password: "pass")
            try manager.add(config)
            await manager.connect(config.id)
            _ = await waitForMountState(config.id)
            configs.append(config)
        }

        // Both teardowns hold here, which is what a backend that will not let go looks
        // like from the manager's side.
        let gate = TestGate()
        await mountProvider.setDisconnectGate(gate)
        let shutdown = Task { @MainActor in await manager.shutdown() }

        var disconnects: [String] = []
        for _ in 0..<1000 {
            disconnects = await mountProvider.disconnectInvocations
            if disconnects.count == configs.count { break }
            await Task.yield()
        }
        // Torn down one at a time, the second would not start until the first had used up
        // its whole deadline — long after this bounded poll gives up.
        XCTAssertEqual(
            Set(disconnects),
            Set(configs.map(\.domainIdentifier)),
            "shutdown tore the connections down one after another"
        )

        await gate.open()
        await shutdown.value
        for config in configs {
            XCTAssertEqual(manager.mountState(for: config.id), .unmounted)
        }
    }

    /// A teardown owns the domain, the convenience link and the filesystem until it
    /// publishes `.unmounted`. A Mount arriving inside that window used to start a second
    /// attempt alongside it, and the teardown's final write landed after the mount it never
    /// saw — leaving the row unmounted with a domain that had just been brought up.
    func testConnectWaitsForATeardownAlreadyInFlight() async throws {
        let config = ConnectionConfig(
            name: "RemountDuringTeardown",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mounted-remount-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        _ = await waitForMountState(config.id)
        await mountProvider.clearInvocations()

        let gate = TestGate()
        await mountProvider.setDisconnectGate(gate)
        let teardown = Task { @MainActor in await manager.disconnect(config.id) }
        await gate.waitUntilEntered()

        let remountStarted = expectation(description: "the remount called connect")
        let remount = Task { @MainActor in
            remountStarted.fulfill()
            await manager.connect(config.id)
        }
        await fulfillment(of: [remountStarted], timeout: 5)
        // The gate stays shut for a while on purpose: an attempt that is free to run
        // alongside the teardown gets every opportunity to finish here, which is what the
        // assertions below then see. Parked on the teardown, the remount does nothing at
        // all in this window.
        for _ in 0..<100 {
            await Task.yield()
        }

        await gate.open()
        await teardown.value
        await remount.value
        _ = await waitForMountState(config.id)

        // The remount ran after the teardown finished, rather than alongside it: the
        // provider's log is ordered by completion, and the teardown does not complete
        // until the gate opens.
        let operations = await mountProvider.operationLog
        XCTAssertEqual(operations, ["disconnect", "reconnect"])
        // The mount the user asked for last is the one that stands.
        XCTAssertTrue(manager.effectiveMountState(for: config.id).isMounted)
    }

    /// Registration sync suspends before and inside `ensureRegistered`, and a removal
    /// running there takes the row, the domain and the credential with it. Registering
    /// afterwards would leave a domain and a bootstrap snapshot behind for a connection
    /// that no longer exists, with nothing left to clean them up.
    func testRegistrationSyncDoesNotResurrectARemovedConnection() async throws {
        let config = ConnectionConfig(
            name: "RemovedDuringRegistration",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        let gate = TestGate()
        await mountProvider.setEnsureRegisteredGate(gate)
        let registration = Task { @MainActor in
            try await manager.syncSavedConnectionRegistration(config, previousConfig: config)
        }
        await gate.waitUntilEntered()

        // Nothing this removal needs is gated, so it runs to completion while the
        // registration is still suspended inside `ensureRegistered`.
        try await manager.remove(config)
        await gate.open()

        do {
            try await registration.value
            XCTFail("Expected the registration to refuse a connection that was removed")
        } catch {
            XCTAssertEqual(error as? ConnectionManagerError, .connectionNotFound(config.id))
        }

        let registeredDomainIDs = await mountProvider.registeredDomainIDs
        XCTAssertFalse(
            registeredDomainIDs.contains(config.domainIdentifier),
            "the removed connection's domain was registered again"
        )
        XCTAssertTrue(manager.connections.isEmpty)
    }

    /// Removal is handed a config by a caller that may be holding an older revision of it.
    /// Cleanup and rollback both have to act on the row as it is now, or the domain is
    /// restored with a host and name that disagree with the connection restored to storage.
    func testRemovalUsesTheCurrentRevisionRatherThanTheCallersSnapshot() async throws {
        let staleConfig = ConnectionConfig(
            name: "StaleSnapshot",
            backendType: .sftp,
            host: "old.example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[staleConfig.id] = Credential(password: "pass")
        try manager.add(staleConfig)

        var editedConfig = staleConfig
        editedConfig.name = "EditedSinceTheSnapshot"
        editedConfig.host = "new.example.com"
        try manager.update(editedConfig)
        await mountProvider.clearInvocations()

        // Fails on the last step, which is the one that rolls the removal back.
        credentialProvider.deleteError = RemoteFileSystemError.operationFailed("delete failed")

        do {
            try await manager.remove(staleConfig)
            XCTFail("Expected the failed credential deletion to surface")
        } catch {
            // The rollback is what this test is about; the error itself is covered
            // elsewhere.
        }

        let unregisteredHosts = await mountProvider.unregisterConfigs.map(\.host)
        XCTAssertEqual(unregisteredHosts, ["new.example.com"])
        let restoredHosts = await mountProvider.ensureRegisteredConfigs.map(\.host)
        XCTAssertEqual(
            restoredHosts,
            ["new.example.com"],
            "the domain was restored with the revision the caller was holding"
        )
        XCTAssertEqual(manager.connections.first?.host, "new.example.com")
    }

    /// A teardown reports its failure by publishing state, not by returning one, so the
    /// registration behind it has to look at what was left. Old runtime state for the
    /// previous config — a domain that would not disconnect — is not a completed switch,
    /// and reporting one lets a save, or a reload that already published the edited row,
    /// treat the connection as serving what it now shows.
    func testEditingAMountedConnectionFailsWhenItsTeardownDoes() async throws {
        let config = ConnectionConfig(
            name: "TeardownFailsOnEdit",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mounted-edit-failure-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        _ = await waitForMountState(config.id)
        await mountProvider.clearInvocations()
        await mountProvider.setUnmountShouldFail(true)

        var edited = config
        edited.name = "TeardownFailsOnEditRenamed"
        do {
            try await manager.syncSavedConnectionRegistration(edited, previousConfig: config)
            XCTFail("Expected the failed teardown to surface")
        } catch {
            XCTAssertEqual(error as? ConnectionManagerError, .cleanupFailed(config.id))
        }

        // And it stopped there rather than mounting the new config on top of the old
        // runtime state.
        let reconnects = await mountProvider.reconnectInvocations
        XCTAssertTrue(reconnects.isEmpty, "the edit remounted on top of a failed teardown")
    }

    /// A retry loop still backing off outlives the row unless removal tears it down: it
    /// goes on calling `connect` against an id that is gone, and its dictionary entry
    /// stays behind as lifecycle work that never completes.
    func testRemovingAConnectionTearsDownAPendingReconnect() async throws {
        let config = ConnectionConfig(
            name: "PendingReconnect",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mounted-reconnect-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        _ = await waitForMountState(config.id)
        await manager.disconnect(config.id)
        await mountProvider.clearInvocations()

        // Nothing else about this row reads as work in progress, so the pending retry is
        // the only thing that can route the removal through a teardown.
        manager.reconnect(config.id)
        try await manager.remove(config)

        let disconnects = await mountProvider.disconnectInvocations
        XCTAssertEqual(disconnects, [config.domainIdentifier])
        XCTAssertTrue(manager.connections.isEmpty)
    }

    /// A teardown that could not disconnect the filesystem keeps it around while the row
    /// goes on offering Mount, so the retry has to clear it — otherwise the connection is
    /// stuck in its error state for the life of the process.
    func testConnectRecoversFromAFailedFileSystemTeardown() async throws {
        let config = ConnectionConfig(
            name: "StuckTeardown",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        let fileSystem = try XCTUnwrap(lastCreatedFileSystem)
        await fileSystem.setDisconnectShouldFail(true)

        await manager.disconnect(config.id)
        guard case .error = manager.state(for: config.id) else {
            return XCTFail("Expected an error state after the filesystem refused to disconnect")
        }
        XCTAssertNotNil(manager.fileSystem(for: config.id))

        await fileSystem.setDisconnectShouldFail(false)
        await manager.connect(config.id)

        XCTAssertEqual(manager.state(for: config.id), .connected)
        XCTAssertNotNil(manager.fileSystem(for: config.id))
    }

    /// Removal suspends while the row is still on screen; a Mount arriving then would
    /// re-register the domain removal had just unregistered.
    func testConnectIsRejectedWhileRemovalIsInFlight() async throws {
        let config = ConnectionConfig(
            name: "RemovalRace",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mounted-removal-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        _ = await waitForMountState(config.id)
        let registrationsBefore = await mountProvider.ensureRegisteredInvocations.count

        let gate = TestGate()
        await mountProvider.setDisconnectGate(gate)
        let removal = Task { @MainActor in try await manager.remove(config) }
        await gate.waitUntilEntered()

        await manager.connect(config.id)
        let registrationsDuringRemoval = await mountProvider.ensureRegisteredInvocations.count
        XCTAssertEqual(registrationsDuringRemoval, registrationsBefore)

        await gate.open()
        try await removal.value

        XCTAssertTrue(manager.connections.isEmpty)
        let registrationsAfter = await mountProvider.ensureRegisteredInvocations.count
        XCTAssertEqual(registrationsAfter, registrationsBefore)
    }

    /// Two removals of the same connection can overlap. The one that finishes first must
    /// not unmark the id, or a Mount slips in while the other is still tearing down.
    func testRemovalStaysMarkedUntilTheLastOverlappingRemovalFinishes() async throws {
        let config = ConnectionConfig(
            name: "OverlappingRemoval",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mounted-overlapping-removal-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        _ = await waitForMountState(config.id)

        // Holds the first removal past its cleanup, in the middle of the credential work.
        let gate = TestGate()
        credentialProvider.credentialLookupGate = gate
        let firstRemoval = Task { @MainActor in try await manager.remove(config) }
        await gate.waitUntilEntered()

        // The second removal joins the first instead of running its own pass: each pass
        // rolls back to the state it captured on entry, so one that started while the
        // other was suspended could restore the connection the other just removed.
        let secondRemoval = Task { @MainActor in try await manager.remove(config) }
        // Let it reach the join before the first removal is released: it parks on the
        // first as soon as its body starts, which takes one hop onto the main actor.
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertTrue(manager.isRemovalInFlight(for: config.id))

        await gate.open()
        try await firstRemoval.value
        try await secondRemoval.value
        XCTAssertFalse(manager.isRemovalInFlight(for: config.id))
        XCTAssertTrue(manager.connections.isEmpty)
        // One pass, not two: the join reports the first removal's outcome.
        let unregisterInvocations = await mountProvider.unregisterInvocations
        XCTAssertEqual(unregisterInvocations, [config.domainIdentifier])
    }

    /// Waiting for the repairs already running only covers the start of the teardown; one
    /// that begins later still races the `removeSymlink` in the middle of it.
    func testMountRepairIsRefusedWhileATeardownIsRunning() async throws {
        let config = ConnectionConfig(
            name: "RepairAfterTeardownStarted",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mounted-late-repair-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        _ = await waitForMountState(config.id)
        let symlinkURL = testSymlinkBaseURL
            .appendingPathComponent(FileProviderMountProvider.symlinkFilename(for: config))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlinkURL.path))

        // The gate sits after removeSymlink, so a repair starting now would recreate a
        // link the teardown has already removed.
        let gate = TestGate()
        await mountProvider.setDisconnectGate(gate)
        let disconnect = Task { @MainActor in await manager.disconnect(config.id) }
        await gate.waitUntilEntered()
        let symlinkCreationsBefore = await mountProvider.createSymlinkInvocations.count

        await manager.repairMountState(for: config.id)

        let symlinkCreationsDuringTeardown = await mountProvider.createSymlinkInvocations.count
        XCTAssertEqual(symlinkCreationsDuringTeardown, symlinkCreationsBefore)

        await gate.open()
        await disconnect.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: symlinkURL.path))
        XCTAssertEqual(manager.mountState(for: config.id), .unmounted)
    }

    /// A registered domain that was disconnected behind the app's back still resolves to a
    /// CloudStorage URL, so the URL alone must not be read as "mounted".
    func testRepairMountStateReconcilesADisconnectedDomain() async throws {
        let config = ConnectionConfig(
            name: "ExternallyDisconnected",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mounted-repair-state-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        let mountedState = await waitForMountState(config.id)
        XCTAssertEqual(mountedState, .mounted(path: mountURL.path))

        let symlinkURL = testSymlinkBaseURL
            .appendingPathComponent(FileProviderMountProvider.symlinkFilename(for: config))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlinkURL.path))

        await mountProvider.setDomainStates([
            RegisteredDomainState(identifier: config.domainIdentifier, isDisconnected: true)
        ])
        await manager.repairMountState(for: config.id)

        XCTAssertEqual(manager.mountState(for: config.id), .unmounted)
        // The shortcut has to go with the state it reflected, or ~/MFuse keeps a link
        // into a CloudStorage location nothing serves.
        XCTAssertFalse(FileManager.default.fileExists(atPath: symlinkURL.path))
    }

    /// A successful mount deliberately leaves `ConnectionState` at `.disconnected` — the
    /// extension owns the session — so a retry loop that reads the connection state sees
    /// every mounted domain as a failure and remounts it on every attempt.
    func testReconnectStopsOnceTheDomainIsMounted() async throws {
        let config = ConnectionConfig(
            name: "ReconnectMounted",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let fileSystem = MockFileSystem()
        lastCreatedFileSystem = fileSystem
        registry.register(.sftp) { _, _ in fileSystem }
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconnect-mounted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        manager.reconnect(config.id)

        // Long enough to cover the first retry (1s) and the second (2s after it).
        try await Task.sleep(nanoseconds: 3_500_000_000)

        XCTAssertEqual(manager.effectiveMountState(for: config.id), .mounted(path: mountURL.path))
        let connectCallCount = await fileSystem.connectCallCount
        XCTAssertEqual(connectCallCount, 1)
        let reconnectInvocations = await mountProvider.reconnectInvocations
        XCTAssertEqual(reconnectInvocations, [config.domainIdentifier])
    }

    /// An attempt still in its handshake holds `.connecting`, no mount state and no
    /// published filesystem, so nothing in the removal's cleanup check saw it — and
    /// `unregister` ran while the attempt could still register the same domain.
    func testRemoveTearsDownAConnectStillInItsHandshake() async throws {
        let config = ConnectionConfig(
            name: "RemoveDuringHandshake",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        manager.mountProvider = mountProvider
        let fileSystem = MockFileSystem()
        lastCreatedFileSystem = fileSystem
        registry.register(.sftp) { _, _ in fileSystem }
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        // Held inside the backend handshake, past the point where the attempt has already
        // checked the generation: only cancelling it stops the session from opening.
        await fileSystem.setConnectDelay(nanoseconds: 2_000_000_000)
        let attempt = Task { @MainActor in await manager.connect(config.id) }
        for _ in 0..<200 {
            if await fileSystem.connectCallCount > 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(manager.state(for: config.id), .connecting)
        XCTAssertNil(manager.fileSystem(for: config.id))
        XCTAssertEqual(manager.mountState(for: config.id), .unmounted)

        try await manager.remove(config)
        await attempt.value

        XCTAssertTrue(manager.connections.isEmpty)
        let isConnected = await fileSystem.isConnected
        XCTAssertFalse(isConnected, "the attempt opened a session for a connection already removed")
        let disconnectCalled = await fileSystem.disconnectCalled
        XCTAssertFalse(
            disconnectCalled,
            "the handshake should have been cancelled by the removal, not completed and thrown away"
        )
        let ensureRegisteredInvocations = await mountProvider.ensureRegisteredInvocations
        XCTAssertTrue(
            ensureRegisteredInvocations.isEmpty,
            "the interrupted attempt must not register the domain the removal just unregistered"
        )
    }

    /// Refresh is the manager's own operation, so it decides on the state at the moment it
    /// runs — `signalEnumerator` rewrites the extension's bootstrap snapshot, and a view
    /// firing it from a captured config would do that for a connection that is no longer
    /// mounted, or no longer looks like the captured one.
    func testRefreshIsSkippedOnceTheConnectionIsUnmounted() async throws {
        let config = ConnectionConfig(
            name: "RefreshAfterUnmount",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("refresh-skip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        _ = await waitForMountState(config.id)
        await mountProvider.clearInvocations()

        await manager.refreshMountedConnection(for: config.id)
        var signalInvocations = await mountProvider.signalInvocations
        XCTAssertEqual(signalInvocations, [config.domainIdentifier])

        await manager.disconnect(config.id)
        await mountProvider.clearInvocations()

        await manager.refreshMountedConnection(for: config.id)
        signalInvocations = await mountProvider.signalInvocations
        XCTAssertTrue(signalInvocations.isEmpty, "an unmounted connection has nothing to refresh")
    }

    /// A refresh that cannot reach the domain is exactly when the row is still showing a
    /// mount that is no longer there.
    func testRefreshFailureReconcilesTheMountState() async throws {
        let config = ConnectionConfig(
            name: "RefreshFailure",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("refresh-failure-\(UUID().uuidString)", isDirectory: true)
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

        // The domain went away behind the app's back.
        await mountProvider.setSignalShouldFail(true)
        await mountProvider.setDomainStates([])

        await manager.refreshMountedConnection(for: config.id)

        XCTAssertEqual(manager.mountState(for: config.id), .unmounted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: symlinkURL.path))
    }

    /// A connect that has not published its filesystem yet still owns one, so a teardown
    /// that returns before the attempt unwinds reports a cleanup that has not happened —
    /// and `remove` would clear the row while a session was still being opened.
    func testDisconnectWaitsForAnInFlightConnectToUnwind() async throws {
        let config = ConnectionConfig(
            name: "TeardownDuringConnect",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let fileSystem = MockFileSystem()
        lastCreatedFileSystem = fileSystem
        registry.register(.sftp) { _, _ in fileSystem }
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        // Holds the attempt inside the credential lookup, before it can build — let alone
        // publish — a filesystem. The gate ignores cancellation, so only the teardown
        // actually waiting for the attempt lets this test finish in order.
        let gate = TestGate()
        credentialProvider.credentialLookupGate = gate
        let attempt = Task { @MainActor in await manager.connect(config.id) }
        await gate.waitUntilEntered()

        let teardown = Task { @MainActor in await manager.disconnect(config.id) }
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertFalse(teardown.isCancelled)
        XCTAssertEqual(manager.state(for: config.id), .connecting)

        await gate.open()
        await teardown.value
        await attempt.value

        XCTAssertEqual(manager.state(for: config.id), .disconnected)
        XCTAssertNil(manager.fileSystem(for: config.id))
        let connectCallCount = await fileSystem.connectCallCount
        XCTAssertEqual(connectCallCount, 0, "the interrupted attempt must not open a session")
    }

    /// The caller that starts an attempt does not own it. Cancelling it has to return that
    /// caller at once — it used to sit on the shared task until the whole handshake
    /// finished — without taking the attempt down for the callers that joined it.
    func testCancellingTheStarterReturnsItAndLeavesAJoinedConnectRunning() async throws {
        let config = ConnectionConfig(
            name: "CancelledStarter",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        // Held inside the credential lookup, so the attempt is suspended well before it
        // could finish on its own.
        let gate = TestGate()
        credentialProvider.credentialLookupGate = gate

        let starterReturned = expectation(description: "the cancelled starter returned")
        let starter = Task { @MainActor in
            await manager.connect(config.id)
            starterReturned.fulfill()
        }
        await gate.waitUntilEntered()

        let joiner = Task { @MainActor in await manager.connect(config.id) }
        var waiterCount = 0
        for _ in 0..<1000 {
            waiterCount = manager.connectWaiterCount(for: config.id)
            if waiterCount == 2 { break }
            await Task.yield()
        }
        XCTAssertEqual(waiterCount, 2, "the starter and the joiner should both be waiting")

        starter.cancel()
        // Bounded: on a regression this returns only once the gate opens, which it has not.
        await fulfillment(of: [starterReturned], timeout: 5)

        XCTAssertEqual(manager.state(for: config.id), .connecting)

        await gate.open()
        await joiner.value

        XCTAssertEqual(manager.state(for: config.id), .connected)
        XCTAssertNotNil(manager.fileSystem(for: config.id))
    }

    /// A cancelled attempt publishes no final state of its own, and `.connecting` is also
    /// what makes every later connect return at the deduplication guard — so leaving it
    /// behind pins the row until the app restarts.
    func testCancelledConnectClearsTheConnectingState() async throws {
        let config = ConnectionConfig(
            name: "CancelledConnecting",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let fileSystem = MockFileSystem()
        await fileSystem.setConnectDelay(nanoseconds: 5_000_000_000)
        lastCreatedFileSystem = fileSystem
        registry.register(.sftp) { _, _ in fileSystem }
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        let attempt = Task { @MainActor in await manager.connect(config.id) }
        for _ in 0..<200 {
            if await fileSystem.connectCallCount > 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(manager.state(for: config.id), .connecting)

        attempt.cancel()
        await attempt.value

        // The cancelled caller returns without waiting for the attempt it gave up on — it
        // is shared, so it unwinds on its own — and clearing the row is the last thing that
        // attempt does.
        var stateAfterCancellation = manager.state(for: config.id)
        for _ in 0..<1000 {
            if stateAfterCancellation == .disconnected { break }
            await Task.yield()
            stateAfterCancellation = manager.state(for: config.id)
        }
        XCTAssertEqual(stateAfterCancellation, .disconnected)

        // The row is actionable again: the guard no longer sees a live attempt.
        await fileSystem.setConnectDelay(nanoseconds: 0)
        await manager.connect(config.id)
        XCTAssertEqual(manager.state(for: config.id), .connected)
    }

    /// A connection edited on another device keeps its UUID, so the added/removed loops
    /// never reach it: without this the domain goes on serving the old host from its
    /// bootstrap snapshot while the UI already shows the new one.
    func testReloadReRegistersAConnectionChangedUnderTheSameID() async throws {
        var config = ConnectionConfig(
            name: "ReloadChanged",
            backendType: .sftp,
            host: "old.example.com",
            username: "user"
        )
        let mountProvider = MockMountProvider(symlinkBaseURL: testSymlinkBaseURL)
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reload-changed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        await mountProvider.setMountURL(mountURL, for: config.domainIdentifier)
        manager.mountProvider = mountProvider
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        await manager.connect(config.id)
        _ = await waitForMountState(config.id)
        await mountProvider.clearInvocations()

        config.host = "new.example.com"
        try storage.saveConnections([config])

        await manager.reloadConnectionsFromStorage()

        XCTAssertEqual(manager.connections, [config])
        // Registered again with the new config — once for the reconciliation, once for
        // the remount that follows it.
        let ensureRegisteredInvocations = await mountProvider.ensureRegisteredInvocations
        XCTAssertEqual(ensureRegisteredInvocations, Array(repeating: config.domainIdentifier, count: 2))
        // Mounted connections are remounted, so the extension picks the new host up now
        // rather than at the next relaunch.
        let reconnectInvocations = await mountProvider.reconnectInvocations
        XCTAssertEqual(reconnectInvocations, [config.domainIdentifier])
        let remountedState = await waitForMountState(config.id)
        XCTAssertEqual(remountedState, .mounted(path: mountURL.path))
    }

    /// Cancelling a connect must stop it, not let the retry delay swallow the cancellation
    /// and establish a connection nobody is waiting for.
    func testCancelledConnectDoesNotRetryAfterTheDelay() async throws {
        let config = ConnectionConfig(
            name: "CancelledRetry",
            backendType: .sftp,
            host: "example.com",
            username: "user"
        )
        let fileSystem = MockFileSystem()
        await fileSystem.setConnectFailures([.connectionFailed("Connection timed out")])
        lastCreatedFileSystem = fileSystem
        registry.register(.sftp) { _, _ in fileSystem }
        credentialProvider.credentials[config.id] = Credential(password: "pass")
        try manager.add(config)

        let attempt = Task { @MainActor in await manager.connect(config.id) }
        var callCountDuringRetryDelay = 0
        for _ in 0..<200 {
            callCountDuringRetryDelay = await fileSystem.connectCallCount
            if callCountDuringRetryDelay > 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(callCountDuringRetryDelay, 1)

        attempt.cancel()
        await attempt.value

        let finalCallCount = await fileSystem.connectCallCount
        XCTAssertEqual(finalCallCount, 1)
        XCTAssertNotEqual(manager.state(for: config.id), .connected)
        XCTAssertNil(manager.fileSystem(for: config.id))
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
        // The domain is still registered, so the retained connection must not read as a
        // clean disconnect — only the user retrying the removal can clear it.
        guard case .error(let message) = manager.state(for: config.id) else {
            return XCTFail("Expected an error state after a failed unregister during reload")
        }
        XCTAssertTrue(message.contains("mock unmount failure"))
        XCTAssertEqual(manager.effectiveMountState(for: config.id), .error(message))
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

    private func waitUntilRemovalStarts(
        for id: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1000 {
            if manager.isRemovalInFlight(for: id) { return }
            await Task.yield()
        }
        XCTFail("Removal never started", file: file, line: line)
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
