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
        // No ongoing work to cancel
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

        Task {
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
                        observer.didEnumerate(batch)
                    }
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
                    observer.didEnumerate(batch)
                }
                observer.finishEnumerating(upTo: nil)
            } catch {
                logger.error(
                    "enumerateItems failed for domain \(self.domainIdentifier, privacy: .public) at \(path.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                observer.finishEnumeratingWithError(errorMapper(error))
            }
        }
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

        Task {
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
                logger.info(
                    "Fetched enumerateChanges for domain \(self.domainIdentifier, privacy: .public) at \(path.absoluteString, privacy: .public) count=\(remoteItems.count)"
                )
                await context.cache.putAll(items: remoteItems, parent: path)
                let newAnchor = try await context.anchorStore.incrementAnchor(for: domainIdentifier)

                let items = remoteItems.map { item in
                    FileProviderItem(
                        remoteItem: item,
                        parentID: self.containerID
                    ) as NSFileProviderItem
                }
                observer.didUpdate(items)

                let anchorData = withUnsafeBytes(of: newAnchor) { Data($0) }
                observer.finishEnumeratingChanges(
                    upTo: NSFileProviderSyncAnchor(anchorData),
                    moreComing: false
                )
            } catch {
                logger.error(
                    "enumerateChanges failed for domain \(self.domainIdentifier, privacy: .public) at \(path.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                observer.finishEnumeratingWithError(errorMapper(error))
            }
        }
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

// MARK: - Array batching

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
