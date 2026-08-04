import Foundation
#if canImport(FileProvider)
import FileProvider
#endif
import os.log

public enum ConnectionManagerError: Error, LocalizedError, Equatable {
    case cleanupFailed(UUID)
    case removalInProgress(UUID)
    case connectionNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .cleanupFailed(let id):
            return MFuseCoreL10n.string(
                "connectionManager.error.cleanupFailed",
                fallback: "Failed to clean up connection %@ before removal",
                id.uuidString
            )
        case .removalInProgress(let id):
            return MFuseCoreL10n.string(
                "connectionManager.error.removalInProgress",
                fallback: "Connection %@ is being removed; save it again once that finishes",
                id.uuidString
            )
        case .connectionNotFound(let id):
            return MFuseCoreL10n.string(
                "connectionManager.error.connectionNotFound",
                fallback: "Connection %@ no longer exists",
                id.uuidString
            )
        }
    }
}

/// Carries the outcome of a tracked `signalEnumerator` pass out of the task that ran it.
///
/// The task itself has to be `Task<Void, Never>` to sit in `refreshTasks` alongside the
/// refreshes teardown already cancels and awaits, so the error travels beside it.
@MainActor
private final class SignalOutcome {
    var error: Error?
}

/// Resumes quit-time cleanup exactly once, whichever of the work and the deadline gets
/// there first.
@MainActor
private final class ShutdownDeadlineResumer {
    var continuation: CheckedContinuation<Void, Never>?

    /// Whether this call is the one that resumed.
    @discardableResult
    func resume() -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume()
        return true
    }
}

/// Manages the lifecycle of remote filesystem connections.
/// Used by the main app to create, connect, disconnect, and track connections.
@MainActor
public final class ConnectionManager: ObservableObject {
    private let logger = Logger(subsystem: "com.lollipopkit.mfuse.core", category: "ConnectionManager")

    @Published public private(set) var connections: [ConnectionConfig] = []
    @Published public private(set) var states: [UUID: ConnectionState] = [:]
    @Published public private(set) var mountStates: [UUID: MountState] = [:]
    @Published public var needsExtensionSetup = false

