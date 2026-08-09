import FileProvider
import MFuseCore
import MFuseSFTP
import MFuseS3
import MFuseWebDAV
import MFuseSMB
import MFuseFTP
import MFuseNFS
import MFuseGoogleDrive
import MFuseDropbox
import MFuseOneDrive
import UniformTypeIdentifiers
import os.log

struct FileProviderRuntimeContext: Sendable {
    let config: ConnectionConfig
    let fileSystem: any RemoteFileSystem
    let cache: MetadataCache
    let contentCache: ContentCache
    let anchorStore: SyncAnchorStore
    let stateStore: FileProviderDomainStateStore
}

actor BootstrapTaskStore {
    private var bootstrapTask: Task<FileProviderRuntimeContext, Error>?
    /// Set by `takeForInvalidation()` and never cleared: the extension instance is being
    /// torn down, so a context created after that point is one nothing closes.
    private var isInvalidated = false

    /// Hand the current task to the teardown and refuse to build another.
    ///
    /// Taking the task without closing the door let an operation that arrived while
    /// cleanup was still disconnecting create a second context: the teardown owns only the
    /// task it took, so that one was left connected, with its caches and state store open,
    /// for an instance the system has already given up on.
    func takeForInvalidation() -> Task<FileProviderRuntimeContext, Error>? {
        isInvalidated = true
        let task = bootstrapTask
        bootstrapTask = nil
        return task
    }

    func clear() {
        bootstrapTask = nil
    }

    func clearIfCurrent(_ task: Task<FileProviderRuntimeContext, Error>) {
        guard let bootstrapTask, bootstrapTask == task else { return }
        self.bootstrapTask = nil
    }

    func currentOrCreate(
        _ create: @Sendable () -> Task<FileProviderRuntimeContext, Error>
    ) throws -> Task<FileProviderRuntimeContext, Error> {
        guard !isInvalidated else {
            throw FileProviderExtensionInvalidated()
        }
        if let bootstrapTask {
            return bootstrapTask
        }

        let task = create()
        bootstrapTask = task
        return task
    }
}

/// Counts the operations holding the runtime context, so teardown can wait for them
/// instead of closing what they are using.
///
/// The count is raised *before* the context is asked for and lowered when the operation
/// leaves, whichever way it leaves. Teardown shuts the door first and drains second, so an
/// operation that arrives in between is refused a context rather than missed by the drain.
final class RuntimeContextActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    /// Single-consumer: `invalidate()` is the only waiter, and waits once per instance.
    private var idleWaiter: CheckedContinuation<Void, Never>?
    private var isWaitCancelled = false

    func begin() {
        lock.withLock { activeCount += 1 }
    }

    func end() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            activeCount -= 1
            guard activeCount == 0 else { return nil }
            return takeIdleWaiterLocked()
        }
        waiter?.resume()
    }

    /// Wait until nothing holds the context any more.
    ///
    /// Cancellation resumes the waiter here rather than leaving it to the last operation:
    /// the caller bounds this wait, and a backend that never returns from a cancelled read
    /// would otherwise strand the continuation for the life of the process.
    func waitUntilIdle() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let isIdle: Bool = lock.withLock {
                    guard activeCount > 0, !isWaitCancelled else { return true }
                    idleWaiter = continuation
                    return false
                }
                if isIdle {
                    continuation.resume()
                }
            }
        } onCancel: {
            let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
                isWaitCancelled = true
                return takeIdleWaiterLocked()
            }
            waiter?.resume()
        }
    }

    private func takeIdleWaiterLocked() -> CheckedContinuation<Void, Never>? {
        let waiter = idleWaiter
        idleWaiter = nil
        return waiter
    }
}

/// One operation's hold on the runtime context, counted for the duration of that operation.
///
/// `finish()` is called exactly once, from a `defer` at the point the lease is taken, so the
/// hold ends whether the operation returned, threw or was cancelled.
struct FileProviderRuntimeContextLease: Sendable {
    let context: FileProviderRuntimeContext
    private let activity: RuntimeContextActivity

    init(context: FileProviderRuntimeContext, activity: RuntimeContextActivity) {
        self.context = context
        self.activity = activity
    }

    func finish() {
        activity.end()
    }
}

/// Raised for work that arrives after the extension instance has been invalidated.
struct FileProviderExtensionInvalidated: LocalizedError {
    var errorDescription: String? {
        NSLocalizedString(
            "fileprovider.invalidated",
            tableName: nil,
            bundle: .main,
            value: "This mount was shut down. Try again.",
            comment: ""
        )
    }
}

