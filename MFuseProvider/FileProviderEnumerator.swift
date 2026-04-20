import FileProvider
import MFuseCore
import os.log

/// Enumerates items in a remote directory for the File Provider framework.
public final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {

    private static let enumerationTimeoutSeconds = 15.0
    private let containerID: NSFileProviderItemIdentifier
    private let domainIdentifier: String
    private let contextProvider: @Sendable () async throws -> FileProviderRuntimeContext
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
        contextProvider: @escaping @Sendable () async throws -> FileProviderRuntimeContext,
        errorMapper: @escaping @Sendable (Error) -> NSError
    ) {
        self.containerID = containerID
        self.domainIdentifier = domainIdentifier
        self.contextProvider = contextProvider
        self.errorMapper = errorMapper
        super.init()
    }

    private static let pageSize = 100

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
        // We emit a single logical enumeration in chunked batches to reduce memory use,
        // but we do not support follow-up page tokens. Callers should start with one of
        // the File Provider initial page constants; any other page is treated as exhausted.
        if page != .initialPageSortedByDate && page != .initialPageSortedByName {
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
            guard let self else { return }
            defer { self.clearItemEnumerationTask(id: taskID) }
            do {
                logger.info(
                    "Starting enumerateItems for domain \(self.domainIdentifier, privacy: .public) at \(path.absoluteString, privacy: .public)"
                )
                let context = try await contextProvider()

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
                await context.cache.putAll(items: remoteItems, parent: path)

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
                observer.finishEnumerating(upTo: nil)
            } catch {
                guard !Task.isCancelled, self.isCurrentItemEnumerationTask(id: taskID) else { return }
                logger.error(
                    "enumerateItems failed for domain \(self.domainIdentifier, privacy: .public) at \(path.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)"
                )
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
            guard let self else { return }
            defer { self.clearChangesEnumerationTask(id: taskID) }
            do {
                logger.info(
                    "Starting enumerateChanges for domain \(self.domainIdentifier, privacy: .public) at \(path.absoluteString, privacy: .public)"
                )
                let context = try await contextProvider()
                let remoteItems = try await withOperationTimeout(
                    seconds: Self.enumerationTimeoutSeconds,
                    operation: "enumerating changes for \(path.absoluteString) in domain \(self.domainIdentifier)"
                ) {
                    try await context.fileSystem.enumerate(at: path)
                }
                let cachedItems = await context.cache.children(of: path) ?? []
                logger.info(
                    "Fetched enumerateChanges for domain \(self.domainIdentifier, privacy: .public) at \(path.absoluteString, privacy: .public) count=\(remoteItems.count)"
                )
                let remotePaths = Set(remoteItems.map(\.path.absoluteString))
                let deletedIdentifiers = cachedItems
                    .filter { !remotePaths.contains($0.path.absoluteString) }
                    .map { NSFileProviderItemIdentifier($0.path.absoluteString) }
                if !deletedIdentifiers.isEmpty {
                    guard !Task.isCancelled, self.isCurrentChangesEnumerationTask(id: taskID) else { return }
                    observer.didDeleteItems(withIdentifiers: deletedIdentifiers)
                }

                await context.cache.putAll(items: remoteItems, parent: path)
                let newAnchor = try await context.anchorStore.incrementAnchor(for: domainIdentifier)

                let items = remoteItems.map { item in
                    FileProviderItem(
                        remoteItem: item,
                        parentID: self.containerID
                    ) as NSFileProviderItem
                }
                guard !Task.isCancelled, self.isCurrentChangesEnumerationTask(id: taskID) else { return }
                observer.didUpdate(items)

                let anchorData = withUnsafeBytes(of: newAnchor) { Data($0) }
                guard !Task.isCancelled, self.isCurrentChangesEnumerationTask(id: taskID) else { return }
                observer.finishEnumeratingChanges(
                    upTo: NSFileProviderSyncAnchor(anchorData),
                    moreComing: false
                )
            } catch {
                guard !Task.isCancelled, self.isCurrentChangesEnumerationTask(id: taskID) else { return }
                logger.error(
                    "enumerateChanges failed for domain \(self.domainIdentifier, privacy: .public) at \(path.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                observer.finishEnumeratingWithError(errorMapper(error))
            }
        }
        replaceChangesEnumerationTask(task, id: taskID)
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task {
            do {
                let context = try await contextProvider()
                let anchor = await context.anchorStore.currentAnchor(for: domainIdentifier)
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