    private let storage: SharedStorage
    private let credentialProvider: CredentialProvider
    private let registry: BackendRegistry
    private var fileSystems: [UUID: any RemoteFileSystem] = [:]
    private var connectionGenerations: [UUID: Int] = [:]
    private var connectTasks: [UUID: Task<Void, Never>] = [:]
    /// Callers waiting on someone else's connect attempt, keyed so each can be resumed —
    /// or give up — on its own. See `waitForConnectAttempt(_:task:)`.
    private var connectWaiters: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]
    /// Everyone still interested in a connect attempt, the caller that started it
    /// included. The attempt is shared, so no single caller's cancellation may take it
    /// down: it is cancelled once the last participant has given up on it.
    private var connectParticipants: [UUID: Set<UUID>] = [:]
    private var interruptedConnectionIDs: Set<UUID> = []
    /// Serialized rather than counted: two removals of the same connection can overlap,
    /// and each captures the state it would roll back to, so an earlier pass resuming
    /// after a later one succeeded would restore the connection that one just removed.
    private var removalTasks: [UUID: Task<Void, Error>] = [:]
    private var disconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var mountResolutionTasks: [UUID: Task<Void, Never>] = [:]
    private var mountRepairTasks: [UUID: Task<Void, Never>] = [:]
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    var staleDomainRemover: ((String) async throws -> Void)?

    /// Optional mount provider – when set, connect() activates a registered domain and disconnect() keeps it registered but disconnected.
    public var mountProvider: (any MountProvider)?

    /// Optional callback for state change notifications (connect/disconnect/error).
    public var onStateChange: ((ConnectionConfig, ConnectionState) -> Void)?

    /// Optional callback for mount state change notifications.
    public var onMountStateChange: ((ConnectionConfig, MountState) -> Void)?

    /// Optional callback fired after local add/update/remove persistence succeeds.
    public var onLocalConnectionsDidChange: (([ConnectionConfig]) -> Void)?

    private static let maxRetries = 5
    private static let baseDelay: UInt64 = 1_000_000_000 // 1 second in nanoseconds
    private static let mountURLRetryCount = 20
    private static let mountURLRetryDelay: UInt64 = 500_000_000 // 500 ms in nanoseconds
    private static let transientConnectionRetryCount = 2
    private static let transientConnectionRetryDelay: UInt64 = 750_000_000 // 750 ms in nanoseconds
    /// How long quit waits for one connection's cleanup before abandoning it.
    private static let shutdownDeadlineNanoseconds: UInt64 = 5_000_000_000 // 5 seconds
    private static let shutdownLogger = Logger(
        subsystem: "com.lollipopkit.mfuse.core",
        category: "ConnectionManagerShutdown"
    )

    public init(
        storage: SharedStorage,
        credentialProvider: CredentialProvider,
        registry: BackendRegistry = .shared
    ) {
        self.storage = storage
        self.credentialProvider = credentialProvider
        self.registry = registry
        do {
            self.connections = try storage.loadConnections()
        } catch {
            self.connections = []
            logger.error(
                "Failed to load initial connections from storage: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - CRUD

    public func add(_ config: ConnectionConfig) throws {
        try rejectMutationDuringRemoval(of: config.id)
        connections.append(config)
        states[config.id] = .disconnected
        do {
            try storage.saveConnections(connections)
            onLocalConnectionsDidChange?(connections)
        } catch {
            connections.removeAll { $0.id == config.id }
            states.removeValue(forKey: config.id)
            throw error
        }
    }

    public func update(_ config: ConnectionConfig) throws {
        try rejectMutationDuringRemoval(of: config.id)
        // A removal that finished while the caller was saving leaves nothing to update.
        // Returning quietly told the editor the edit had been applied, and the credential
        // it had already written stayed behind for a connection nobody can see.
        guard let idx = connections.firstIndex(where: { $0.id == config.id }) else {
            throw ConnectionManagerError.connectionNotFound(config.id)
        }
        let previous = connections[idx]
        connections[idx] = config
        do {
            try storage.saveConnections(connections)
            onLocalConnectionsDidChange?(connections)
        } catch {
            connections[idx] = previous
            throw error
        }
    }

    /// Refuse a write to a connection whose removal is already running.
    ///
    /// `performRemove` suspends between deleting the row and deleting its credential, and
    /// a save landing in that window appends the connection back — after the deletion was
    /// persisted, and before the credential is destroyed. What is left is a row with no
    /// secret and no domain, which nothing puts right.
    private func rejectMutationDuringRemoval(of id: UUID) throws {
        guard !isRemovalInFlight(for: id) else {
            throw ConnectionManagerError.removalInProgress(id)
        }
    }

    public func remove(_ config: ConnectionConfig) async throws {
        // Removal suspends repeatedly while the row is still on screen. A Mount landing in
        // one of those windows passes its own membership check and re-registers the domain
        // this method already unregistered, orphaning it once the config is gone.
        //
        // Overlapping removals join the pass already running instead of racing it: each
        // pass rolls back to the state it captured on entry, so a first pass resuming
        // after a second one succeeded would restore what the second one removed.
        if let inFlight = removalTasks[config.id] {
            return try await inFlight.value
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.removalTasks.removeValue(forKey: config.id) }
            try await self.performRemove(config)
        }
        removalTasks[config.id] = task
        return try await task.value
    }

    private func performRemove(_ requestedConfig: ConnectionConfig) async throws {
        // Pinned to the row as it is now, not to the revision the caller is holding: a UI
        // snapshot taken before an edit — or before an external reload — would otherwise
        // unregister and, on rollback, re-register a host, name and parameter set that
        // disagree with the connection `previousConnections` restores to storage.
        let config = connections.first(where: { $0.id == requestedConfig.id }) ?? requestedConfig
        advanceConnectionGeneration(for: config.id)
        let shouldCleanupMount = states[config.id]?.isConnected == true
            || {
                if case .error = states[config.id] {
                    return true
                }
                return false
            }()
            || mountState(for: config.id).isMounted
            || mountState(for: config.id) == .mounting
            || mountResolutionTasks[config.id] != nil
            // A repair recreates the convenience symlink, so it is cleanup work too:
            // skipping the teardown lets a repair suspended inside `createSymlink` relink
            // the domain this method is about to unregister.
            || mountRepairTasks[config.id] != nil
            || refreshTasks[config.id] != nil
            // An attempt still in its handshake is invisible to every check above — it
            // holds `.connecting`, no mount state and no published filesystem — yet it
            // can register the very domain `unregister` is about to remove. Routing it
            // through `disconnect` is what cancels and waits for it first.
            || connectTasks[config.id] != nil
            // A retry loop still backing off outlives the row otherwise: nothing else here
            // cancels it, and it goes on calling `connect` against an id that is gone.
            || reconnectTasks[config.id] != nil
            || fileSystems[config.id] != nil
        if shouldCleanupMount {
            await disconnect(config.id)
            guard isCleanupComplete(for: config.id) else {
                throw ConnectionManagerError.cleanupFailed(config.id)
            }
        }
        if let mountProvider {
            do {
                try await mountProvider.unregister(config: config)
            } catch MountError.domainNotFound {
                states[config.id] = .disconnected
                setMountState(.unmounted, for: config)
                onStateChange?(config, .disconnected)
            } catch {
                let message = "Failed to unregister \(config.name): \(describe(error))"
                let errorState = ConnectionState.error(message)
                states[config.id] = errorState
                setMountState(.error(message), for: config)
                onStateChange?(config, errorState)
                throw RemoteFileSystemError.operationFailed(message)
            }
        }
        let previousConnections = connections
        let previousState = states[config.id]
       let previousMountState = mountStates[config.id]
        let previousFileSystem = fileSystems[config.id]
        let savedCredential: Credential?
        do {
            savedCredential = try await credentialProvider.credential(for: config.id)
        } catch {
            throw removalError(
                primary: error,
                restoreFailures: await restoreDomainRegistration(for: config).map { [$0] } ?? [],
                for: config
            )
        }
        connections.removeAll { $0.id == config.id }
        states.removeValue(forKey: config.id)
        mountStates.removeValue(forKey: config.id)
        fileSystems.removeValue(forKey: config.id)
        do {
            try storage.saveConnections(connections)
        } catch {
            let registrationFailure = await restoreDomainRegistration(for: config)
            restoreRemovedConnectionState(
                for: config.id,
                connections: previousConnections,
                state: previousState,
                mountState: previousMountState,
                fileSystem: previousFileSystem
            )
            throw removalError(
                primary: error,
                restoreFailures: registrationFailure.map { [$0] } ?? [],
                for: config
            )
        }
        do {
            try await credentialProvider.delete(for: config.id)
        } catch {
            let credentialDeleteError = error
            var restoreFailures: [String] = []
            do {
                try restoreRemovedConnectionStateAndPersist(
                    for: config.id,
                    connections: previousConnections,
                    state: previousState,
                    mountState: previousMountState,
                    fileSystem: previousFileSystem
                )
            } catch {
                restoreFailures.append(
                    MFuseCoreL10n.string(
                        "connectionManager.error.restoreRemovedConnection",
                        fallback: "Failed to restore the removed connection: %@",
                        error.localizedDescription
                    )
                )
            }
            if let registrationFailure = await restoreDomainRegistration(for: config) {
                restoreFailures.append(registrationFailure)
            }
            if let savedCredential {
                do {
                    try await credentialProvider.store(savedCredential, for: config.id)
                } catch {
                    restoreFailures.append(
                        MFuseCoreL10n.string(
                            "connectionManager.error.restoreCredential",
                            fallback: "Failed to restore the credential: %@",
                            error.localizedDescription
                        )
                    )
                }
            }
            if !restoreFailures.isEmpty {
                let restoreFailureSummary = restoreFailures.joined(separator: " ")
                throw RemoteFileSystemError.operationFailed(
                    MFuseCoreL10n.string(
                        "connectionManager.error.deleteCredentialWithRestoreFailures",
                        fallback: "Failed to delete credential for connection %@: %@. %@",
                        config.id.uuidString,
                        credentialDeleteError.localizedDescription,
                        restoreFailureSummary
                    )
                )
            }
            throw RemoteFileSystemError.operationFailed(
                MFuseCoreL10n.string(
                    "connectionManager.error.deleteCredentialRecovered",
                    fallback: "Failed to delete credential for connection %@; restored the connection and credential so removal can be retried: %@",
                    config.id.uuidString,
                    credentialDeleteError.localizedDescription
                )
            )
        }
        connectionGenerations.removeValue(forKey: config.id)
        onLocalConnectionsDidChange?(connections)
    }

    // MARK: - Connection lifecycle

    public func connect(_ id: UUID) async {
        // Overlapping callers join the attempt already running instead of returning
        // early: `connect` is awaited for its effect, and a caller that returns before
        // the handshake and mount finish reports a connection nobody established yet.
        if let inFlight = connectTasks[id] {
            await waitForConnectAttempt(id, task: inFlight)
            return
        }
        guard connections.contains(where: { $0.id == id }) else { return }
        guard !isRemovalInFlight(for: id) else { return }
        if case .connecting = states[id] {
            return
        }
        if case .connected = states[id] {
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performConnect(id)
            self.finishConnectAttempt(id)
        }
        connectTasks[id] = task
        // The caller that starts the attempt waits on it exactly the way callers that join
        // it do: on its own continuation. Awaiting `task.value` here instead pinned a
        // cancelled starter to a handshake the callers behind it were still waiting for,
        // while a cancelled joiner returned at once — the attempt is shared, so no caller
        // waits on it past its own cancellation.
        await waitForConnectAttempt(id, task: task)
    }

    /// Give up one caller's interest in a shared attempt, cancelling it only once nobody
    /// is left waiting for it.
    private func relinquishConnectAttempt(
        _ id: UUID,
        participantID: UUID,
        task: Task<Void, Never>
    ) {
        guard connectTasks[id] == task, var participants = connectParticipants[id] else {
            return
        }
        participants.remove(participantID)
        guard participants.isEmpty else {
            connectParticipants[id] = participants
            return
        }
        connectParticipants.removeValue(forKey: id)
        task.cancel()
    }

    /// Wait for the attempt another caller started, without waiting past *this* caller's
    /// own cancellation.
    ///
    /// `Task.value` resumes only when the awaited task finishes, so a cancelled joiner
    /// would stay pinned to an attempt it no longer wants; cancelling that attempt
    /// instead would abandon the caller that started it. Joiners therefore park on their
    /// own continuation, which `finishConnectAttempt(_:)` resumes.
    private func waitForConnectAttempt(_ id: UUID, task: Task<Void, Never>) async {
        let waiterID = UUID()
        // Registered before the checks below, and withdrawn on every way out: the attempt
        // is cancelled by whichever caller is the last to give up on it, and a caller that
        // never counted as interested could not be that one.
        connectParticipants[id, default: []].insert(waiterID)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Both checks share this step with the registration: a cancellation that
                // landed first has no continuation to resume yet, and an attempt that
                // finished while this call hopped back onto the main actor never will.
                if Task.isCancelled || connectTasks[id] != task {
                    continuation.resume()
                } else {
                    connectWaiters[id, default: [:]][waiterID] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeConnectWaiter(id, waiterID: waiterID)
                self?.relinquishConnectAttempt(id, participantID: waiterID, task: task)
            }
        }
        // Covers the paths the handler above does not: a caller that was already cancelled
        // when it got here, and one that resumed normally. Both are no-ops once
        // `finishConnectAttempt` has cleared the attempt.
        relinquishConnectAttempt(id, participantID: waiterID, task: task)
    }

    /// Test seam: how many callers are parked on the attempt for this connection.
    func connectWaiterCount(for id: UUID) -> Int {
        connectWaiters[id]?.count ?? 0
    }

    private func resumeConnectWaiter(_ id: UUID, waiterID: UUID) {
        guard let continuation = connectWaiters[id]?.removeValue(forKey: waiterID) else { return }
        if connectWaiters[id]?.isEmpty == true {
            connectWaiters.removeValue(forKey: id)
        }
        continuation.resume()
    }

    private func finishConnectAttempt(_ id: UUID) {
        connectTasks.removeValue(forKey: id)
        // Safe to drop wholesale: a replacement attempt can only be registered once
        // `connectTasks` is clear, which happens in this same main-actor step.
        connectParticipants.removeValue(forKey: id)
        let waiters = connectWaiters.removeValue(forKey: id) ?? [:]
        for continuation in waiters.values {
            continuation.resume()
        }
    }

    private func performConnect(_ id: UUID) async {
        guard let config = connections.first(where: { $0.id == id }) else { return }
        // A new attempt is a new generation. Teardowns advanced it so their state could
        // not be overwritten by work they interrupted; a connect needs the same, or a
        // `syncMounts` holding a snapshot from before this attempt still passes its own
        // fence and unmounts the domain this attempt just brought up.
        let localGeneration = advanceConnectionGeneration(for: id)
        interruptedConnectionIDs.remove(id)
        states[id] = .connecting
        // effectiveMountState gives a mount error precedence over the handshake, so a
        // retry would keep showing the previous failure — and an enabled Mount action —
        // for its whole duration unless the stale error is cleared first.
        if case .error = mountState(for: id) {
            setMountState(.unmounted, for: config)
        }
        defer {
            interruptedConnectionIDs.remove(id)
            // A cancelled attempt reaches none of the branches that publish a final
            // state, so without this the row stays pinned at `.connecting` — and every
            // later connect returns at the guard above. Only the attempt that still owns
            // the connection clears it; a teardown that interrupted this one has already
            // published its own state.
            if case .connecting = states[id],
               isCurrentConnectionAttempt(for: id, generation: localGeneration) {
                states[id] = .disconnected
                onStateChange?(config, .disconnected)
            }
        }

        do {
            // A teardown that could not disconnect the filesystem leaves it behind while
            // the row goes on offering Mount. Retrying that teardown is what makes the
            // retry work: `connect` used to return on a lingering filesystem, pinning the
            // connection in its error state until the app restarted. The reference is
            // dropped only once the disconnect succeeds — dropping it on failure loses
            // the only handle to a session that is still open on the remote.
            if let lingering = fileSystems[id] {
                do {
                    try await lingering.disconnect()
                    fileSystems.removeValue(forKey: id)
                } catch {
                    guard isCurrentConnectionAttempt(for: id, generation: localGeneration),
                          !interruptedConnectionIDs.contains(id) else {
                        return
                    }
                    let message = "Failed to disconnect filesystem for \(config.name) before reconnecting: \(describe(error))"
                    logger.error(
                        "Failed to disconnect lingering filesystem for connection \(config.name, privacy: .private): \(self.describe(error), privacy: .public)"
                    )
                    let errorState = ConnectionState.error(message)
                    states[id] = errorState
                    onStateChange?(config, errorState)
                    return
                }
            }
            let credential = try await credentialProvider.credential(for: id) ?? Credential()
            guard isCurrentConnectionAttempt(for: id, generation: localGeneration),
                  !interruptedConnectionIDs.contains(id) else {
                return
            }
            guard let fs = registry.createFileSystem(config: config, credential: credential) else {
                guard isCurrentConnectionAttempt(for: id, generation: localGeneration),
                      !interruptedConnectionIDs.contains(id) else {
                    return
                }
                let errorState = ConnectionState.error(
                    MFuseCoreL10n.string(
                        "connectionManager.error.unsupportedBackend",
                        fallback: "Unsupported backend: %@",
                        config.backendType.displayName
                    )
                )
                states[id] = errorState
                onStateChange?(config, errorState)
                return
            }
            try await connectFileSystemWithRetry(fs, for: config)
            // Cancellation is checked alongside the generation: a backend that ignores it
            // can hand back a live connection to an attempt nobody is waiting for.
            if !isCurrentConnectionAttempt(for: id, generation: localGeneration)
                || interruptedConnectionIDs.contains(id)
                || Task.isCancelled {
                await discardFileSystem(fs, for: id, context: "abandoned connect attempt")
                return
            }
            fileSystems[id] = fs
            states[id] = .connected
            onStateChange?(config, .connected)

            // Auto-mount if mount provider is set
            if let mp = mountProvider {
                setMountState(.mounting, for: config)
                do {
                    try await mp.ensureRegistered(config: config)
                    try await mp.reconnect(config: config)
                    // Cancellation is checked alongside the generation here too: nothing
                    // guarantees a MountProvider throws on it, so a cancelled attempt whose
                    // `ensureRegistered`/`reconnect` returned normally would otherwise go on
                    // to publish a mount nobody is waiting for.
                    guard isCurrentConnectionAttempt(for: id, generation: localGeneration),
                          !interruptedConnectionIDs.contains(id),
                          !Task.isCancelled else {
                        try? await mp.disconnect(config: config)
                        await discardFileSystem(fs, for: id, context: "abandoned mount attempt")
                        return
                    }
                    if let disconnectFailure = await disconnectMountedFileSystem(
                        fs,
                        for: config,
                        context: "after mounting"
                    ) {
                        guard isCurrentConnectionAttempt(for: id, generation: localGeneration),
                              !interruptedConnectionIDs.contains(id) else {
                            return
                        }
                        let errorState = ConnectionState.error(disconnectFailure)
                        states[id] = errorState
                        onStateChange?(config, errorState)
                        scheduleMountResolution(for: config, using: mp)
                        return
                    }
                    guard isCurrentConnectionAttempt(for: id, generation: localGeneration),
                          !interruptedConnectionIDs.contains(id) else {
                        return
                    }
                    fileSystems.removeValue(forKey: id)
                    let disconnectedState = ConnectionState.disconnected
                    states[id] = disconnectedState
                    onStateChange?(config, disconnectedState)
                    guard isCurrentConnectionAttempt(for: id, generation: localGeneration),
                          !interruptedConnectionIDs.contains(id) else {
                        return
                    }
                    try? await mp.signalEnumerator(for: config)
                    guard isCurrentConnectionAttempt(for: id, generation: localGeneration),
                          !interruptedConnectionIDs.contains(id) else {
                        return
                    }
                    scheduleMountResolution(for: config, using: mp)
                } catch {
                    // The production provider sleeps and calls `Task.checkCancellation()`
                    // while registering a domain, so a cancelled attempt lands here with a
                    // `CancellationError` — reporting that as a mount failure would put a
                    // red row and a notification in front of the user for work they, or a
                    // teardown, deliberately stopped. The filesystem is still cleaned up
                    // below; only the verdict is left to the outer handling and the defer.
                    let wasCancelled = error is CancellationError || Task.isCancelled
                    var desc = describe(error)
                    if !wasCancelled, isMissingFileProviderExtensionError(error) {
                        needsExtensionSetup = true
                    }
                    if let disconnectFailure = await disconnectMountedFileSystem(
                        fs,
                        for: config,
                        context: "after mount failure"
                    ) {
                        desc += " | \(disconnectFailure)"
                    } else {
                        fileSystems.removeValue(forKey: id)
                    }
                    guard !wasCancelled else {
                        // The mount state was set to `.mounting` before the attempt began.
                        // A teardown that interrupted it publishes its own state, but a
                        // caller that simply gave up leaves the row spinning unless this
                        // clears it.
                        if isCurrentConnectionAttempt(for: id, generation: localGeneration),
                           !interruptedConnectionIDs.contains(id),
                           mountState(for: id) == .mounting {
                            setMountState(.unmounted, for: config)
                        }
                        return
                    }
                    guard isCurrentConnectionAttempt(for: id, generation: localGeneration),
                          !interruptedConnectionIDs.contains(id) else {
                        return
                    }
                    let errorState = ConnectionState.error(desc)
                    states[id] = errorState
                    onStateChange?(config, errorState)
                    setMountState(.error(desc), for: config)
                }
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                return
            }
            guard isCurrentConnectionAttempt(for: id, generation: localGeneration),
                  !interruptedConnectionIDs.contains(id) else {
                return
            }
            let errorState = ConnectionState.error(describe(error))
            states[id] = errorState
            onStateChange?(config, errorState)
        }
    }

    public func disconnect(_ id: UUID) async {
        await disconnect(id, using: nil)
    }

    private func disconnect(_ id: UUID, using configOverride: ConnectionConfig?) async {
        // A row stays effectively mounted until cleanup finishes, so a second click or an
        // overlapping Unmount All can arrive here for the same id. Running the teardown
        // twice repeats removeSymlink and the provider/filesystem disconnects, and a
        // failure in the duplicate pass can mark a connection that unmounted cleanly as
        // errored. Overlapping callers therefore join the pass already running instead of
        // returning early: `remove` and `reloadConnectionsFromStorage` check
        // `isCleanupComplete` as soon as this returns, and would otherwise judge a
        // teardown that is still in flight.
        if let inFlight = disconnectTasks[id] {
            await inFlight.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performDisconnect(id, using: configOverride)
            self.disconnectTasks.removeValue(forKey: id)
        }
        disconnectTasks[id] = task
        await task.value
    }

    private func performDisconnect(_ id: UUID, using configOverride: ConnectionConfig?) async {
        advanceConnectionGeneration(for: id)
        // Awaited, not just flagged: an attempt still running owns a filesystem this
        // teardown cannot see — it is not in `fileSystems` until the attempt publishes it
        // — so returning now would report a cleanup that has not happened, and `remove`
        // would clear the row while a session was still being opened.
        if let connectTask = connectTasks[id] {
            interruptedConnectionIDs.insert(id)
            connectTask.cancel()
            await connectTask.value
        }
        reconnectTasks[id]?.cancel()
        reconnectTasks.removeValue(forKey: id)
        await cancelAndAwaitMountStateWork(for: id)

        let config = configOverride ?? connections.first(where: { $0.id == id })
        var cleanupFailures: [String] = []
        var didDisconnectFileSystem = false

        if let config, let mp = mountProvider {
            do {
                try await mp.removeSymlink(for: config)
            } catch {
                let message = "Failed to remove symlink for \(config.name): \(describe(error))"
                logger.error(
                    "Failed to remove symlink for connection \(config.name, privacy: .private): \(self.describe(error), privacy: .private)"
                )
                cleanupFailures.append(message)
            }

            do {
                try await mp.disconnect(config: config)
            } catch MountError.domainNotFound {
                logger.notice(
                    "Skipping disconnect for missing domain \(config.domainIdentifier, privacy: .public)"
                )
            } catch {
                let message = "Failed to disconnect domain for \(config.name): \(describe(error))"
                logger.error(
                    "Failed to disconnect domain for connection \(config.name, privacy: .private): \(self.describe(error), privacy: .private)"
                )
                cleanupFailures.append(message)
            }
        }

        if let fs = fileSystems[id] {
            do {
                try await fs.disconnect()
                didDisconnectFileSystem = true
            } catch {
                let targetName = config?.name ?? id.uuidString
                let message = "Failed to disconnect filesystem for \(targetName): \(describe(error))"
                logger.error(
                    "Failed to disconnect filesystem for target \(targetName, privacy: .private): \(self.describe(error), privacy: .public)"
                )
                cleanupFailures.append(message)
            }
        }

        if let config, !cleanupFailures.isEmpty {
            if didDisconnectFileSystem {
                fileSystems.removeValue(forKey: id)
            }
            let errorMessage = cleanupFailures.joined(separator: " | ")
            let errorState = ConnectionState.error(errorMessage)
            states[id] = errorState
            setMountState(.error(errorMessage), for: config)
            onStateChange?(config, errorState)
            return
        }

        fileSystems.removeValue(forKey: id)
        states[id] = .disconnected
        if let config {
            setMountState(.unmounted, for: config)
            onStateChange?(config, .disconnected)
        }
    }

    /// Remove the convenience symlink for a connection that is no longer mounted, and put
    /// it back if a mount landed while the removal was suspended.
    ///
    /// `removeSymlink` resolves the mount URL first, so it suspends — and a `connect()`
    /// that completes inside that window creates exactly the link this call then deletes,
    /// leaving a mounted domain with no shortcut. The published mount state is the
    /// arbiter: only a mount that is current after the removal is restored.
    private func removeSymlinkPreservingCurrentMount(
        for config: ConnectionConfig,
        using mountProvider: any MountProvider
    ) async {
        try? await mountProvider.removeSymlink(for: config)
        guard mountState(for: config.id).isMounted else { return }
        do {
            _ = try await mountProvider.createSymlink(for: config)
        } catch {
            logger.warning(
                "Failed to restore the convenience symlink for \(config.domainIdentifier, privacy: .public) after removing a stale one: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Stop everything that could still publish a mount state or a convenience link for
    /// `id`, and wait for it.
    ///
    /// Refresh first: a failing refresh starts a repair on its way out, so waiting for
    /// the refresh means that repair is already covered by the symlink wait behind it.
    private func cancelAndAwaitMountStateWork(for id: UUID) async {
        await cancelAndAwaitRefresh(for: id)
        await cancelAndAwaitSymlinkWork(for: id)
    }

    /// Stop a refresh that would otherwise rewrite the bootstrap snapshot of a connection
    /// being torn down, edited, or removed.
    private func cancelAndAwaitRefresh(for id: UUID) async {
        guard let task = refreshTasks[id] else { return }
        task.cancel()
        await task.value
        if refreshTasks[id] == task {
            refreshTasks.removeValue(forKey: id)
        }
    }

    /// Stop anything that may still create the convenience symlink for `id`.
    ///
    /// Cancelling is not enough: mount resolution and mount repair can both be suspended
    /// *inside* `createSymlink`, so the link would be recreated after the teardown below
    /// removed it, leaving a symlink pointing at a connection that is gone. Awaiting the
    /// cancelled task serializes the two.
    private func cancelAndAwaitSymlinkWork(for id: UUID) async {
        if let task = mountResolutionTasks[id] {
            task.cancel()
            await task.value
            if mountResolutionTasks[id] == task {
                mountResolutionTasks.removeValue(forKey: id)
            }
        }
        if let task = mountRepairTasks[id] {
            task.cancel()
            await task.value
            if mountRepairTasks[id] == task {
                mountRepairTasks.removeValue(forKey: id)
            }
        }
    }

    /// Disconnect and unmount all known connections before terminating the app.
    public func shutdown() async {
        for task in reconnectTasks.values {
            task.cancel()
        }
        reconnectTasks.removeAll()
        // Cancelled here but awaited by each teardown below, so a pass suspended inside
        // createSymlink cannot recreate the link after its connection is torn down. A
        // repair belongs in the same set: it creates the same symlink and publishes the
        // same mounted state, so a connection with one pending still needs a teardown —
        // and so does a refresh, which rewrites the bootstrap snapshot and can start a
        // repair of its own.
        let pendingMountStateWorkIDs = Set(mountResolutionTasks.keys)
            .union(mountRepairTasks.keys)
            .union(refreshTasks.keys)
        for task in mountResolutionTasks.values {
            task.cancel()
        }
        for task in mountRepairTasks.values {
            task.cancel()
        }
        for task in refreshTasks.values {
            task.cancel()
        }
        // A connect that has not installed a filesystem or reached mounting yet is still
        // connection work. Cancelling it and running its teardown is what stops it
        // publishing a connection after shutdown returns. The teardown awaits that
        // cancelled attempt — which is why every wait below carries a deadline.
        let pendingConnectIDs = Set(connectTasks.keys)
        for task in connectTasks.values {
            task.cancel()
        }

        for config in connections where
            states[config.id]?.isConnected == true ||
            {
                if case .error = states[config.id] {
                    return true
                }
                return false
            }() ||
            mountState(for: config.id).isMounted ||
            mountState(for: config.id) == .mounting ||
            pendingMountStateWorkIDs.contains(config.id) ||
            pendingConnectIDs.contains(config.id) ||
            fileSystems[config.id] != nil {
            let id = config.id
            await withShutdownDeadline { [weak self] in
                await self?.disconnect(id)
            }
        }

        for id in Set(mountResolutionTasks.keys).union(mountRepairTasks.keys).union(refreshTasks.keys) {
            await withShutdownDeadline { [weak self] in
                await self?.cancelAndAwaitMountStateWork(for: id)
            }
        }
    }

    /// Run quit-time cleanup, giving up on it once the deadline passes.
    ///
    /// Every teardown deliberately *awaits* the work it cancels, so nothing can publish a
    /// mount, a symlink or a bootstrap snapshot after it returns. A backend or credential
    /// call that never returns from a cancelled operation would therefore hold the app
    /// open forever — `applicationShouldTerminate` replies `.terminateLater` and waits on
    /// exactly this. An abandoned pass keeps running in a process that is about to exit.
    private func withShutdownDeadline(_ work: @escaping @MainActor () async -> Void) async {
        let resumer = ShutdownDeadlineResumer()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Both tasks can only run at a suspension point, so the continuation is
            // installed before either of them can reach for it.
            resumer.continuation = continuation
            Task { @MainActor in
                await work()
                resumer.resume()
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.shutdownDeadlineNanoseconds)
                if resumer.resume() {
                    Self.shutdownLogger.error("Quit cleanup timed out; abandoning it")
                }
            }
        }
    }

    /// Attempt to reconnect with exponential backoff.
    public func reconnect(_ id: UUID) {
        reconnectTasks[id]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            for attempt in 0..<Self.maxRetries {
                let delay = Self.baseDelay * UInt64(1 << min(attempt, 4)) // 1s, 2s, 4s, 8s, 16s
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled { return }
                if self.isReconnectSatisfied(for: id) {
                    return
                }
                // A handshake or a mount still resolving is not a failed attempt;
                // connecting on top of it would drive the same domain twice.
                if self.isConnectionAttemptInProgress(for: id) {
                    continue
                }
                await self.connect(id)
                if self.isReconnectSatisfied(for: id) { return }
            }
        }
        reconnectTasks[id] = task
        // Cleared when the retry loop ends on its own, identity-checked so a newer attempt
        // survives. Without this a finished retry stays in the dictionary forever, where
        // `remove` and `shutdown` keep reading it as lifecycle work still to be waited on.
        Task { @MainActor [weak self] in
            await task.value
            guard let self, self.reconnectTasks[id] == task else { return }
            self.reconnectTasks.removeValue(forKey: id)
        }
    }

    /// Whether a retry has nothing left to do.
    ///
    /// With a mount provider a successful mount deliberately returns `ConnectionState`
    /// to `.disconnected` — the extension owns the session from then on — so the
    /// connection state cannot decide this, or every retry would remount the domain that
    /// just came up.
    private func isReconnectSatisfied(for id: UUID) -> Bool {
        guard mountProvider != nil else {
            return states[id]?.isConnected == true
        }
        return effectiveMountState(for: id).isMounted
    }

    private func isConnectionAttemptInProgress(for id: UUID) -> Bool {
        connectTasks[id] != nil
            || states[id] == .connecting
            || mountState(for: id) == .mounting
    }

    public func fileSystem(for id: UUID) -> (any RemoteFileSystem)? {
        fileSystems[id]
    }

    public func state(for id: UUID) -> ConnectionState {
        states[id] ?? .disconnected
    }

    /// Test connectivity without persisting the filesystem.
    public func testConnection(_ config: ConnectionConfig, credential: Credential) async -> Result<Void, Error> {
        guard let fs = registry.createFileSystem(config: config, credential: credential) else {
            return .failure(RemoteFileSystemError.unsupported(config.backendType.displayName))
        }
        let enumerationPath = config.remotePath.isEmpty ? RemotePath.root : RemotePath(config.remotePath)
        do {
            try await fs.connect()
        } catch {
            return .failure(error)
        }

        do {
            _ = try await fs.enumerate(at: enumerationPath)
        } catch {
            try? await fs.disconnect()
            return .failure(error)
        }

        do {
            try await fs.disconnect()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Best-effort reconciliation between the app-facing credential store and any
    /// mirrored provider snapshot store. This is especially important on startup so
    /// already-saved mounts can be enumerated by the File Provider extension without
    /// the extension touching Keychain items directly.
    public func syncCredentialSnapshots() async {
        for config in connections {
            do {
                _ = try await credentialProvider.credential(for: config.id)
            } catch {
                logger.warning(
                    "Failed to sync credential snapshot for \(config.domainIdentifier, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    public func reloadConnectionsFromStorage() async {
        let reloadedConnections: [ConnectionConfig]
        do {
            reloadedConnections = try storage.loadConnections()
        } catch {
            logger.error(
                "Failed to reload connections from storage: \(String(describing: error), privacy: .public)"
            )
            return
        }
        let currentConnections = connections
        let currentIDs = Set(currentConnections.map(\.id))
        let reloadedIDs = Set(reloadedConnections.map(\.id))
        var nextConnections = reloadedConnections

        for removedConfig in currentConnections where !reloadedIDs.contains(removedConfig.id) {
            await disconnect(removedConfig.id, using: removedConfig)
            guard isCleanupComplete(for: removedConfig.id) else {
                nextConnections.append(removedConfig)
                continue
            }
            if let mountProvider {
                do {
                    try await mountProvider.unregister(config: removedConfig)
                } catch MountError.domainNotFound {
                    logger.notice(
                        "Skipping unregister for missing domain \(removedConfig.domainIdentifier, privacy: .public) during reload cleanup"
                    )
                } catch {
                    logger.error(
                        "Failed to unregister removed connection \(removedConfig.name, privacy: .private) during reload: \(self.describe(error), privacy: .private)"
                    )
                    // The connection is kept, so it must not read as a clean disconnect:
                    // its domain is still registered and only the user retrying the
                    // removal can clear it.
                    let message = "Failed to unregister \(removedConfig.name): \(describe(error))"
                    let errorState = ConnectionState.error(message)
                    states[removedConfig.id] = errorState
                    setMountState(.error(message), for: removedConfig)
                    onStateChange?(removedConfig, errorState)
                    nextConnections.append(removedConfig)
                    continue
                }
            }

            states.removeValue(forKey: removedConfig.id)
            mountStates.removeValue(forKey: removedConfig.id)
            fileSystems.removeValue(forKey: removedConfig.id)
            connectionGenerations.removeValue(forKey: removedConfig.id)
            // Cancelled but left in place: the attempt clears its own entry once it
            // unwinds, which is also what resumes anyone still waiting on it.
            connectTasks[removedConfig.id]?.cancel()
            interruptedConnectionIDs.remove(removedConfig.id)
            reconnectTasks[removedConfig.id]?.cancel()
            reconnectTasks.removeValue(forKey: removedConfig.id)
            await cancelAndAwaitRefresh(for: removedConfig.id)
            await cancelAndAwaitSymlinkWork(for: removedConfig.id)
        }

        connections = nextConnections
        for config in nextConnections where !currentIDs.contains(config.id) {
            states[config.id] = .disconnected
        }

        // A connection edited on another device keeps its UUID, so neither loop above
        // reaches it. Publishing it only in memory leaves the domain serving the old
        // host, endpoint, bucket or remote path from its bootstrap snapshot while the UI
        // already shows the new one, so changed configs go through the registration path
        // — which also remounts the ones that are currently mounted.
        for config in nextConnections {
            guard let previousConfig = currentConnections.first(where: { $0.id == config.id }),
                  previousConfig != config else {
                continue
            }
            do {
                try await syncSavedConnectionRegistration(config, previousConfig: previousConfig)
            } catch {
                logger.error(
                    "Failed to re-register changed connection \(config.domainIdentifier, privacy: .public) during reload: \(self.describe(error), privacy: .private)"
                )
                // The row is already showing the edited config while the domain still
                // serves the previous one, and nothing retries this before the next
                // launch. Publishing the failure is what makes that desync visible
                // instead of leaving a green mount answering with the old host.
                let message = MFuseCoreL10n.string(
                    "connectionManager.error.reregisterChangedConnection",
                    fallback: "Failed to apply the updated settings for %1$@: %2$@. Reconnect or restart MFuse to retry.",
                    config.name,
                    describe(error)
                )
                let errorState = ConnectionState.error(message)
                states[config.id] = errorState
                setMountState(.error(message), for: config)
                onStateChange?(config, errorState)
            }
        }
    }

    // MARK: - Mount state

    public func mountState(for id: UUID) -> MountState {
        mountStates[id] ?? .unmounted
    }

    /// User-facing state that collapses the connection handshake into mount semantics.
    public func effectiveMountState(for id: UUID) -> MountState {
        let mountState = mountState(for: id)
        switch mountState {
        case .mounted, .mounting, .error:
            return mountState
        case .unmounted:
            break
        }

        // An attempt whose task exists but has not run yet holds no connection state at
        // all. Reporting it as unmounted let a batch Unmount skip the rows a batch Mount
        // had just started, and the mount they were bringing up landed after the unmount
        // had already finished.
        if connectTasks[id] != nil {
            return mountProvider == nil ? .unmounted : .mounting
        }

        switch state(for: id) {
        case .connecting, .connected:
            return mountProvider == nil ? .unmounted : .mounting
        case .error(let message):
            return .error(message)
        case .disconnected:
            return .unmounted
        }
    }

    /// Re-enumerate a mounted connection, repairing its state when the domain cannot be
    /// reached.
    ///
    /// Owned by the manager rather than the caller because `signalEnumerator` rewrites
    /// the extension's bootstrap snapshot: a refresh holding a config captured before an
    /// edit would put the old host back, and one still running after a removal would
    /// write a snapshot for a domain that is gone. The config is therefore read at
    /// execution time, checked against the generation, and tracked so teardown can cancel
    /// and wait for it.
    public func refreshMountedConnection(for id: UUID) async {
        if let inFlight = refreshTasks[id] {
            await inFlight.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh(for: id)
            self.refreshTasks.removeValue(forKey: id)
        }
        refreshTasks[id] = task
        await task.value
    }

    private func performRefresh(for id: UUID) async {
        guard let config = connections.first(where: { $0.id == id }),
              let mountProvider else {
            return
        }
        guard !isTeardownInFlight(for: id), !isRemovalInFlight(for: id) else { return }
        guard effectiveMountState(for: id).isMounted else { return }

        let generation = connectionGenerations[id, default: 0]
        do {
            try await mountProvider.signalEnumerator(for: config)
        } catch {
            // A teardown that cancelled this refresh is already publishing its own state;
            // repairing on the way out would fight it.
            if error is CancellationError || Task.isCancelled { return }
            guard isCurrentConnectionAttempt(for: id, generation: generation) else { return }
            logger.warning(
                "Failed to refresh \(config.domainIdentifier, privacy: .public): \(self.describe(error), privacy: .private)"
            )
            // Not reaching the domain is exactly when the row is still showing a mount
            // that is no longer there.
            await repairMountState(for: id)
        }
    }

    /// Best-effort mount state repair for already-registered File Provider domains.
    ///
    /// The repair recreates the convenience symlink, so it is tracked as a task that
    /// `disconnect` can cancel and wait for — see `cancelAndAwaitSymlinkWork(for:)`.
    public func repairMountState(for id: UUID) async {
        if let inFlight = mountRepairTasks[id] {
            await inFlight.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performMountRepair(for: id)
            self.mountRepairTasks.removeValue(forKey: id)
        }
        mountRepairTasks[id] = task
        await task.value
    }

    private func performMountRepair(for id: UUID) async {
        guard let config = connections.first(where: { $0.id == id }),
              let mountProvider else {
            return
        }
        // Waiting for the repairs already running is not enough: a repair that starts
        // after that wait still races the `removeSymlink` further down the teardown, and
        // one starting mid-removal relinks a domain that is about to be unregistered.
        guard !isTeardownInFlight(for: id), !isRemovalInFlight(for: id) else { return }

        let generation = connectionGenerations[id, default: 0]

        do {
            // A registered domain that was deliberately disconnected keeps a usable
            // CloudStorage URL, so the URL alone cannot say whether it is mounted —
            // startup sync classifies such a domain as unmounted, and so must this.
            let domainState = try await mountProvider.domainStates()
                .first { $0.identifier == config.domainIdentifier }
            guard isCurrentConnectionAttempt(for: id, generation: generation) else {
                return
            }
            guard let domainState, !domainState.isDisconnected else {
                // Reconciles a mount that disappeared behind the app's back: leaving the
                // row green keeps offering reveal and unmount for a domain that is gone.
                if mountState(for: id).isMounted {
                    // The convenience link outlives the domain otherwise, still pointing
                    // at a CloudStorage location nothing serves — startup sync and normal
                    // disconnect both remove it for exactly this transition. State first,
                    // link second: the removal suspends, and the helper reads the state to
                    // decide whether a mount landed in the meantime.
                    setMountState(.unmounted, for: config)
                    await removeSymlinkPreservingCurrentMount(for: config, using: mountProvider)
                }
                return
            }

            if let mountURL = try await mountProvider.mountURL(for: config) {
                // The user can unmount while the provider call above is suspended;
                // writing the observed state unconditionally would resurrect the mount.
                guard isCurrentConnectionAttempt(for: id, generation: generation) else {
                    return
                }
                do {
                    _ = try await mountProvider.createSymlink(for: config)
                } catch {
                    logger.warning(
                        "Failed to recreate convenience symlink for \(config.domainIdentifier, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
                // Cancellation is checked alongside the generation: shutdown cancels this
                // pass without advancing it, and publishing a mount there would contradict
                // the teardown running right behind it.
                guard !Task.isCancelled,
                      isCurrentConnectionAttempt(for: id, generation: generation) else {
                    return
                }
                setMountState(.mounted(path: mountURL.path), for: config)
                return
            }
        } catch {
            logger.warning(
                "Failed to repair mount state for \(config.domainIdentifier, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Sync mount states on startup: remove stale FP domains, rebuild symlinks for existing mounts.
    public func syncMounts() async {
        guard let mp = mountProvider else { return }
        // Captured before the snapshot is taken: every provider call below suspends, and
        // a disconnect landing in one of those windows must not have its teardown undone
        // by domain state that was observed before it ran.
        let generations = connections.reduce(into: [UUID: Int]()) { result, config in
            result[config.id] = connectionGenerations[config.id, default: 0]
        }
        do {
            let domainStates = try await mp.domainStates()
            let domainStatesByID = Dictionary(
                uniqueKeysWithValues: domainStates.map { ($0.identifier, $0) }
            )
            let knownDomainIDs = Set(connections.map(\.domainIdentifier))

            // Remove stale domains
            for domainID in domainStatesByID.keys where !knownDomainIDs.contains(domainID) {
                let remover = staleDomainRemover ?? _removeStaleProviderDomain
                try? await remover(domainID)
            }

            try? await cleanupOrphanedSymlinks(for: connections)

            // Rebuild mount states and symlinks for existing mounted configs
            for id in connections.map(\.id) {
                // Re-read instead of iterating the snapshot this loop started with: a save
                // landing mid-sync leaves that snapshot holding the config from before the
                // edit, and every provider call below persists what it is handed as the
                // domain's bootstrap snapshot.
                guard let config = connections.first(where: { $0.id == id }) else { continue }
                // Only connections this pass actually observed. One added while
                // `domainStates()` was in flight is missing from that list by construction,
                // and reconciling it against the list would classify a domain it just
                // mounted as gone — publishing `.unmounted` and removing its symlink.
                guard let generation = generations[config.id] else { continue }
                guard isCurrentConnectionAttempt(for: config.id, generation: generation),
                      !isTeardownInFlight(for: config.id),
                      connectTasks[config.id] == nil else {
                    continue
                }
                if let domainState = domainStatesByID[config.domainIdentifier] {
                    if domainState.isDisconnected {
                        // Awaited, not just cancelled: a pass suspended inside
                        // createSymlink would otherwise finish after the removal below
                        // and leave a link for a domain just classified as unmounted, and
                        // a refresh in flight would repair the state right back.
                        await cancelAndAwaitMountStateWork(for: config.id)
                        guard isCurrentConnectionAttempt(for: config.id, generation: generation) else {
                            continue
                        }
                        setMountState(.unmounted, for: config)
                        await removeSymlinkPreservingCurrentMount(for: config, using: mp)
                        continue
                    }

                    setMountState(.mounting, for: config)
                    do {
                        try await signalEnumeratorAsTrackedRefresh(for: config, using: mp)
                        guard isCurrentConnectionAttempt(for: config.id, generation: generation),
                              !isTeardownInFlight(for: config.id) else {
                            continue
                        }
                        // `syncMounts()` may discover an already-mounted File Provider domain
                        // after app relaunch. In that case the extension owns the active mount,
                        // not this process, so we intentionally drop any stale local entry from
                        // `fileSystems`, mark `states[config.id]` as `.disconnected`, keep the
                        // mount alive via `mountStates[config.id] = .mounting`, and let
                        // `scheduleMountResolution(for:using:)` refresh the mounted state after
                        // `mp.signalEnumerator(for:)`. This is why the UI can show a disconnected
                        // app-side connection while Finder still has an active mount, and it is
                        // also why failures here fall back to `mp.removeSymlink(for:)` instead of
                        // trying to recreate an in-process filesystem session.
                        fileSystems.removeValue(forKey: config.id)
                        states[config.id] = .disconnected
                        scheduleMountResolution(for: config, using: mp)
                    } catch {
                        // An edit, a teardown or a removal cancelled this pass and is
                        // publishing its own state; reporting a refresh failure on the way
                        // out would fight it.
                        if error is CancellationError { continue }
                        let desc = "Failed to refresh mounted domain \(config.domainIdentifier): \(describe(error))"
                        if isMissingFileProviderExtensionError(error) {
                            needsExtensionSetup = true
                        }
                        await cancelAndAwaitMountStateWork(for: config.id)
                        guard isCurrentConnectionAttempt(for: config.id, generation: generation) else {
                            continue
                        }
                        let errorState = ConnectionState.error(desc)
                        states[config.id] = errorState
                        onStateChange?(config, errorState)
                        setMountState(.error(desc), for: config)
                        await removeSymlinkPreservingCurrentMount(for: config, using: mp)
                    }
                } else {
                    await cancelAndAwaitMountStateWork(for: config.id)
                    guard isCurrentConnectionAttempt(for: config.id, generation: generation) else {
                        continue
                    }
                    setMountState(.unmounted, for: config)
                    await removeSymlinkPreservingCurrentMount(for: config, using: mp)
                }
            }
        } catch {
            // Best-effort, but not silent: every mount state below stays at its default
            // when the domain list cannot be read, and nothing else reports why.
            logger.error(
                "Failed to synchronize mounts on startup: \(self.describe(error), privacy: .public)"
            )
        }
    }

    /// Re-enumerate a domain during startup sync as *tracked* refresh work.
    ///
    /// `signalEnumerator` rewrites the extension's bootstrap snapshot, so a pass still in
    /// flight while a connection is edited would put the old config back after the new one
    /// was registered. Registering it as this connection's refresh is what lets
    /// `cancelAndAwaitRefresh(for:)` — which every edit, teardown and removal runs — cancel
    /// it *and wait for it* before writing a snapshot of its own.
    private func signalEnumeratorAsTrackedRefresh(
        for config: ConnectionConfig,
        using mountProvider: any MountProvider
    ) async throws {
        await cancelAndAwaitRefresh(for: config.id)
        let outcome = SignalOutcome()
        let task = Task { @MainActor in
            do {
                try await mountProvider.signalEnumerator(for: config)
            } catch {
                outcome.error = error
            }
        }
        refreshTasks[config.id] = task
        await task.value
        if refreshTasks[config.id] == task {
            refreshTasks.removeValue(forKey: config.id)
        }
        // Checked before the outcome: a provider that ignores cancellation reports success,
        // and treating that as one would let this pass go on to publish a mount state for
        // the very work a teardown or an edit just cancelled.
        if task.isCancelled {
            throw CancellationError()
        }
        if let error = outcome.error {
            throw error
        }
    }

    public func autoMountConfiguredConnections() async {
        let targets = connections.filter { config in
            guard config.autoMountOnLaunch else {
                return false
            }

            if effectiveMountState(for: config.id).isMounted || mountState(for: config.id) == .mounting {
                return false
            }

            if state(for: config.id) == .connecting {
                return false
            }

            return true
        }

        for config in targets {
            await connect(config.id)
        }
    }

    public func syncSavedConnectionRegistration(
        _ config: ConnectionConfig,
        previousConfig: ConnectionConfig?
    ) async throws {
        guard let mountProvider else { return }

        // A refresh in flight is holding the config from before this edit, and its
        // `signalEnumerator` would write that one back over the snapshot registered here.
        await cancelAndAwaitRefresh(for: config.id)
        // A removal that ran while this was suspended has already taken the row, the
        // domain and the credential; registering now would put an orphan domain and
        // bootstrap snapshot back for a connection that no longer exists.
        guard isRegistrableConnection(config.id) else {
            throw ConnectionManagerError.connectionNotFound(config.id)
        }
        try await mountProvider.ensureRegistered(config: config)
        // Registration suspends too, so the same removal can land inside it. What it
        // created is taken straight back out rather than left behind.
        guard isRegistrableConnection(config.id) else {
            try? await mountProvider.unregister(config: config)
            throw ConnectionManagerError.connectionNotFound(config.id)
        }

        // Read *after* the suspensions above rather than on entry: the user can unmount
        // while `ensureRegistered` is in flight, and a remount decided from the earlier
        // state would bring back the mount they just took down.
        //
        // `.mounting` counts as much as `.mounted`, and covers a connect still in its
        // handshake — `effectiveMountState` reports one whichever stage it has reached.
        // That attempt is holding the config from before this edit and would go on to
        // reconnect, signal and resolve a mount for it, leaving a domain serving the old
        // endpoint under a row showing the new one. The teardown below is what fences it:
        // it cancels the attempt and waits for it, and the connect that follows rebuilds
        // everything from the config that is current now.
        let currentMountState = effectiveMountState(for: config.id)
        if currentMountState.isMounted || currentMountState == .mounting {
            await disconnect(config.id, using: previousConfig)
            // The teardown publishes its own failure but cannot report one by returning, so
            // what it left behind is checked here: a filesystem that would not close or a
            // domain still connected is old runtime state for the *previous* config, and
            // handing that back as a completed switch tells the caller — a save, or a
            // reload that has already published the edited row — that the connection is now
            // serving what it shows.
            guard isCleanupComplete(for: config.id) else {
                throw ConnectionManagerError.cleanupFailed(config.id)
            }
            // A remount that cannot reach the server is not a registration failure: the
            // domain carries the new config either way, and the row reports the error.
            await connect(config.id)
            return
        }

        if let previousConfig, previousConfig.name != config.name {
            try? await mountProvider.removeSymlink(for: previousConfig)
        }

        try? await mountProvider.removeSymlink(for: config)
        try await mountProvider.disconnect(config: config)
        setMountState(.unmounted, for: config)
    }

    private func _removeStaleProviderDomain(id: String) async throws {
        #if canImport(FileProvider)
        let domains = try await NSFileProviderManager.domains()
        if let domain = domains.first(where: { $0.identifier.rawValue == id }) {
            try await NSFileProviderManager.remove(domain)
        }
        #endif
    }

    private func resolveMountPath(
        for config: ConnectionConfig,
        using mountProvider: any MountProvider
    ) async throws -> String {
        for attempt in 0..<Self.mountURLRetryCount {
            try Task.checkCancellation()
            if let url = try await mountProvider.mountURL(for: config) {
                try Task.checkCancellation()
                return url.path
            }

            if attempt < Self.mountURLRetryCount - 1 {
                try Task.checkCancellation()
                try? await Task.sleep(nanoseconds: Self.mountURLRetryDelay)
                try Task.checkCancellation()
            }
        }

        throw MountError.mountFailed("Mount path is not ready yet for \(config.name)")
    }

    private func connectFileSystemWithRetry(
        _ fileSystem: any RemoteFileSystem,
        for config: ConnectionConfig
    ) async throws {
        var lastError: Error?

        for attempt in 0..<Self.transientConnectionRetryCount {
            do {
                try await fileSystem.connect()
                return
            } catch {
                lastError = error
                guard attempt < Self.transientConnectionRetryCount - 1,
                      shouldRetryTransientConnectionError(error) else {
                    throw error
                }

                logger.warning(
                    "Retrying transient connection failure for \(config.domainIdentifier, privacy: .public): \(self.describe(error), privacy: .public)"
                )
                // Not `try?`: swallowing cancellation here would run another attempt and
                // establish a connection for a caller that already gave up.
                try await Task.sleep(nanoseconds: Self.transientConnectionRetryDelay)
            }
        }

        if let lastError {
            throw lastError
        }
    }

    private func scheduleMountResolution(
        for config: ConnectionConfig,
        using mountProvider: any MountProvider
    ) {
        // Same window as `performMountRepair`: a resolution started mid-teardown would
        // recreate the symlink the teardown is about to remove.
        guard !isTeardownInFlight(for: config.id), !isRemovalInFlight(for: config.id) else { return }
        // Cancelling the superseded pass is not enough. It can be suspended inside
        // `createSymlink`, and dropping the only handle to it lets it finish after a
        // later teardown removed the link. Chaining it onto the replacement keeps the
        // tracked task a proxy for every pass a teardown still has to wait for.
        let supersededTask = mountResolutionTasks[config.id]
        supersededTask?.cancel()
        let generation = connectionGenerations[config.id, default: 0]
        mountResolutionTasks[config.id] = Task { @MainActor [weak self] in
            await supersededTask?.value
            guard let self else { return }
            await self.resolveMountState(
                for: config,
                using: mountProvider,
                generation: generation
            )
            // A replaced task is cancelled before the replacement is stored, so this
            // cannot delete the entry of the task that superseded it. Teardown clears
            // cancelled tasks itself, once it has waited for them.
            if !Task.isCancelled {
                self.mountResolutionTasks.removeValue(forKey: config.id)
            }
        }
    }

    private func resolveMountState(
        for config: ConnectionConfig,
        using mountProvider: any MountProvider,
        generation: Int
    ) async {
        do {
            let path = try await resolveMountPath(for: config, using: mountProvider)
            try Task.checkCancellation()
            do {
                if try await mountProvider.createSymlink(for: config) == nil {
                    logger.warning(
                        "Mounted domain \(config.domainIdentifier, privacy: .public) without creating convenience symlink"
                    )
                }
            } catch {
                logger.warning(
                    "Mounted domain \(config.domainIdentifier, privacy: .public) but failed to create convenience symlink: \(String(describing: error), privacy: .public)"
                )
            }
            try Task.checkCancellation()
            // The provider calls above suspend, and a task that was replaced rather than
            // cancelled still gets here — publishing then would resurrect a mount the
            // user has already torn down.
            guard isCurrentConnectionAttempt(for: config.id, generation: generation) else { return }
            setMountState(.mounted(path: path), for: config)
        } catch {
            if Task.isCancelled { return }
            let desc = describe(error)
            if isMissingFileProviderExtensionError(error) {
                needsExtensionSetup = true
            }
            guard isCurrentConnectionAttempt(for: config.id, generation: generation) else { return }
            setMountState(.error(desc), for: config)
        }
    }

    private func restoreRemovedConnectionState(
        for id: UUID,
        connections restoredConnections: [ConnectionConfig],
        state restoredState: ConnectionState?,
        mountState restoredMountState: MountState?,
        fileSystem restoredFileSystem: (any RemoteFileSystem)?
    ) {
        connections = restoredConnections
        if let restoredState {
            states[id] = restoredState
        } else {
            states.removeValue(forKey: id)
        }
        if let restoredMountState {
            mountStates[id] = restoredMountState
        } else {
            mountStates.removeValue(forKey: id)
        }
        if let restoredFileSystem {
            fileSystems[id] = restoredFileSystem
        } else {
            fileSystems.removeValue(forKey: id)
        }
    }

    private func restoreRemovedConnectionStateAndPersist(
        for id: UUID,
        connections restoredConnections: [ConnectionConfig],
        state restoredState: ConnectionState?,
        mountState restoredMountState: MountState?,
        fileSystem restoredFileSystem: (any RemoteFileSystem)?
    ) throws {
        restoreRemovedConnectionState(
            for: id,
            connections: restoredConnections,
            state: restoredState,
            mountState: restoredMountState,
            fileSystem: restoredFileSystem
        )
        try storage.saveConnections(restoredConnections)
    }

    /// Re-register the domain a failed removal already unregistered.
    ///
    /// Returns a message when the domain could not be restored: the connection itself is
    /// kept, so reporting only the primary failure would leave a row whose domain is
    /// gone and no indication that mounting it again needs the app restarted.
    private func restoreDomainRegistration(for config: ConnectionConfig) async -> String? {
        guard let mountProvider else { return nil }
        do {
            try await mountProvider.ensureRegistered(config: config)
            return nil
        } catch {
            logger.error(
                "Failed to restore the domain for \(config.domainIdentifier, privacy: .public) after a failed removal: \(self.describe(error), privacy: .private)"
            )
            return MFuseCoreL10n.string(
                "connectionManager.error.restoreRegistration",
                fallback: "Failed to restore the File Provider domain: %@",
                describe(error)
            )
        }
    }

    private func removalError(
        primary: Error,
        restoreFailures: [String],
        for config: ConnectionConfig
    ) -> Error {
        guard !restoreFailures.isEmpty else { return primary }
        return RemoteFileSystemError.operationFailed(
            MFuseCoreL10n.string(
                "connectionManager.error.removeWithRestoreFailures",
                fallback: "Failed to remove connection %1$@: %2$@. %3$@",
                config.id.uuidString,
                describe(primary),
                restoreFailures.joined(separator: " ")
            )
        )
    }

    /// Whether any `remove(_:)` call for this connection is still running.
    func isRemovalInFlight(for id: UUID) -> Bool {
        removalTasks[id] != nil
    }

    /// Whether a domain may be registered for this connection: it is one of ours, and
    /// nothing is in the middle of taking it away.
    private func isRegistrableConnection(_ id: UUID) -> Bool {
        connections.contains(where: { $0.id == id }) && !isRemovalInFlight(for: id)
    }

    /// Whether a teardown for this connection is running, from the moment `disconnect`
    /// starts one until `performDisconnect` returns. Symlink work must not begin inside
    /// that window: `removeSymlink` runs in the middle of it.
    func isTeardownInFlight(for id: UUID) -> Bool {
        disconnectTasks[id] != nil
    }

    /// Whether a teardown or a removal is running for this connection.
    ///
    /// The published mount state lags both: `performDisconnect` removes the convenience
    /// symlink well before it publishes `.unmounted`, so anything that acts on a mount —
    /// revealing it in Finder, above all — has to consult this too or it will act on one
    /// whose links are already gone.
    public func isLifecycleTeardownInFlight(for id: UUID) -> Bool {
        isTeardownInFlight(for: id) || isRemovalInFlight(for: id)
    }

    private func isCleanupComplete(for id: UUID) -> Bool {
        let connectionIsDisconnected = states[id]?.isConnected != true
        let mountIsStopped = mountProvider == nil || mountState(for: id) == .unmounted

        return connectionIsDisconnected
            && mountIsStopped
            && mountResolutionTasks[id] == nil
            && mountRepairTasks[id] == nil
            && refreshTasks[id] == nil
            && fileSystems[id] == nil
    }

    @discardableResult
    private func advanceConnectionGeneration(for id: UUID) -> Int {
        let nextGeneration = connectionGenerations[id, default: 0] + 1
        connectionGenerations[id] = nextGeneration
        return nextGeneration
    }

    private func isCurrentConnectionAttempt(for id: UUID, generation: Int) -> Bool {
        guard connectionGenerations[id, default: 0] == generation else {
            return false
        }
        return connections.contains(where: { $0.id == id })
    }

    /// Drop a filesystem built for an attempt nobody is waiting for.
    ///
    /// A failure here used to be swallowed together with the last reference to it, which
    /// leaked a session that is still open on the remote. Publishing it instead makes the
    /// next connect or teardown retry the disconnect, and makes `isCleanupComplete`
    /// report the connection as not yet clean rather than silently losing it.
    private func discardFileSystem(
        _ fileSystem: any RemoteFileSystem,
        for id: UUID,
        context: String
    ) async {
        do {
            try await fileSystem.disconnect()
        } catch {
            logger.error(
                "Failed to disconnect the filesystem of an \(context, privacy: .public) for \(id.uuidString, privacy: .private): \(self.describe(error), privacy: .public)"
            )
            fileSystems[id] = fileSystem
        }
    }

    private func disconnectMountedFileSystem(
        _ fileSystem: any RemoteFileSystem,
        for config: ConnectionConfig,
        context: String
    ) async -> String? {
        do {
            try await fileSystem.disconnect()
            return nil
        } catch {
            let message = "Failed to disconnect filesystem for \(config.name) \(context): \(describe(error))"
            logger.error(
                "Failed to disconnect filesystem for connection \(config.name, privacy: .private) \(context, privacy: .public): \(self.describe(error), privacy: .public)"
            )
            return message
        }
    }

    private func setMountState(_ state: MountState, for config: ConnectionConfig) {
        mountStates[config.id] = state
        onMountStateChange?(config, state)
    }

    private func isMissingFileProviderExtensionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        #if canImport(FileProvider)
        if nsError.domain == NSFileProviderErrorDomain,
           nsError.code == NSFileProviderError.Code.providerNotFound.rawValue {
            return true
        }
        #endif
        return MountError.matchesExtensionNotEnabledMessage(describe(error))
    }

    private func shouldRetryTransientConnectionError(_ error: Error) -> Bool {
        if case RemoteFileSystemError.authenticationFailed = error {
            return false
        }

        let normalizedDescription = describe(error).lowercased()
        let transientIndicators = [
            "no route to host",
            "host is down",
            "network is down",
            "network is unreachable",
            "timed out"
        ]
        return transientIndicators.contains { normalizedDescription.contains($0) }
    }

    private func describe(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty,
           !description.hasPrefix("The operation couldn’t be completed.") {
            return description
        }

        let described = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        if !described.isEmpty, !described.hasPrefix("Error Domain=") {
            return described
        }

        let localized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return localized.isEmpty ? String(reflecting: error) : localized
    }

    private func cleanupOrphanedSymlinks(for connections: [ConnectionConfig]) async throws {
        let fm = FileManager.default
        guard let mountProvider else { return }
        let baseDir = mountProvider.symlinkBaseURL

        guard fm.fileExists(atPath: baseDir.path),
              let contents = try? fm.contentsOfDirectory(atPath: baseDir.path) else {
            return
        }

        let knownNames = Set(connections.map(FileProviderMountProvider.symlinkFilename(for:)))
        for name in contents where !knownNames.contains(name) {
            let candidateURL = baseDir.appendingPathComponent(name)
            guard FileProviderMountProvider.shouldRemoveManagedSymlink(at: candidateURL, fileManager: fm) else {
                continue
            }
            try? fm.removeItem(at: candidateURL)
        }
    }
}