actor CleanupTaskStore {
    private var cleanupTask: Task<Void, Never>?
    private var cleanupTaskID: UUID?

    /// Keep a reference to this cleanup pass, leaving any pass already running alone.
    ///
    /// Cancelling the previous one made a second `invalidate()` abandon the teardown
    /// altogether: `BootstrapTaskStore.takeForInvalidation()` hands the runtime context to
    /// whichever pass asks first, and the later pass finds nothing to close, so cancelling
    /// the earlier one — parked on a drain, or on a bootstrap that has not unwound — left
    /// the filesystem connected and the caches open with nothing left to answer for them.
    func adopt(_ task: Task<Void, Never>, id: UUID) {
        cleanupTask = task
        cleanupTaskID = id
    }

    func clear(id: UUID) {
        guard cleanupTaskID == id else { return }
        cleanupTask = nil
        cleanupTaskID = nil
    }
}

enum FileProviderOperationTimeout: LocalizedError {
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let operation):
            let template = NSLocalizedString(
                "fileprovider.timeout",
                tableName: nil,
                bundle: .main,
                value: "Timed out while %@",
                comment: ""
            )
            return String(format: template, locale: .current, arguments: [operation])
        }
    }
}

final class FileProviderDomainVersionState: @unchecked Sendable {
    private let lock = NSLock()
    private var currentVersion = NSFileProviderDomainVersion().next()

    func read() -> NSFileProviderDomainVersion {
        lock.lock()
        defer { lock.unlock() }
        return currentVersion
    }

    func advance() {
        lock.lock()
        currentVersion = currentVersion.next()
        lock.unlock()
    }
}

final class SharedCredentialStoreProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var store: SharedCredentialStore

    init(
        syncMode: KeychainItemSyncMode = SharedAppSettings.iCloudSyncEnabled ? .synchronizable : .local
    ) {
        self.store = SharedCredentialStore(syncMode: syncMode)
    }

    func credential(for connectionID: UUID) throws -> Credential? {
        try currentStore().credential(for: connectionID)
    }

    func store(_ credential: Credential, for connectionID: UUID) throws {
        try currentStore().store(credential, for: connectionID)
    }

    /// The store for the sync mode that is configured *now*.
    ///
    /// Read on every access rather than chosen once: turning iCloud sync on or off moves
    /// every credential to the other Keychain sync mode, and the extension is a separate
    /// process the app cannot call into. An instance built before the change would keep
    /// looking in the mode the items have left — reporting an authentication failure for
    /// every domain until the extension happens to be recreated — and would write refreshed
    /// OAuth tokens back there, where nothing reads them.
    private func currentStore() -> SharedCredentialStore {
        let syncMode: KeychainItemSyncMode = SharedAppSettings.iCloudSyncEnabled ? .synchronizable : .local
        return lock.withLock {
            if store.syncMode != syncMode {
                store = SharedCredentialStore(syncMode: syncMode)
            }
            return store
        }
    }
}

/// Resumes its caller once, for whichever of the work, the deadline and the caller's own
/// cancellation gets there first.
private final class OperationTimeoutResumer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pendingResult: Result<T, Error>?
    private var isFinished = false

    /// Installed before anything can race for it, and answered straight away when the
    /// first outcome arrived while the caller was still suspending.
    func install(_ continuation: CheckedContinuation<T, Error>) {
        let readyResult: Result<T, Error>? = lock.withLock {
            guard let pendingResult else {
                self.continuation = continuation
                return nil
            }
            self.pendingResult = nil
            return pendingResult
        }
        if let readyResult {
            continuation.resume(with: readyResult)
        }
    }

    func resume(with result: Result<T, Error>) {
        let continuation: CheckedContinuation<T, Error>? = lock.withLock {
            guard !isFinished else { return nil }
            isFinished = true
            guard let continuation = self.continuation else {
                pendingResult = result
                return nil
            }
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

/// Run `work` under a deadline, and stop waiting for it once that deadline passes.
///
/// Not a task group: a throwing group waits for every child task before its scope ends, so
/// an operation that never observes cancellation held the caller well past the timeout the
/// group had already decided on — `runtimeContext()` sat there indefinitely on a wedged
/// backend, and `invalidate()`, which cancels the bootstrap and awaits it, sat behind it
/// with the filesystem and caches still open. The work is cancelled and then left to
/// unwind on its own; the caller is answered on time.
@Sendable
func withOperationTimeout<T: Sendable>(
    seconds: Double,
    operation: String,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    let resumer = OperationTimeoutResumer<T>()
    let workTask = Task {
        do {
            resumer.resume(with: .success(try await work()))
        } catch {
            resumer.resume(with: .failure(error))
        }
    }
    let timeoutTask = Task {
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } catch {
            // Cancelled because the work already answered.
            return
        }
        workTask.cancel()
        resumer.resume(with: .failure(FileProviderOperationTimeout.timedOut(operation)))
    }
    defer { timeoutTask.cancel() }

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            resumer.install(continuation)
        }
    } onCancel: {
        workTask.cancel()
        timeoutTask.cancel()
        // Answered here rather than left to the work: cancellation is only prompt if it
        // does not wait for an operation that may be ignoring it.
        resumer.resume(with: .failure(CancellationError()))
    }
}

