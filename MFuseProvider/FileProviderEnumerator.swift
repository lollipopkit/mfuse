import FileProvider
import MFuseCore
import os.log

/// Enumerates items in a remote directory for the File Provider framework.
public final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {

    private static let enumerationTimeoutSeconds = 15.0
    private let containerID: NSFileProviderItemIdentifier
    private let domainIdentifier: String
    /// Hands out the runtime context as a lease, so an enumeration in progress is counted:
    /// extension teardown waits for the leases it has given out before it closes the
    /// connection, the caches and the anchor store this enumeration reads and writes.
    private let contextProvider: @Sendable () async throws -> FileProviderRuntimeContextLease
    private let errorMapper: @Sendable (Error) -> NSError
    private let logger = Logger(subsystem: "com.lollipopkit.mfuse.provider", category: "Enumerator")
    private let taskLock = NSLock()
    private var itemEnumerationTask: Task<Void, Never>?
    private var itemEnumerationTaskID: UUID?
    private var changesEnumerationTask: Task<Void, Never>?
    private var changesEnumerationTaskID: UUID?

    init(
        containerID: NSFileProviderItemIdentifier,
        domainIdentifier: String,
        contextProvider: @escaping @Sendable () async throws -> FileProviderRuntimeContextLease,
        errorMapper: @escaping @Sendable (Error) -> NSError
    ) {
        self.containerID = containerID
        self.domainIdentifier = domainIdentifier
        self.contextProvider = contextProvider
        self.errorMapper = errorMapper
        super.init()
    }

    private static let pageSize = 100

    /// The anchor is this container's, not the whole domain's.
    ///
    /// One anchor per domain was advanced by whichever container enumerated changes first,
    /// while the baseline it snapshotted was only that container's. Every other container
    /// then arrived holding the anchor it had been given, found it no longer current, and
    /// was rejected as expired — a full re-enumeration for a directory nothing had changed.
    /// A container's anchor now moves only when that container's own changes are reported.
    private var anchorKey: String {
        "\(domainIdentifier)|\(containerID.rawValue)"
    }

    public func invalidate() {
        let itemTask: Task<Void, Never>?
        let changesTask: Task<Void, Never>?

        taskLock.lock()
        itemTask = itemEnumerationTask
        itemEnumerationTask = nil
        itemEnumerationTaskID = nil
        changesTask = changesEnumerationTask
        changesEnumerationTask = nil
        changesEnumerationTaskID = nil
        taskLock.unlock()

        itemTask?.cancel()
        changesTask?.cancel()
    }

    // MARK: - Full Enumeration

    public func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        let pageData = page.rawValue
        let initialPageSortedByDate = NSFileProviderPage.initialPageSortedByDate as Data
        let initialPageSortedByName = NSFileProviderPage.initialPageSortedByName as Data
        // We emit a single logical enumeration in chunked batches to reduce memory use,
        // but we do not support follow-up page tokens. Callers should start with one of
        // the File Provider initial page constants; any other page is treated as exhausted.
        if pageData != initialPageSortedByDate && pageData != initialPageSortedByName {
            observer.finishEnumerating(upTo: nil)
            return
        }

        if containerID == .workingSet || containerID == .trashContainer {
            observer.finishEnumerating(upTo: nil)
            return
        }

        let path = containerID.remotePath

        let taskID = UUID()
        let task = Task { [weak self] in
            var didFinish = false
            defer {
                // Only the pass that still owns this request answers it. A cancelled pass
                // resuming after its replacement had taken over used to complete the
                // observer with a cancellation for an enumeration the replacement was still
                // running, racing its results with an error for a request it did not own.
                let isCurrent = self?.isCurrentItemEnumerationTask(id: taskID) ?? false
                if let self {
                    self.clearItemEnumerationTask(id: taskID)
                }
                if !didFinish, isCurrent {
                    observer.finishEnumeratingWithError(Self.cancellationError())
                }
            }
            guard let self else { return }
            do {
                logger.info(
                    "Starting enumerateItems for domain \(self.domainIdentifier, privacy: .public) at \(path.absoluteString, privacy: .public)"
                )
                let lease = try await contextProvider()
                defer { lease.finish() }
                let context = lease.context

                // Check cache first
                if let cached = await context.cache.children(of: path) {
                    logger.info(
                        "Serving cached enumerateItems for domain \(self.domainIdentifier, privacy: .public) at \(path.absoluteString, privacy: .public) count=\(cached.count)"
                    )
                    let items = cached.map { item in
                        FileProviderItem(
                            remoteItem: item,
                            parentID: self.containerID
                        ) as NSFileProviderItem
                    }
                    // Paginate to avoid memory spikes
                    for batch in items.chunked(into: Self.pageSize) {
                        guard !Task.isCancelled, self.isCurrentItemEnumerationTask(id: taskID) else { return }
                        observer.didEnumerate(batch)
                    }
                    guard !Task.isCancelled, self.isCurrentItemEnumerationTask(id: taskID) else { return }
                    didFinish = true
                    observer.finishEnumerating(upTo: nil)
                    return
                }

                // Fetch from remote
                let remoteItems = try await withOperationTimeout(
                    seconds: Self.enumerationTimeoutSeconds,
                    operation: "enumerating \(path.absoluteString) for domain \(self.domainIdentifier)"
                ) {
                    try await context.fileSystem.enumerate(at: path)
                }
                logger.info(
                    "Fetched enumerateItems for domain \(self.domainIdentifier, privacy: .public) at \(path.absoluteString, privacy: .public) count=\(remoteItems.count)"
                )
                // `putAll` replaces the directory's cached children, so a pass that has been
                // replaced must not write its own: the list it fetched is older than
                // whatever replaced it, and the next enumeration would serve items that had
                // already been deleted or moved.
                guard !Task.isCancelled, self.isCurrentItemEnumerationTask(id: taskID) else { return }
                try await context.cache.putAll(items: remoteItems, parent: path)

                let items = remoteItems.map { item in
                    FileProviderItem(
                        remoteItem: item,
                        parentID: self.containerID
                    ) as NSFileProviderItem
                }
                for batch in items.chunked(into: Self.pageSize) {
                    guard !Task.isCancelled, self.isCurrentItemEnumerationTask(id: taskID) else { return }
                    observer.didEnumerate(batch)
                }
                guard !Task.isCancelled, self.isCurrentItemEnumerationTask(id: taskID) else { return }
                didFinish = true
                observer.finishEnumerating(upTo: nil)
            } catch {
                guard !Task.isCancelled, self.isCurrentItemEnumerationTask(id: taskID) else { return }
                logger.error(
                    "enumerateItems failed for domain \(self.domainIdentifier, privacy: .public) at \(path.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                didFinish = true
                observer.finishEnumeratingWithError(errorMapper(error))
            }
        }
        replaceItemEnumerationTask(task, id: taskID)
    }

    // MARK: - Change Enumeration

    public func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        if containerID == .workingSet || containerID == .trashContainer {
            observer.finishEnumeratingChanges(
                upTo: anchor,
                moreComing: false
            )
            return
        }

        let path = containerID.remotePath

        let taskID = UUID()
        let task = Task { [weak self] in
            var didFinish = false
            defer {
                // Owned the same way the full enumeration owns its completion: a pass that
                // has been replaced answers for nothing.
                let isCurrent = self?.isCurrentChangesEnumerationTask(id: taskID) ?? false
                if let self {
                    self.clearChangesEnumerationTask(id: taskID)
                }
                if !didFinish, isCurrent {
                    observer.finishEnumeratingWithError(Self.cancellationError())
                }
            }
            guard let self else { return }
            do {
                logger.info(
                    "Starting enumerateChanges for domain \(self.domainIdentifier, privacy: .public) at \(path.absoluteString, privacy: .public)"
                )
                let lease = try await contextProvider()
                defer { lease.finish() }
                let context = lease.context
                let requestedAnchor = try Self.decodeSyncAnchor(anchor)
                let currentAnchor = await context.anchorStore.currentAnchor(for: anchorKey)

                guard requestedAnchor == currentAnchor else {
                    logger.error(
                        "Rejecting enumerateChanges for domain \(self.domainIdentifier, privacy: .public) at \(path.absoluteString, privacy: .public): requested anchor \(requestedAnchor) does not match current anchor \(currentAnchor)"
                    )
                    throw Self.syncAnchorExpiredError()
                }

                let cachedItems: [RemoteItem]
                if let snapshot = await context.cache.children(of: path) {
                    cachedItems = snapshot
                } else if currentAnchor == 0 {
                    cachedItems = []
                } else {
                    logger.error(
                        "Rejecting enumerateChanges for domain \(self.domainIdentifier, privacy: .public) at \(path.absoluteString, privacy: .public): cached baseline missing for anchor \(currentAnchor)"
                    )
                    throw Self.syncAnchorExpiredError()
                }

                let remoteItems = try await withOperationTimeout(
                    seconds: Self.enumerationTimeoutSeconds,
                    operation: "enumerating changes for \(path.absoluteString) in domain \(self.domainIdentifier)"
                ) {
                    try await context.fileSystem.enumerate(at: path)
                }
                logger.info(
                    "Fetched enumerateChanges for domain \(self.domainIdentifier, privacy: .public) at \(path.absoluteString, privacy: .public) count=\(remoteItems.count)"
                )
                let changeSet = Self.computeChangeSet(
                    cachedItems: cachedItems,
                    remoteItems: remoteItems
                )

                if !changeSet.deletedIdentifiers.isEmpty {
                    guard !Task.isCancelled, self.isCurrentChangesEnumerationTask(id: taskID) else { return }
                    observer.didDeleteItems(withIdentifiers: changeSet.deletedIdentifiers)
                }

                // Checked before the shared state is written, not only before the observer is
                // told. A replaced or cancelled pass that wrote here anyway replaced this
                // directory's baseline and moved its anchor for a result nobody was ever
                // given: the pass that took over then compared against a snapshot that was
                // never reported and called the difference "no changes".
                guard !Task.isCancelled, self.isCurrentChangesEnumerationTask(id: taskID) else { return }
                let shouldAdvanceAnchor = currentAnchor == 0 || changeSet.hasChanges
                try await context.cache.putAll(items: remoteItems, parent: path)

                let resultingAnchor: UInt64
                if shouldAdvanceAnchor {
                    resultingAnchor = try await context.anchorStore.incrementAnchor(for: anchorKey)
                } else {
                    resultingAnchor = currentAnchor
                }

                if !changeSet.updatedItems.isEmpty {
                    let items = changeSet.updatedItems.map { item in
                        FileProviderItem(
                            remoteItem: item,
                            parentID: self.containerID
                        ) as NSFileProviderItem
                    }
                    for batch in items.chunked(into: Self.pageSize) {
                        guard !Task.isCancelled, self.isCurrentChangesEnumerationTask(id: taskID) else { return }
                        observer.didUpdate(batch)
                    }
                }

                let anchorData = Self.encodeSyncAnchor(resultingAnchor)
                if !changeSet.deletedIdentifiers.isEmpty {
                    logger.debug(
                        "enumerateChanges reported deletes for domain \(self.domainIdentifier, privacy: .public) at \(path.absoluteString, privacy: .public): \(changeSet.deletedIdentifiers.count)"
                    )
                }
                guard !Task.isCancelled, self.isCurrentChangesEnumerationTask(id: taskID) else { return }
                didFinish = true
                observer.finishEnumeratingChanges(
                    upTo: NSFileProviderSyncAnchor(anchorData),
                    moreComing: false
                )
            } catch {
                guard !Task.isCancelled, self.isCurrentChangesEnumerationTask(id: taskID) else { return }
                logger.error(
                    "enumerateChanges failed for domain \(self.domainIdentifier, privacy: .public) at \(path.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                didFinish = true
                observer.finishEnumeratingWithError(errorMapper(error))
            }
        }
        replaceChangesEnumerationTask(task, id: taskID)
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task {
            do {
                let lease = try await contextProvider()
                defer { lease.finish() }
                let anchor = await lease.context.anchorStore.currentAnchor(for: anchorKey)
                guard anchor != 0 else {
                    completionHandler(nil)
                    return
                }

                let anchorData = withUnsafeBytes(of: anchor) { Data($0) }
                completionHandler(NSFileProviderSyncAnchor(anchorData))
            } catch {
                completionHandler(nil)
            }
        }
    }
}

