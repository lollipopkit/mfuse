import Foundation
import FileProvider
import os.log

/// Serializes the operations of one connection that must not interleave.
///
/// Resolving a domain's CloudStorage path and acting on its convenience link are two
/// steps with a suspension between them, and a rename moves that path: a pass that
/// resolved the old one could otherwise resume after a later pass wrote the new one and
/// put the stale destination back. Renames take the same lock, so a resolution cannot be
/// invalidated while it is being acted on.
///
/// Operations run in the order they arrive: a rename that reached this before a link
/// creation must also run before it, or the link is written against the path the rename
/// was about to move. Resuming every waiter and letting them race back in would decide
/// that by executor scheduling, and would let an operation arriving at that moment take
/// the lock ahead of callers that were already queued.
///
/// Not reentrant: nothing inside a held section takes the lock again.
actor MountOperationCoordinator {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var busyKeys: Set<String> = []
    private var waiters: [String: [Waiter]] = [:]

    /// Takes the lock, or throws if the caller is cancelled before it gets there.
    ///
    /// Only the *wait* answers cancellation: a caller parked here has not begun its
    /// section, so withdrawing abandons nothing, while a holder that stopped halfway is
    /// what this exists to prevent and is untouched. Waiting regardless made a teardown
    /// depend on work it had nothing to do with — `ConnectionManager` cancels mount
    /// resolution and repair and then *awaits* them, so a cancelled pass queued behind an
    /// unrelated registration or link operation had to sit that operation out before it
    /// could unwind, and an Unmount or a Remove waited with it.
    ///
    /// A caller that is handed the lock and only then cancelled still runs its section, as
    /// an uncontended one does: the lock is held by then, and dropping it there is the
    /// half-finished section this serializes to avoid.
    func acquire(_ key: String) async throws {
        guard busyKeys.contains(key) else {
            busyKeys.insert(key)
            return
        }
        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // The handler below has nothing to withdraw until the waiter is registered,
                // so a cancellation that lands first is answered here.
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters[key, default: []].append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.withdraw(waiterID, from: key) }
        }
        // Resumed holding the lock, handed over by `release`. Re-checking `busyKeys` here
        // instead is what would let a newcomer overtake this caller.
        guard acquired else { throw CancellationError() }
    }

    func release(_ key: String) {
        guard var queue = waiters[key], !queue.isEmpty else {
            busyKeys.remove(key)
            waiters.removeValue(forKey: key)
            return
        }
        let next = queue.removeFirst()
        if queue.isEmpty {
            waiters.removeValue(forKey: key)
        } else {
            waiters[key] = queue
        }
        // `busyKeys` stays set: ownership passes straight to the caller that has waited
        // longest, so an operation arriving now queues behind it rather than racing it.
        next.continuation.resume(returning: true)
    }

    /// Give up a place in the queue for a caller that was cancelled before its turn came.
    ///
    /// A waiter `release` has already taken is simply gone from the queue: ownership was
    /// handed over, and the caller keeps it — resuming it a second time would trap, and
    /// dropping the lock on its behalf would hand the same section to two callers.
    private func withdraw(_ waiterID: UUID, from key: String) {
        guard var queue = waiters[key],
              let index = queue.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = queue.remove(at: index)
        if queue.isEmpty {
            waiters.removeValue(forKey: key)
        } else {
            waiters[key] = queue
        }
        waiter.continuation.resume(returning: false)
    }

    /// Test seam: how many callers are parked behind the operation holding this key.
    func waitingCount(for key: String) -> Int {
        waiters[key]?.count ?? 0
    }
}

/// MountProvider backed by macOS File Provider (NSFileProviderDomain).
/// Mounts appear under ~/Library/CloudStorage/. Convenience links are created in a writable shortcuts directory.
public final class FileProviderMountProvider: MountProvider {

    private static let logger = Logger(
        subsystem: "com.lollipopkit.mfuse.core",
        category: "FileProviderMountProvider"
    )

    public static let defaultSymlinkBaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("MFuse", isDirectory: true)

    /// Base directory for convenience symlinks.
    public let symlinkBaseURL: URL