/// The File Provider Replicated Extension — bridges the macOS File Provider framework
/// to the MFuse VFS layer.
public final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderDomainState {

    private static let bootstrapTimeoutSeconds = 15.0
    private static let invalidationDrainTimeoutSeconds = 5.0
    private static let bootstrapTransientRetryCount = 2
    private static let bootstrapTransientRetryDelayNanoseconds: UInt64 = 750_000_000
    private static let contentCacheStoreRetryCount = 2
    private static let streamedReadChunkSize: UInt32 = 1_048_576
    private static let sharedCredentialStoreProvider = SharedCredentialStoreProvider()
    private static let registerBackendsOnce: Void = {
        BackendRegistry.shared.registerAllBuiltIns(
            sftpFactory: { config, credential in
                SFTPFileSystem(config: config, credential: credential)
            },
            s3Factory: { config, credential in
                S3FileSystem(config: config, credential: credential)
            },
            webdavFactory: { config, credential in
                WebDAVFileSystem(config: config, credential: credential)
            },
            smbFactory: { config, credential in
                SMBFileSystem(config: config, credential: credential)
            },
            ftpFactory: { config, credential in
                FTPFileSystem(config: config, credential: credential)
            },
            nfsFactory: { config, credential in
                NFSFileSystem(config: config, credential: credential)
            },
            googleDriveFactory: { config, credential in
                return GoogleDriveFileSystem(
                    config: config,
                    credential: credential
                ) { updatedCredential in
                    try FileProviderExtension.sharedCredentialStoreProvider.store(updatedCredential, for: config.id)
                }
            },
            dropboxFactory: { config, credential in
                DropboxFileSystem(
                    config: config,
                    credential: credential
                ) { updatedCredential in
                    try FileProviderExtension.sharedCredentialStoreProvider.store(updatedCredential, for: config.id)
                }
            },
            oneDriveFactory: { config, credential in
                OneDriveFileSystem(
                    config: config,
                    credential: credential
                ) { updatedCredential in
                    try FileProviderExtension.sharedCredentialStoreProvider.store(updatedCredential, for: config.id)
                }
            }
        )
    }()
    private let domain: NSFileProviderDomain
    private let domainVersionState = FileProviderDomainVersionState()
    private let storage = SharedStorage(createDirectoriesOnInit: false)
    private let logger = Logger(subsystem: "com.lollipopkit.mfuse.provider", category: "Extension")
    private let bootstrapTaskStore = BootstrapTaskStore()
    private let cleanupTaskStore = CleanupTaskStore()
    private let runtimeContextActivity = RuntimeContextActivity()

    public required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        Self.registerBackends()
    }

    public var domainVersion: NSFileProviderDomainVersion {
        domainVersionState.read()
    }

    public var userInfo: [AnyHashable: Any] {
        [:]
    }

    public func invalidate() {
        let cleanupTaskID = UUID()
        let cleanupTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task {
                    await self.cleanupTaskStore.clear(id: cleanupTaskID)
                }
            }

            let bootstrapTask = await self.bootstrapTaskStore.takeForInvalidation()
            bootstrapTask?.cancel()
            guard let bootstrapTask, let context = try? await bootstrapTask.value else { return }

            // Drained after the door is shut, and before anything is closed. An operation
            // that is already running holds the same connection, caches and anchor store
            // this is about to close: closing underneath it dropped the cache invalidation
            // a delete or a move makes on its way out — `close()` leaves every later write
            // a no-op — so the next extension instance opened the same database and served
            // the entry for an item that is no longer there.
            //
            // A drain that runs out of time leaves the context open rather than closing it
            // anyway. The operation still holding it is the one closing would damage, and
            // the instance is being released: what is left open goes with the process,
            // which costs nothing the next instance can observe, while closing under a live
            // operation costs exactly the writes this drain exists to keep.
            guard await self.awaitInFlightOperations() else { return }

            try? await context.fileSystem.disconnect()
            await context.cache.close()
            await context.contentCache.close()
            await context.anchorStore.close()
            context.stateStore.close()
        }

        Task {
            await cleanupTaskStore.adopt(cleanupTask, id: cleanupTaskID)
        }
    }

    // MARK: - NSFileProviderReplicatedExtension: Item Operations

    public func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        Task {
            defer { progress.completedUnitCount = 1 }

            do {
                if identifier == .rootContainer {
                    completionHandler(FileProviderItem.rootItem(name: domain.displayName), nil)
                    return
                }

                if identifier == .workingSet {
                    completionHandler(
                        FileProviderItem.syntheticContainer(
                            identifier: .workingSet,
                            name: "Working Set"
                        ),
                        nil
                    )
                    return
                }

                if identifier == .trashContainer {
                    completionHandler(
                        FileProviderItem.syntheticContainer(
                            identifier: .trashContainer,
                            name: "Trash"
                        ),
                        nil
                    )
                    return
                }

                let lease = try await runtimeContextLease()
                defer { lease.finish() }
                let context = lease.context
                let path = identifier.remotePath
                let remoteItem = try await context.fileSystem.itemInfo(at: path)
                let parentID = parentIdentifier(for: path)
                completionHandler(FileProviderItem(remoteItem: remoteItem, parentID: parentID), nil)
            } catch {
                logger.error("item(for:) failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, nsError(from: error))
            }
        }

        return progress
    }

    public func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            defer { progress.completedUnitCount = 100 }

            do {
                let lease = try await runtimeContextLease()
                defer { lease.finish() }
                let context = lease.context
                let path = itemIdentifier.remotePath
                let cachedItem = await context.cache.get(path: path)
                if let cachedItem,
                   let cachedURL = await context.contentCache.cachedFileURL(for: cachedItem) {
                    let parentID = parentIdentifier(for: path)
                    completionHandler(cachedURL, FileProviderItem(remoteItem: cachedItem, parentID: parentID), nil)
                    return
                }

                let remoteItem = try await context.fileSystem.itemInfo(at: path)
                if let cachedURL = await context.contentCache.cachedFileURL(for: remoteItem) {
                    await context.cache.put(item: remoteItem)
                    let parentID = parentIdentifier(for: path)
                    completionHandler(cachedURL, FileProviderItem(remoteItem: remoteItem, parentID: parentID), nil)
                    return
                }

                let temporaryURL = try await downloadFileToTemporaryURL(
                    at: path,
                    remoteItem: remoteItem,
                    using: context,
                    progress: progress
                )
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                let cachedURL = try await storeContentCache(
                    fileAt: temporaryURL,
                    for: remoteItem,
                    using: context
                )
                await context.cache.put(item: remoteItem)

                let parentID = parentIdentifier(for: path)
                let item = FileProviderItem(remoteItem: remoteItem, parentID: parentID)
                domainVersionState.advance()
                completionHandler(cachedURL, item, nil)
            } catch {
                logger.error("fetchContents failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, nil, nsError(from: error))
            }
        }

        return progress
    }

    public func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        Task {
            defer { progress.completedUnitCount = 1 }

            do {
                let lease = try await runtimeContextLease()
                defer { lease.finish() }
                let context = lease.context
                let parentPath = itemTemplate.parentItemIdentifier.remotePath
                let newPath = parentPath.appending(itemTemplate.filename)
                let createdFileURL: URL?
                var temporaryCreatedFileURL: URL?
                defer {
                    if let temporaryCreatedFileURL {
                        try? FileManager.default.removeItem(at: temporaryCreatedFileURL)
                    }
                }

                if itemTemplate.contentType == .folder {
                    try await context.fileSystem.createDirectory(at: newPath)
                    createdFileURL = nil
                } else if let url = url {
                    try await createFile(at: newPath, from: url, using: context.fileSystem)
                    createdFileURL = url
                } else {
                    let filenamePathExtension = (itemTemplate.filename as NSString).pathExtension
                    let temporaryURL = try context.stateStore.temporaryFileURL(
                        for: UUID().uuidString,
                        extension: filenamePathExtension.isEmpty ? "tmp" : filenamePathExtension
                    )
                    FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
                    temporaryCreatedFileURL = temporaryURL
                    try await createFile(at: newPath, from: temporaryURL, using: context.fileSystem)
                    createdFileURL = temporaryURL
                }

                let remoteItem = try await context.fileSystem.itemInfo(at: newPath)
                await context.cache.put(item: remoteItem)
                await context.cache.invalidateChildren(of: parentPath)
                if let createdFileURL, !remoteItem.isDirectory {
                    do {
                        _ = try await storeContentCache(fileAt: createdFileURL, for: remoteItem, using: context)
                    } catch {
                        logger.error("createItem content cache store failed: \(error.localizedDescription, privacy: .public)")
                        await context.contentCache.invalidate(path: remoteItem.path)
                    }
                }
                let newItem = FileProviderItem(
                    remoteItem: remoteItem,
                    parentID: itemTemplate.parentItemIdentifier
                )
                domainVersionState.advance()
                completionHandler(newItem, [], false, nil)
            } catch {
                logger.error("createItem failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, [], false, nsError(from: error))
            }
        }

        return progress
    }

    public func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        Task {
            defer { progress.completedUnitCount = 1 }

            do {
                let lease = try await runtimeContextLease()
                defer { lease.finish() }
                let context = lease.context
                var currentPath = item.itemIdentifier.remotePath
                var updatedFileURL: URL?
                let originalPath = currentPath

                let targetParent = changedFields.contains(.parentItemIdentifier)
                    ? item.parentItemIdentifier.remotePath
                    : (currentPath.parent ?? .root)
                let targetName = changedFields.contains(.filename)
                    ? item.filename
                    : currentPath.name
                let finalPath = targetParent.appending(targetName)

                if finalPath != originalPath {
                    try await context.fileSystem.move(from: originalPath, to: finalPath)
                    await context.cache.invalidate(path: originalPath)
                    if let originalParent = originalPath.parent {
                        await context.cache.invalidateChildren(of: originalParent)
                    }
                    if let finalParent = finalPath.parent {
                        await context.cache.invalidateChildren(of: finalParent)
                    }
                    await context.contentCache.invalidate(path: originalPath)
                    currentPath = finalPath
                }

                if changedFields.contains(.contents), let url = newContents {
                    try await writeFile(at: currentPath, from: url, using: context.fileSystem)
                    updatedFileURL = url
                }

                let remoteItem = try await context.fileSystem.itemInfo(at: currentPath)
                let parentID = parentIdentifier(for: currentPath)
                await context.cache.put(item: remoteItem)
                if let updatedFileURL {
                    do {
                        _ = try await storeContentCache(fileAt: updatedFileURL, for: remoteItem, using: context)
                    } catch {
                        logger.error("modifyItem content cache store failed: \(error.localizedDescription, privacy: .public)")
                        await context.contentCache.invalidate(path: remoteItem.path)
                    }
                } else {
                    await context.contentCache.invalidate(path: currentPath)
                }
                domainVersionState.advance()
                completionHandler(FileProviderItem(remoteItem: remoteItem, parentID: parentID), [], false, nil)
            } catch {
                logger.error("modifyItem failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, [], false, nsError(from: error))
            }
        }

        return progress
    }

    public func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        Task {
            defer { progress.completedUnitCount = 1 }

            do {
                let lease = try await runtimeContextLease()
                defer { lease.finish() }
                let context = lease.context
                let path = identifier.remotePath
                let deletedItem = await cachedOrRemoteItem(at: path, using: context)
                let descendantItems = await descendantItemsForDeletion(
                    at: path,
                    deletedItem: deletedItem,
                    using: context
                )
                try await context.fileSystem.delete(at: path)
                await invalidateDeletedDescendants(descendantItems, using: context)
                await context.cache.invalidate(path: path)
                await context.contentCache.invalidate(path: path)
                if deletedItem?.isDirectory == true {
                    await context.cache.invalidateChildren(of: path)
                }
                if let parent = path.parent {
                    await context.cache.invalidateChildren(of: parent)
                }
                domainVersionState.advance()
                completionHandler(nil)
            } catch {
                logger.error("deleteItem failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nsError(from: error))
            }
        }

        return progress
    }

    // MARK: - Enumerator

    public func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        FileProviderEnumerator(
            containerID: containerItemIdentifier,
            domainIdentifier: domain.identifier.rawValue
        ) { [weak self] in
            guard let self else {
                throw CancellationError()
            }
            return try await self.runtimeContextLease()
        } errorMapper: { [weak self] error in
            guard let self else {
                return error as NSError
            }
            return self.nsError(from: error)
        }
    }

    // MARK: - Private Setup

    private static func registerBackends() {
        _ = registerBackendsOnce
    }

    private func bootstrapRuntimeContext(for domain: NSFileProviderDomain) async throws -> FileProviderRuntimeContext {
        guard let stateStore = FileProviderDomainStateStore(domain: domain) else {
            throw MountError.mountFailed("Unable to access File Provider manager for domain \(domain.identifier.rawValue)")
        }

        logger.info("Bootstrapping runtime context for domain \(domain.identifier.rawValue, privacy: .public)")

        let config: ConnectionConfig
        if #available(macOS 15.0, *),
           let domainConfig = try FileProviderDomainStateStore.loadBootstrapConfig(from: domain.userInfo) {
            config = domainConfig
            try? stateStore.saveBootstrapConfig(domainConfig)
        } else if let storedConfig = try stateStore.loadBootstrapConfig() {
            config = storedConfig
        } else if let sharedConfig = storage.connection(forDomain: domain.identifier.rawValue) {
            config = sharedConfig
            try? stateStore.saveBootstrapConfig(sharedConfig)
        } else {
            logger.error("No connection config found for domain: \(domain.identifier.rawValue, privacy: .public)")
            throw RemoteFileSystemError.connectionFailed("Missing bootstrap config for \(domain.identifier.rawValue)")
        }

        let credential = try await requireCredential(for: config)
        guard let fileSystem = BackendRegistry.shared.createFileSystem(config: config, credential: credential) else {
            throw RemoteFileSystemError.unsupported("No backend registered for \(config.backendType.rawValue)")
        }

        let metadataCacheURL = try stateStore.metadataCacheURL()
        let syncAnchorStoreURL = try stateStore.syncAnchorStoreURL()
        let contentCacheURL = try stateStore.contentCacheDirectoryURL()
        let cache = MetadataCache(path: metadataCacheURL.path)
        let contentCache = ContentCache(rootURL: contentCacheURL)
        let anchorStore = SyncAnchorStore(path: syncAnchorStoreURL.path)

        do {
            logger.info("Connecting remote filesystem for domain \(config.domainIdentifier, privacy: .public)")
            try await connectFileSystemWithRetry(fileSystem, config: config)
            logger.info("Opening metadata cache at \(metadataCacheURL.path, privacy: .public)")
            try await cache.open()
            logger.info("Opening sync anchor store at \(syncAnchorStoreURL.path, privacy: .public)")
            try await anchorStore.open()
        } catch {
            logger.error(
                "Bootstrap failed for domain \(config.domainIdentifier, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            try? await fileSystem.disconnect()
            await cache.invalidateAll()
            await cache.close()
            await contentCache.invalidateAll()
            await contentCache.close()
            await anchorStore.close()
            stateStore.close()
            throw error
        }

        let context = FileProviderRuntimeContext(
            config: config,
            fileSystem: fileSystem,
            cache: cache,
            contentCache: contentCache,
            anchorStore: anchorStore,
            stateStore: stateStore
        )

        logger.info(
            "Connected to \(config.host, privacy: .public) for domain \(config.domainIdentifier, privacy: .public)"
        )
        domainVersionState.advance()
        return context
    }

    private func connectFileSystemWithRetry(
        _ fileSystem: any RemoteFileSystem,
        config: ConnectionConfig
    ) async throws {
        var lastError: Error?

        for attempt in 0..<Self.bootstrapTransientRetryCount {
            try Task.checkCancellation()
            do {
                try await withOperationTimeout(
                    seconds: Self.bootstrapTimeoutSeconds,
                    operation: "connecting remote filesystem for domain \(config.domainIdentifier)"
                ) {
                    try await fileSystem.connect()
                }
                return
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw error
                }
                lastError = error
                guard attempt < Self.bootstrapTransientRetryCount - 1,
                      shouldRetryTransientConnectionError(error) else {
                    throw error
                }

                logger.warning(
                    "Retrying transient bootstrap connection failure for domain \(config.domainIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                try await Task.sleep(nanoseconds: Self.bootstrapTransientRetryDelayNanoseconds)
            }
        }

        if let lastError {
            throw lastError
        }
    }

    private func shouldRetryTransientConnectionError(_ error: Error) -> Bool {
        // A deadline this extension imposed is not a failure the backend reported: the
        // attempt was cancelled and left to unwind, so it may still be inside `connect()`
        // on the very filesystem a retry would connect again. Two connects interleaving on
        // one instance is how an abandoned attempt finished after the retry and left the
        // session it opened owned by nobody. The retry happens a level up instead, where
        // `runtimeContext()` clears the failed bootstrap and the next request builds a
        // fresh filesystem to attempt on.
        if error is FileProviderOperationTimeout {
            return false
        }
        if let remoteError = error as? RemoteFileSystemError {
            if case .authenticationFailed = remoteError {
                return false
            }
            if remoteError.isTransientConnectionFailure {
                return true
            }
        }

        let normalizedDescription = error.localizedDescription.lowercased()
        let transientIndicators = [
            "no route to host",
            "host is down",
            "network is down",
            "network is unreachable",
            "timed out"
        ]
        return transientIndicators.contains { normalizedDescription.contains($0) }
    }

    private func requireCredential(for config: ConnectionConfig) async throws -> Credential {
        let stored: Credential?
        do {
            stored = try Self.sharedCredentialStoreProvider.credential(for: config.id)
        } catch is DecodingError {
            // A credential item that cannot be decoded is not a server the extension failed
            // to reach: no retry recovers it, and reporting it as unreachable left the
            // domain with no way out. `notAuthenticated` is what asks the user to supply
            // the credential again, which is the only thing that fixes it.
            logger.error(
                "Undecodable credential for domain \(config.domainIdentifier, privacy: .public); reporting it as an authentication failure"
            )
            throw RemoteFileSystemError.authenticationFailed
        }
        let credential = stored ?? Credential()

        switch config.authMethod {
        case .password:
            guard let password = credential.password, !password.isEmpty else {
                throw RemoteFileSystemError.authenticationFailed
            }
        case .publicKey:
            guard let privateKey = credential.privateKey, !privateKey.isEmpty else {
                throw RemoteFileSystemError.authenticationFailed
            }
        case .accessKey:
            guard let accessKeyID = credential.accessKeyID, !accessKeyID.isEmpty,
                  let secretAccessKey = credential.secretAccessKey, !secretAccessKey.isEmpty else {
                throw RemoteFileSystemError.authenticationFailed
            }
        case .oauth:
            guard let token = credential.token, !token.isEmpty else {
                throw RemoteFileSystemError.authenticationFailed
            }
        case .agent, .anonymous:
            break
        }

        return credential
    }

    private func runtimeContext() async throws -> FileProviderRuntimeContext {
        let task = try await currentOrCreateBootstrapTask()

        do {
            return try await task.value
        } catch {
            await bootstrapTaskStore.clearIfCurrent(task)
            throw error
        }
    }

    /// Take the runtime context for one operation, and count that operation while it runs.
    ///
    /// Counted before the context is asked for: raising it afterwards leaves a window in
    /// which teardown sees nothing in flight and starts closing, while this operation is
    /// about to be handed the context it is closing. `BootstrapTaskStore` refuses a context
    /// from the moment teardown takes over, so an operation that lands inside the drain is
    /// turned away instead.
    private func runtimeContextLease() async throws -> FileProviderRuntimeContextLease {
        runtimeContextActivity.begin()
        do {
            let context = try await runtimeContext()
            return FileProviderRuntimeContextLease(context: context, activity: runtimeContextActivity)
        } catch {
            runtimeContextActivity.end()
            throw error
        }
    }

    /// Wait for the operations still holding the runtime context, but not indefinitely.
    ///
    /// The system releases this instance shortly after `invalidate()`; a backend that never
    /// returns from a cancelled read must not hold the teardown for the rest of the
    /// process's life, so the wait is bounded.
    ///
    /// Returns whether everything let go — which is what says the context may be closed.
    private func awaitInFlightOperations() async -> Bool {
        do {
            try await withOperationTimeout(
                seconds: Self.invalidationDrainTimeoutSeconds,
                operation: "waiting for in-flight operations on domain \(domain.identifier.rawValue)"
            ) { [runtimeContextActivity] in
                await runtimeContextActivity.waitUntilIdle()
            }
            return true
        } catch {
            logger.error(
                "Leaving the runtime context for domain \(self.domain.identifier.rawValue, privacy: .public) open: operations are still in flight: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private func storeContentCache(
        fileAt sourceURL: URL,
        for remoteItem: RemoteItem,
        using context: FileProviderRuntimeContext
    ) async throws -> URL {
        var lastError: Error?

        for attempt in 0..<Self.contentCacheStoreRetryCount {
            do {
                return try await context.contentCache.store(fileAt: sourceURL, for: remoteItem)
            } catch {
                lastError = error
                await context.contentCache.invalidate(path: remoteItem.path)
                guard attempt < Self.contentCacheStoreRetryCount - 1 else { break }
            }
        }

        throw lastError ?? RemoteFileSystemError.operationFailed(
            "Failed to cache content for \(remoteItem.path.absoluteString)"
        )
    }

    private func createFile(
        at path: RemotePath,
        from localFileURL: URL,
        using fileSystem: any RemoteFileSystem
    ) async throws {
        do {
            try await fileSystem.createFile(at: path, from: localFileURL)
        } catch let error as RemoteFileSystemError {
            guard case .unsupported = error else {
                throw error
            }
            let data = try Data(contentsOf: localFileURL, options: .mappedIfSafe)
            try await fileSystem.createFile(at: path, data: data)
        }
    }

    private func writeFile(
        at path: RemotePath,
        from localFileURL: URL,
        using fileSystem: any RemoteFileSystem
    ) async throws {
        do {
            try await fileSystem.writeFile(at: path, from: localFileURL)
        } catch let error as RemoteFileSystemError {
            guard case .unsupported = error else {
                throw error
            }
            let data = try Data(contentsOf: localFileURL, options: .mappedIfSafe)
            try await fileSystem.writeFile(at: path, data: data)
        }
    }

    private func downloadFileToTemporaryURL(
        at path: RemotePath,
        remoteItem: RemoteItem,
        using context: FileProviderRuntimeContext,
        progress: Progress
    ) async throws -> URL {
        let pathExtension = remoteItem.path.pathExtension ?? "tmp"
        let temporaryURL = try context.stateStore.temporaryFileURL(
            for: UUID().uuidString,
            extension: pathExtension.isEmpty ? "tmp" : pathExtension
        )
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        var shouldDeleteTemporaryFile = true

        do {
            defer { try? handle.close() }

            if supportsChunkedRead(for: context.config.backendType) {
                let totalBytes = max(remoteItem.size, 1)
                var offset: UInt64 = 0

                while true {
                    let chunk = try await context.fileSystem.readFile(
                        at: path,
                        offset: offset,
                        length: Self.streamedReadChunkSize
                    )
                    if chunk.isEmpty {
                        break
                    }

                    try handle.write(contentsOf: chunk)
                    offset += UInt64(chunk.count)
                    progress.completedUnitCount = min(80, Int64((offset * 80) / totalBytes))

                    if remoteItem.size > 0 && offset >= remoteItem.size {
                        break
                    }
                }
            } else {
                let data = try await context.fileSystem.readFile(at: path)
                try handle.write(contentsOf: data)
                progress.completedUnitCount = 80
            }

            shouldDeleteTemporaryFile = false
            return temporaryURL
        } catch {
            try? handle.close()
            if shouldDeleteTemporaryFile {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            throw error
        }
    }

    private func supportsChunkedRead(for backendType: BackendType) -> Bool {
        switch backendType {
        case .s3, .sftp:
            return true
        default:
            return false
        }
    }

    private func cachedOrRemoteItem(
        at path: RemotePath,
        using context: FileProviderRuntimeContext
    ) async -> RemoteItem? {
        if let remoteItem = try? await context.fileSystem.itemInfo(at: path) {
            return remoteItem
        }

        return await context.cache.get(path: path)
    }

    private func descendantItemsForDeletion(
        at path: RemotePath,
        deletedItem: RemoteItem?,
        using context: FileProviderRuntimeContext
    ) async -> [RemoteItem] {
        guard deletedItem?.isDirectory == true else {
            return []
        }

        let cachedDescendants = await context.cache.descendants(of: path)
        return cachedDescendants.sorted { lhs, rhs in
            lhs.path.components.count > rhs.path.components.count
        }
    }

    private func invalidateDeletedDescendants(
        _ descendants: [RemoteItem],
        using context: FileProviderRuntimeContext
    ) async {
        for item in descendants {
            await context.cache.invalidate(path: item.path)
            if item.isDirectory {
                await context.cache.invalidateChildren(of: item.path)
            }
            await context.contentCache.invalidate(path: item.path)
        }
    }

    private func currentOrCreateBootstrapTask() async throws -> Task<FileProviderRuntimeContext, Error> {
        try await bootstrapTaskStore.currentOrCreate {
            let task = Task { [weak self, domain] in
                guard let self else {
                    throw CancellationError()
                }
                return try await self.bootstrapRuntimeContext(for: domain)
            }
            return task
        }
    }

    private func parentIdentifier(for path: RemotePath) -> NSFileProviderItemIdentifier {
        guard let parent = path.parent else { return .rootContainer }
        if parent.isRoot { return .rootContainer }
        return NSFileProviderItemIdentifier(parent.absoluteString)
    }

    private func nsError(from error: Error) -> NSError {
        if let rfsError = error as? RemoteFileSystemError {
            switch rfsError {
            case .notFound:
                return NSError(domain: NSFileProviderErrorDomain,
                               code: NSFileProviderError.noSuchItem.rawValue)
            case .notDirectory, .notFile:
                return NSError(
                    domain: NSFileProviderErrorDomain,
                    code: NSFileProviderError.noSuchItem.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "\(rfsError)"]
                )
            case .alreadyExists:
                return NSError(domain: NSFileProviderErrorDomain,
                               code: NSFileProviderError.filenameCollision.rawValue)
            case .notConnected, .connectionFailed:
                return NSError(domain: NSFileProviderErrorDomain,
                               code: NSFileProviderError.serverUnreachable.rawValue,
                               userInfo: [NSLocalizedDescriptionKey: "\(rfsError)"])
            case .permissionDenied:
                // Not `serverUnreachable`: the server answered, and it answered "no". Told
                // it is unreachable, Finder offers to retry a request that will be refused
                // the same way every time and says nothing about access. A POSIX EACCES is
                // what the file system layer above turns into the permission error the user
                // can act on.
                return NSError(domain: NSPOSIXErrorDomain,
                               code: Int(EACCES),
                               userInfo: [NSLocalizedDescriptionKey: "\(rfsError)"])
            case .authenticationFailed:
                return NSError(domain: NSFileProviderErrorDomain,
                               code: NSFileProviderError.notAuthenticated.rawValue)
            default:
                return NSError(domain: NSFileProviderErrorDomain,
                               code: NSFileProviderError.serverUnreachable.rawValue,
                               userInfo: [NSLocalizedDescriptionKey: "\(rfsError)"])
            }
        }
        if error is FileProviderExtensionInvalidated {
            return NSError(
                domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.serverUnreachable.rawValue,
                userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]
            )
        }
        if let mountError = error as? MountError {
            return NSError(
                domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.serverUnreachable.rawValue,
                userInfo: [NSLocalizedDescriptionKey: mountError.localizedDescription]
            )
        }
        // The HTTP backends hand their transport failures back as they come, and File
        // Provider has no reading of `NSURLErrorDomain`: a host that could not be resolved
        // or a connection that dropped reached Finder as an error it could not act on
        // instead of a server it cannot reach. Cancellation is left alone — it is this
        // extension stopping its own work, not the server.
        if let urlError = error as? URLError, urlError.code != .cancelled {
            return NSError(
                domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.serverUnreachable.rawValue,
                userInfo: [NSLocalizedDescriptionKey: urlError.localizedDescription]
            )
        }
        return error as NSError
    }
}
