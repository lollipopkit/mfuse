import Foundation
#if canImport(FileProvider)
import FileProvider
#endif
import os.log

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
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var mountResolutionTasks: [UUID: Task<Void, Never>] = [:]
    var staleDomainRemover: ((String) async throws -> Void)?

    /// Optional mount provider – when set, connect() auto-mounts and disconnect() auto-unmounts.
    public var mountProvider: (any MountProvider)?

    /// Optional callback for state change notifications (connect/disconnect/error).
    public var onStateChange: ((ConnectionConfig, ConnectionState) -> Void)?

    /// Optional callback for mount state change notifications.
    public var onMountStateChange: ((ConnectionConfig, MountState) -> Void)?

    private static let maxRetries = 5
    private static let baseDelay: UInt64 = 1_000_000_000 // 1 second in nanoseconds
    private static let mountURLRetryCount = 20
    private static let mountURLRetryDelay: UInt64 = 500_000_000 // 500 ms in nanoseconds
    private static let transientConnectionRetryCount = 2
    private static let transientConnectionRetryDelay: UInt64 = 750_000_000 // 750 ms in nanoseconds

    public init(
        storage: SharedStorage,
        credentialProvider: CredentialProvider,
        registry: BackendRegistry = .shared
    ) {
        self.storage = storage
        self.credentialProvider = credentialProvider
        self.registry = registry
        self.connections = storage.loadConnections()
    }

    // MARK: - CRUD

    public func add(_ config: ConnectionConfig) throws {
        connections.append(config)
        states[config.id] = .disconnected
        do {
            try storage.saveConnections(connections)
        } catch {
            connections.removeAll { $0.id == config.id }
            states.removeValue(forKey: config.id)
            throw error
        }
    }

    public func update(_ config: ConnectionConfig) throws {
        if let idx = connections.firstIndex(where: { $0.id == config.id }) {
            let previous = connections[idx]
            connections[idx] = config
            do {
                try storage.saveConnections(connections)
            } catch {
                connections[idx] = previous
                throw error
            }
        }
    }

    public func remove(_ config: ConnectionConfig) async throws {
        let shouldCleanupMount = states[config.id]?.isConnected == true
            || mountState(for: config.id).isMounted
            || mountState(for: config.id) == .mounting
            || mountResolutionTasks[config.id] != nil
        if shouldCleanupMount {
            await disconnect(config.id)
        }
        let previousConnections = connections
        let previousState = states[config.id]
        let previousMountState = mountStates[config.id]
        let previousFileSystem = fileSystems[config.id]
        connections.removeAll { $0.id == config.id }
        states.removeValue(forKey: config.id)
        mountStates.removeValue(forKey: config.id)
        fileSystems.removeValue(forKey: config.id)
        do {
            try storage.saveConnections(connections)
        } catch {
            connections = previousConnections
            if let previousState {
                states[config.id] = previousState
            }
            if let previousMountState {
                mountStates[config.id] = previousMountState
            }
            if let previousFileSystem {
                fileSystems[config.id] = previousFileSystem
            }
            throw error
        }
        do {
            try await credentialProvider.delete(for: config.id)
        } catch {
            throw RemoteFileSystemError.operationFailed(
                "Removed connection \(config.id.uuidString) but failed to delete its credential: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Connection lifecycle

    public func connect(_ id: UUID) async {
        guard let config = connections.first(where: { $0.id == id }) else { return }
        states[id] = .connecting

        do {
            let credential = try await credentialProvider.credential(for: id) ?? Credential()
            guard let fs = registry.createFileSystem(config: config, credential: credential) else {
                let errorState = ConnectionState.error("Unsupported backend: \(config.backendType.displayName)")
                states[id] = errorState
                onStateChange?(config, errorState)
                return
            }
            try await connectFileSystemWithRetry(fs, for: config)
            fileSystems[id] = fs
            states[id] = .connected
            onStateChange?(config, .connected)

            // Auto-mount if mount provider is set
            if let mp = mountProvider {
                setMountState(.mounting, for: config)
                do {
                    try await mp.mount(config: config)
                    if let disconnectFailure = await disconnectMountedFileSystem(
                        fs,
                        for: config,
                        context: "after mounting"
                    ) {
                        let errorState = ConnectionState.error(disconnectFailure)
                        states[id] = errorState
                        onStateChange?(config, errorState)
                        scheduleMountResolution(for: config, using: mp)
                        return
                    }
                    fileSystems.removeValue(forKey: id)
                    let disconnectedState = ConnectionState.disconnected
                    states[id] = disconnectedState
                    onStateChange?(config, disconnectedState)
                    try? await mp.signalEnumerator(for: config)
                    scheduleMountResolution(for: config, using: mp)
                } catch {
                    var desc = describe(error)
                    if isMissingFileProviderExtensionError(error) {
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
                    let errorState = ConnectionState.error(desc)
                    states[id] = errorState
                    onStateChange?(config, errorState)
                    setMountState(.error(desc), for: config)
                }
            }
        } catch {
            let errorState = ConnectionState.error(describe(error))
            states[id] = errorState
            onStateChange?(config, errorState)
        }
    }

    public func disconnect(_ id: UUID) async {
        reconnectTasks[id]?.cancel()
        reconnectTasks.removeValue(forKey: id)
        mountResolutionTasks[id]?.cancel()
        mountResolutionTasks.removeValue(forKey: id)

        let config = connections.first(where: { $0.id == id })
        var cleanupFailures: [String] = []
        var didDisconnectFileSystem = false

        if let config, let mp = mountProvider {
            do {
                try await mp.removeSymlink(for: config)
            } catch {
                let message = "Failed to remove symlink for \(config.name): \(describe(error))"
                logger.error("\(message, privacy: .public)")
                cleanupFailures.append(message)
            }

            do {
                try await mp.unmount(config: config)
            } catch {
                let message = "Failed to unmount \(config.name): \(describe(error))"
                logger.error("\(message, privacy: .public)")
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
                logger.error("\(message, privacy: .public)")
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
            if mountProvider != nil {
                setMountState(.unmounted, for: config)
            }
            onStateChange?(config, .disconnected)
        }
    }

    /// Disconnect and unmount all known connections before terminating the app.
    public func shutdown() async {
        for task in reconnectTasks.values {
            task.cancel()
        }
        reconnectTasks.removeAll()
        let pendingMountResolutionIDs = Set(mountResolutionTasks.keys)
        for task in mountResolutionTasks.values {
            task.cancel()
        }
        mountResolutionTasks.removeAll()

        for config in connections where
            states[config.id]?.isConnected == true ||
            mountState(for: config.id).isMounted ||
            mountState(for: config.id) == .mounting ||
            pendingMountResolutionIDs.contains(config.id) {
            await disconnect(config.id)
        }
    }

    /// Attempt to reconnect with exponential backoff.
    public func reconnect(_ id: UUID) {
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = Task { [weak self] in
            guard let self else { return }
            for attempt in 0..<Self.maxRetries {
                let delay = Self.baseDelay * UInt64(1 << min(attempt, 4)) // 1s, 2s, 4s, 8s, 16s
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled { return }
                if self.states[id]?.isConnected == true {
                    return
                }
                await self.connect(id)
                if self.states[id]?.isConnected == true { return }
            }
        }
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
        do {
            try await fs.connect()
        } catch {
            return .failure(error)
        }

        do {
            _ = try await fs.enumerate(at: .root)
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

        switch state(for: id) {
        case .connecting, .connected:
            return mountProvider == nil ? .unmounted : .mounting
        case .error(let message):
            return .error(message)
        case .disconnected:
            return .unmounted
        }
    }

    /// Best-effort mount state repair for already-registered File Provider domains.
    public func repairMountState(for id: UUID) async {
        guard let config = connections.first(where: { $0.id == id }),
              let mountProvider else {
            return
        }

        do {
            if let mountURL = try await mountProvider.mountURL(for: config) {
                do {
                    _ = try await mountProvider.createSymlink(for: config)
                } catch {
                    logger.warning(
                        "Failed to recreate convenience symlink for \(config.domainIdentifier, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
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
        do {
            let domainIDs = try await mp.mountedDomains()
            let knownDomainIDs = Set(connections.map(\.domainIdentifier))

            // Remove stale domains
            for domainID in domainIDs where !knownDomainIDs.contains(domainID) {
                let remover = staleDomainRemover ?? _removeStaleProviderDomain
                try? await remover(domainID)
            }

            try? await cleanupOrphanedSymlinks(for: connections)

            // Rebuild mount states and symlinks for existing mounted configs
            for config in connections {
                if domainIDs.contains(config.domainIdentifier) {
                    setMountState(.mounting, for: config)
                    do {
                        try await mp.signalEnumerator(for: config)
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
                        states[config.id] = .disconnected
                        mountResolutionTasks[config.id]?.cancel()
                        mountResolutionTasks.removeValue(forKey: config.id)
                        setMountState(.unmounted, for: config)
                        try? await mp.removeSymlink(for: config)
                    }
                } else {
                    mountResolutionTasks[config.id]?.cancel()
                    mountResolutionTasks.removeValue(forKey: config.id)
                    setMountState(.unmounted, for: config)
                    try? await mp.removeSymlink(for: config)
                }
            }
        } catch {
            // Sync is best-effort
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
                try? await Task.sleep(nanoseconds: Self.transientConnectionRetryDelay)
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
        mountResolutionTasks[config.id]?.cancel()
        mountResolutionTasks[config.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let path = try await self.resolveMountPath(for: config, using: mountProvider)
                try Task.checkCancellation()
                do {
                    if try await mountProvider.createSymlink(for: config) == nil {
                        self.logger.warning(
                            "Mounted domain \(config.domainIdentifier, privacy: .public) without creating convenience symlink"
                        )
                    }
                } catch {
                    self.logger.warning(
                        "Mounted domain \(config.domainIdentifier, privacy: .public) but failed to create convenience symlink: \(String(describing: error), privacy: .public)"
                    )
                }
                try Task.checkCancellation()
                self.setMountState(.mounted(path: path), for: config)
            } catch {
                if Task.isCancelled { return }
                let desc = self.describe(error)
                if self.isMissingFileProviderExtensionError(error) {
                    self.needsExtensionSetup = true
                }
                self.setMountState(.error(desc), for: config)
            }
            self.mountResolutionTasks.removeValue(forKey: config.id)
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
            logger.error("\(message, privacy: .public)")
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
            "timed out",
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