    /// Test seams for `unregister`'s two steps, which exist so its ordering — the domain
    /// before the bootstrap config it is the last fallback for — can be exercised without
    /// a registered File Provider domain. Never set in production.
    /// `nonisolated(unsafe)`, and only sound because of that "never in production": a
    /// test sets these once, before the provider is handed to anything that could call it
    /// concurrently.
    nonisolated(unsafe) var removeRegisteredDomainOverride: ((ConnectionConfig) async throws -> Void)?
    nonisolated(unsafe) var removeBootstrapConfigOverride: ((ConnectionConfig) throws -> Void)?
    /// Test seam: replaces the CloudStorage lookup so a resolution can be held at the
    /// point where another pass interleaves. Never set in production.
    nonisolated(unsafe) var resolveMountURLOverride: ((ConnectionConfig) async throws -> URL?)?

    private let operationCoordinator = MountOperationCoordinator()

    public init(
        symlinkBaseURL: URL = defaultSymlinkBaseURL
    ) {
        self.symlinkBaseURL = symlinkBaseURL
    }

    public func ensureRegistered(config: ConnectionConfig) async throws {
        // A rename registers a new display name, which is what moves the domain's
        // CloudStorage path — the link operations resolve that path, so this cannot run
        // while one of them is between its resolution and its write.
        try await withMountOperationLock(for: config) {
            try await performEnsureRegistered(config: config)
        }
    }

    private func performEnsureRegistered(config: ConnectionConfig) async throws {
        // What the rollback below puts back. The lookup can answer `nil` and `add` still
        // report a duplicate — the domain exists but was not listed yet — so the refresh
        // path records what it removed here: rolling back to "there was nothing" would then
        // remove the replacement and leave the connection with no domain at all.
        var existingDomain = try await findDomain(for: config)
        let domain = try makeDomain(for: config)

        do {
            try await NSFileProviderManager.add(domain)
        } catch {
            if isExtensionNotEnabledError(error) {
                throw MountError.extensionNotEnabled
            }
            if shouldRetryMountAfterDomainRefresh(error) {
                var removedDomain: NSFileProviderDomain?
                if let stale = try await findDomain(for: config) {
                    try await NSFileProviderManager.remove(stale)
                    removedDomain = stale
                    existingDomain = stale
                    try await Task.sleep(nanoseconds: FileProviderConstants.domainRemovalSettleNanoseconds)
                }
                do {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    try Task.checkCancellation()
                    try await NSFileProviderManager.add(domain)
                } catch {
                    // The refresh took the registered domain out to put a fresh one in its
                    // place, and the replacement never arrived — through a failure or
                    // through the cancellation the waits above observe. Every caller reads
                    // a throw from here as "the registration is unchanged": a save reports
                    // that it will retry on the next launch, a reload keeps the row. Left
                    // as it is, the mount is simply gone until then, so what was removed
                    // goes back. Best effort, and never at the cost of the failure itself.
                    if let removedDomain {
                        do {
                            try await NSFileProviderManager.add(removedDomain)
                        } catch let restoreError {
                            Self.logger.error(
                                "Failed to restore domain \(removedDomain.identifier.rawValue, privacy: .public) after its refresh could not re-add it: \(restoreError.localizedDescription, privacy: .private)"
                            )
                        }
                    }
                    if isExtensionNotEnabledError(error) {
                        throw MountError.extensionNotEnabled
                    }
                    throw error
                }
            } else {
                throw error
            }
        }

        do {
            try persistBootstrapConfig(for: config)
        } catch {
            let persistError = error
            do {
                if let existingDomain {
                    // Put the registration back as it was. `add` above already updated the
                    // domain — its display name, and on macOS 15 its `userInfo` — while the
                    // snapshot beside it is still the previous config, and that pairing is
                    // what the extension bootstraps from before macOS 15.
                    try await NSFileProviderManager.add(existingDomain)
                } else {
                    try await NSFileProviderManager.remove(domain)
                }
            } catch {
                let rollbackError = error
                Self.logger.error(
                    "persistBootstrapConfig(for:) failed for domain \(domain.identifier.rawValue, privacy: .public): \(persistError.localizedDescription, privacy: .private); restoring the previous registration also failed: \(rollbackError.localizedDescription, privacy: .private)"
                )
                throw MountError.mountFailed(
                    "persistBootstrapConfig(for:) failed for \(domain.identifier.rawValue): \(persistError.localizedDescription); restoring the previous registration failed: \(rollbackError.localizedDescription)"
                )
            }
            throw persistError
        }
    }