private extension FileProviderEnumerator {
    struct ChangeSet {
        let updatedItems: [RemoteItem]
        let deletedIdentifiers: [NSFileProviderItemIdentifier]

        var hasChanges: Bool {
            !updatedItems.isEmpty || !deletedIdentifiers.isEmpty
        }
    }

    static func cancellationError() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
    }

    static func syncAnchorExpiredError() -> NSError {
        NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.syncAnchorExpired.rawValue)
    }

    static func decodeSyncAnchor(_ anchor: NSFileProviderSyncAnchor) throws -> UInt64 {
        let rawValue = anchor.rawValue
        guard !rawValue.isEmpty else { return 0 }
        guard rawValue.count == MemoryLayout<UInt64>.size else {
            throw syncAnchorExpiredError()
        }

        var decodedAnchor: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &decodedAnchor) { rawBuffer in
            rawValue.copyBytes(to: rawBuffer)
        }
        return decodedAnchor
    }

    static func encodeSyncAnchor(_ anchor: UInt64) -> Data {
        withUnsafeBytes(of: anchor) { Data($0) }
    }

    static func computeChangeSet(cachedItems: [RemoteItem], remoteItems: [RemoteItem]) -> ChangeSet {
        let cachedByPath = Dictionary(uniqueKeysWithValues: cachedItems.map { ($0.path.absoluteString, $0) })
        let remoteByPath = Dictionary(uniqueKeysWithValues: remoteItems.map { ($0.path.absoluteString, $0) })

        let updatedItems = remoteItems.filter { remoteItem in
            guard let cachedItem = cachedByPath[remoteItem.path.absoluteString] else {
                return true
            }
            return !hasSameSnapshot(cachedItem, remoteItem)
        }

        let deletedIdentifiers = cachedItems.compactMap { cachedItem -> NSFileProviderItemIdentifier? in
            guard remoteByPath[cachedItem.path.absoluteString] == nil else {
                return nil
            }
            return NSFileProviderItemIdentifier(cachedItem.path.absoluteString)
        }

        return ChangeSet(updatedItems: updatedItems, deletedIdentifiers: deletedIdentifiers)
    }

    static func hasSameSnapshot(_ lhs: RemoteItem, _ rhs: RemoteItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.path == rhs.path &&
        lhs.type == rhs.type &&
        lhs.size == rhs.size &&
        lhs.modificationDate == rhs.modificationDate &&
        lhs.creationDate == rhs.creationDate &&
        lhs.permissions == rhs.permissions &&
        lhs.isHidden == rhs.isHidden
    }

    func replaceItemEnumerationTask(_ task: Task<Void, Never>, id: UUID) {
        let previousTask: Task<Void, Never>?
        taskLock.lock()
        previousTask = itemEnumerationTask
        itemEnumerationTask = task
        itemEnumerationTaskID = id
        taskLock.unlock()
        previousTask?.cancel()
    }

    func clearItemEnumerationTask(id: UUID) {
        taskLock.lock()
        if itemEnumerationTaskID == id {
            itemEnumerationTask = nil
            itemEnumerationTaskID = nil
        }
        taskLock.unlock()
    }

    func isCurrentItemEnumerationTask(id: UUID) -> Bool {
        taskLock.lock()
        defer { taskLock.unlock() }
        return itemEnumerationTaskID == id
    }

    func replaceChangesEnumerationTask(_ task: Task<Void, Never>, id: UUID) {
        let previousTask: Task<Void, Never>?
        taskLock.lock()
        previousTask = changesEnumerationTask
        changesEnumerationTask = task
        changesEnumerationTaskID = id
        taskLock.unlock()
        previousTask?.cancel()
    }

    func clearChangesEnumerationTask(id: UUID) {
        taskLock.lock()
        if changesEnumerationTaskID == id {
            changesEnumerationTask = nil
            changesEnumerationTaskID = nil
        }
        taskLock.unlock()
    }

    func isCurrentChangesEnumerationTask(id: UUID) -> Bool {
        taskLock.lock()
        defer { taskLock.unlock() }
        return changesEnumerationTaskID == id
    }
}

// MARK: - Array batching

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