    public func unregister(config: ConnectionConfig) async throws {
        // Removing the domain invalidates the CloudStorage path the link operations
        // resolve, so it takes the same lock they do rather than landing in the middle of
        // one and leaving a link for a domain that no longer exists.
        try await withMountOperationLock(for: config) {
            try await performUnregister(config: config)
        }
    }

    private func performUnregister(config: ConnectionConfig) async throws {
        // Domain first, bookkeeping second. Removing the bootstrap config ahead of the
        // domain leaves a still-registered domain with nothing to bootstrap from: before
        // macOS 15 there is no `domain.userInfo`, and `reloadConnectionsFromStorage`
        // reaches here *after* the connection is gone from `SharedStorage`, so the file
        // this deletes is the last source there is. A failure at this step therefore has
        // to leave everything intact and simply be retried.
        if let removeRegisteredDomainOverride {
            try await removeRegisteredDomainOverride(config)
        } else if let domain = try await findDomain(for: config) {
            try await NSFileProviderManager.remove(domain)
        }

        do {
            try removeBootstrapConfigStep(for: config)
        } catch {
            // Best effort, because the domain is already gone: reporting a failure here
            // would have the caller keep a connection that no longer has one. What is left
            // behind is a bootstrap file for a domain that does not exist, which nothing
            // reads — but it is not swallowed silently either.
            // The message can carry the container path the config was written to, so it
            // stays private — the domain identifier is enough to act on.
            Self.logger.warning(
                "Removed domain \(config.domainIdentifier, privacy: .public) but failed to remove its bootstrap config: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    /// Every operation that looks a domain up and then writes its bootstrap snapshot takes
    /// the same section as `ensureRegistered`.
    ///
    /// The lookup suspends, and the snapshot is what the extension bootstraps from before
    /// macOS 15: a pass holding an older config could resume after a save had registered the
    /// newer one and write its own config over that snapshot, leaving the domain serving an
    /// endpoint neither the row nor storage shows.
    public func reconnect(config: ConnectionConfig) async throws {
        try await withMountOperationLock(for: config) {
            let domain = try await self.domainOrThrow(for: config)
            try self.persistBootstrapConfig(for: config)
            guard let manager = NSFileProviderManager(for: domain) else {
                throw MountError.managerNotFound(config.domainIdentifier)
            }
            try await manager.reconnect()
        }
    }

    public func disconnect(config: ConnectionConfig) async throws {
        try await withMountOperationLock(for: config) {
            let domain = try await self.domainOrThrow(for: config)
            try self.persistBootstrapConfig(for: config)
            guard let manager = NSFileProviderManager(for: domain) else {
                throw MountError.managerNotFound(config.domainIdentifier)
            }
            try await manager.disconnect(
                reason: "Disconnected from MFuse",
                options: []
            )
        }
    }

    public func domainStates() async throws -> [RegisteredDomainState] {
        let domains = try await NSFileProviderManager.domains()
        return domains.map {
            RegisteredDomainState(
                identifier: $0.identifier.rawValue,
                isDisconnected: $0.isDisconnected
            )
        }
    }

    public func signalEnumerator(for config: ConnectionConfig) async throws {
        try await withMountOperationLock(for: config) {
            guard let domain = try await self.refreshExistingDomain(for: config) else {
                throw MountError.domainNotFound(config.domainIdentifier)
            }
            try self.persistBootstrapConfig(for: config)
            guard let manager = NSFileProviderManager(for: domain) else {
                throw MountError.managerNotFound(config.domainIdentifier)
            }
            try await manager.signalEnumerator(for: .workingSet)
        }
    }

    public func mountURL(for config: ConnectionConfig) async throws -> URL? {
        try await resolveMountURL(for: config)
    }

    @discardableResult
    public func createSymlink(for config: ConnectionConfig) async throws -> URL? {
        // Resolving the destination and writing the link are one operation: a rename moves
        // the domain's CloudStorage path, so a pass that resolved the old one must not
        // resume after a later pass wrote the new one and put its stale destination back.
        // `ensureRegistered` — where a rename happens — takes the same lock.
        try await withMountOperationLock(for: config) {
            try await performCreateSymlink(for: config)
        }
    }

    private func performCreateSymlink(for config: ConnectionConfig) async throws -> URL? {
        let fileManager = FileManager.default
        let baseDir = symlinkBaseURL

        let symlinkURL = Self.symlinkURL(for: config, baseDir: baseDir)
        let parentDirectoryURL = symlinkURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDirectoryURL, withIntermediateDirectories: true)
        try cleanupLegacyShortcutIfNeeded(for: config)

        guard let mountURL = try await resolveMountURL(for: config) else { return nil }

        try removeManagedSymlinkIfNeeded(at: symlinkURL, expectedDestinationURL: mountURL)
        // Link-aware, because `fileExists` resolves the link: a dangling one — a user's
        // own, with a managed-looking name, pointing at something that is gone — reads as
        // absent, and the creation below then fails with EEXIST instead of leaving the
        // path alone and warning, which is what the ownership test above decided.
        guard try itemType(at: symlinkURL) == nil else {
            Self.logger.warning(
                "Skipping symlink creation because target path is occupied by a non-managed item: \(symlinkURL.path, privacy: .public)"
            )
            return nil
        }

        do {
            try fileManager.createSymbolicLink(
                atPath: symlinkURL.path,
                withDestinationPath: mountURL.path
            )
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            try fileManager.createDirectory(at: parentDirectoryURL, withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(
                atPath: symlinkURL.path,
                withDestinationPath: mountURL.path
            )
        }
        return symlinkURL
    }

    public func removeSymlink(for config: ConnectionConfig) async throws {
        // Same section as `createSymlink`: both resolve the destination and then act on
        // the link, and interleaving them lets one undo what the other just did.
        try await withMountOperationLock(for: config) {
            try await performRemoveSymlink(for: config)
        }
    }

    private func performRemoveSymlink(for config: ConnectionConfig) async throws {
        // A failed lookup must not abort the cleanup. The states that need it most — a
        // provider failure mid-teardown, a domain damaged behind the app's back — are
        // exactly the ones where the URL cannot be resolved, and giving up there leaves a
        // link pointing into CloudStorage forever. Without a destination to match,
        // removal falls back to the filename plus ownership test below.
        let expectedDestinationURL: URL?
        do {
            expectedDestinationURL = try await resolveMountURL(for: config)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Domain and error identity are enough to diagnose this; the provider's
            // message can carry paths and response detail, so it stays private.
            let nsError = error as NSError
            Self.logger.warning(
                "Removing the convenience symlink for \(config.domainIdentifier, privacy: .public) without a resolved mount URL: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            expectedDestinationURL = nil
        }
        let symlinkURL = Self.symlinkURL(for: config, baseDir: symlinkBaseURL)
        try removeManagedSymlinkIfNeeded(at: symlinkURL, expectedDestinationURL: expectedDestinationURL)
        try cleanupLegacyShortcutIfNeeded(for: config)
    }

    /// Sanitize a connection name for use as a filesystem directory name.
    public static func sanitizeName(_ name: String) -> String {
        var result = String()
        result.reserveCapacity(name.count)

        for character in name {
            switch character {
            case "/", ":", "\0":
                result.append("-")
            default:
                result.append(character)
            }
        }

        // Collapse multiple dashes and trim
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return result.isEmpty ? "unnamed" : result
    }

    public static func symlinkFilename(for config: ConnectionConfig) -> String {
        let sanitizedName = sanitizeName(config.name)
        return "\(sanitizedName)-\(config.id.uuidString)"
    }

    public static func symlinkURL(for config: ConnectionConfig, baseDir: URL) -> URL {
        baseDir.appendingPathComponent(symlinkFilename(for: config))
    }

    public static func symlinkDisplayPath(for config: ConnectionConfig, baseDir: URL) -> String {
        symlinkURL(for: config, baseDir: baseDir).path
    }

    static func legacySymlinkBaseURL(
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupConstants.groupIdentifier
        )
    ) -> URL? {
        guard let containerURL else {
            return nil
        }

        return containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MFuse", isDirectory: true)
            .appendingPathComponent("Shortcuts", isDirectory: true)
    }

    public static func shouldRemoveManagedSymlink(at url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeSymbolicLink,
              matchesManagedSymlinkFilename(url.lastPathComponent),
              let destinationPath = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return false
        }

        let resolvedDestinationURL = URL(
            fileURLWithPath: destinationPath,
            relativeTo: url.deletingLastPathComponent()
        ).standardizedFileURL

        return isManagedMountDestination(resolvedDestinationURL)
    }

    public static func matchesManagedSymlinkFilename(_ name: String) -> Bool {
        let uuidLength = 36
        guard name.count > uuidLength else {
            return false
        }

        let uuidStartIndex = name.index(name.endIndex, offsetBy: -uuidLength)
        guard uuidStartIndex > name.startIndex else {
            return false
        }

        let separatorIndex = name.index(before: uuidStartIndex)
        guard name[separatorIndex] == "-" else {
            return false
        }

        let prefix = name[..<separatorIndex]
        let suffix = name[uuidStartIndex...]
        return !prefix.isEmpty && UUID(uuidString: String(suffix)) != nil
    }

    public static func isManagedMountDestination(_ url: URL) -> Bool {
        let cloudStorageRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("CloudStorage", isDirectory: true)
            .standardizedFileURL

        let destinationPath = url.path
        let rootPath = cloudStorageRoot.path
        return destinationPath == rootPath || destinationPath.hasPrefix(rootPath + "/")
    }

    func itemType(at url: URL) throws -> FileAttributeType? {
        let path = url.path
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path)
                || (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil else {
            return nil
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: path)
            return attributes[.type] as? FileAttributeType
        } catch let error as NSError
            where (error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError)
                || (error.domain == NSPOSIXErrorDomain && error.code == ENOENT) {
            return nil
        }
    }

    private func removeManagedSymlinkIfNeeded(at symlinkURL: URL, expectedDestinationURL: URL?) throws {
        let fm = FileManager.default
        guard let itemType = try itemType(at: symlinkURL) else {
            return
        }
        guard itemType == .typeSymbolicLink else {
            return
        }

        if let expectedDestinationURL {
            guard Self.matchesManagedSymlinkFilename(symlinkURL.lastPathComponent) else {
                return
            }

            if let destinationPath = try? fm.destinationOfSymbolicLink(atPath: symlinkURL.path) {
                let resolvedDestinationURL = URL(
                    fileURLWithPath: destinationPath,
                    relativeTo: symlinkURL.deletingLastPathComponent()
                ).standardizedFileURL
                if resolvedDestinationURL == expectedDestinationURL.standardizedFileURL {
                    try fm.removeItem(at: symlinkURL)
                    return
                }
            }

            // Replace a stale link of ours so the config points at the current mount, but
            // apply the same ownership test as the branch below: a link with a matching
            // name that resolves outside CloudStorage was put there by the user, and
            // reveal now runs this on every click. createSymlink leaves the path alone and
            // warns instead.
            guard Self.shouldRemoveManagedSymlink(at: symlinkURL, fileManager: fm) else {
                return
            }
            try fm.removeItem(at: symlinkURL)
            return
        }

        guard Self.shouldRemoveManagedSymlink(at: symlinkURL, fileManager: fm) else {
            return
        }

        try fm.removeItem(at: symlinkURL)
    }

    private func cleanupLegacyShortcutIfNeeded(for config: ConnectionConfig) throws {
        guard let legacyBaseURL = Self.legacySymlinkBaseURL(),
              legacyBaseURL.standardizedFileURL != symlinkBaseURL.standardizedFileURL else {
            return
        }

        let legacyShortcutURL = Self.symlinkURL(for: config, baseDir: legacyBaseURL)
        let fm = FileManager.default

        if Self.shouldRemoveManagedSymlink(at: legacyShortcutURL, fileManager: fm) {
            try? fm.removeItem(at: legacyShortcutURL)
            return
        }

        guard let itemType = try itemType(at: legacyShortcutURL),
              itemType == .typeDirectory,
              Self.matchesManagedSymlinkFilename(legacyShortcutURL.lastPathComponent),
              let contents = try? fm.contentsOfDirectory(atPath: legacyShortcutURL.path),
              contents.isEmpty else {
            return
        }

        try? fm.removeItem(at: legacyShortcutURL)
    }

    private func findDomain(for config: ConnectionConfig) async throws -> NSFileProviderDomain? {
        let domainID = NSFileProviderDomainIdentifier(rawValue: config.domainIdentifier)
        let domains = try await NSFileProviderManager.domains()
        return domains.first(where: { $0.identifier == domainID })
    }

    private func isExtensionNotEnabledError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSFileProviderErrorDomain,
           nsError.code == NSFileProviderError.Code.providerNotFound.rawValue {
            return true
        }
        return MountError.matchesExtensionNotEnabledMessage(nsError.localizedDescription)
    }

    private func shouldRetryMountAfterDomainRefresh(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteFileExistsError
    }

    private func makeDomain(for config: ConnectionConfig) throws -> NSFileProviderDomain {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: config.domainIdentifier),
            displayName: config.name
        )
        if #available(macOS 15.0, *) {
            domain.userInfo = try FileProviderDomainStateStore.bootstrapUserInfo(for: config)
        }
        return domain
    }

    private func refreshExistingDomain(for config: ConnectionConfig) async throws -> NSFileProviderDomain? {
        try await findDomain(for: config)
    }

    /// Test seam: how many operations are queued behind the one currently holding this
    /// connection, so a test can see that serialization is what is being exercised.
    func queuedOperationCount(for config: ConnectionConfig) async -> Int {
        await operationCoordinator.waitingCount(for: config.domainIdentifier)
    }

    /// Hold this connection's operation lock for the duration of `work`.
    ///
    /// Released on every path, including a thrown error, so one failed operation cannot
    /// strand the connection's later ones.
    private func withMountOperationLock<T>(
        for config: ConnectionConfig,
        _ work: () async throws -> T
    ) async throws -> T {
        let key = config.domainIdentifier
        try await operationCoordinator.acquire(key)
        do {
            let result = try await work()
            await operationCoordinator.release(key)
            return result
        } catch {
            await operationCoordinator.release(key)
            throw error
        }
    }

    private func resolveMountURL(for config: ConnectionConfig) async throws -> URL? {
        if let resolveMountURLOverride {
            return try await resolveMountURLOverride(config)
        }
        guard let domain = try await refreshExistingDomain(for: config) else { return nil }
        guard let manager = NSFileProviderManager(for: domain) else {
            throw MountError.managerNotFound(config.domainIdentifier)
        }
        return try await manager.getUserVisibleURL(for: .rootContainer)
    }

    private func domainOrThrow(for config: ConnectionConfig) async throws -> NSFileProviderDomain {
        guard let domain = try await findDomain(for: config) else {
            throw MountError.domainNotFound(config.domainIdentifier)
        }
        return domain
    }

    private func refreshDomain(for config: ConnectionConfig) async throws -> NSFileProviderDomain {
        try await domainOrThrow(for: config)
    }

    private func resolveDomain(for config: ConnectionConfig) async throws -> NSFileProviderDomain {
        try await domainOrThrow(for: config)
    }

    private func persistBootstrapConfig(for config: ConnectionConfig) throws {
        try FileProviderDomainStateStore.saveBootstrapConfig(config)
    }

    private func removeBootstrapConfig(for config: ConnectionConfig) throws {
        try FileProviderDomainStateStore.removeBootstrapConfig(for: config.domainIdentifier)
    }

    private func removeBootstrapConfigStep(for config: ConnectionConfig) throws {
        if let removeBootstrapConfigOverride {
            try removeBootstrapConfigOverride(config)
            return
        }
        try removeBootstrapConfig(for: config)
    }
}
