import FileProvider
import MFuseCore
import MFuseSFTP
import MFuseS3
import MFuseWebDAV
import MFuseSMB
import MFuseFTP
import MFuseNFS
import MFuseGoogleDrive
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

    func take() -> Task<FileProviderRuntimeContext, Error>? {
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
    ) -> Task<FileProviderRuntimeContext, Error> {
        if let bootstrapTask {
            return bootstrapTask
        }

        let task = create()
        bootstrapTask = task
        return task
    }
}

actor CleanupTaskStore {
    private var cleanupTask: Task<Void, Never>?
    private var cleanupTaskID: UUID?

    func replace(with task: Task<Void, Never>, id: UUID) {
        cleanupTask?.cancel()
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
            return "Timed out while \(operation)"
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

@Sendable
func withOperationTimeout<T: Sendable>(
    seconds: Double,
    operation: String,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await work()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw FileProviderOperationTimeout.timedOut(operation)
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// The File Provider Replicated Extension — bridges the macOS File Provider framework
/// to the MFuse VFS layer.
public final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderDomainState {

    private static let bootstrapTimeoutSeconds = 15.0
    private static let bootstrapTransientRetryCount = 2
    private static let bootstrapTransientRetryDelayNanoseconds: UInt64 = 750_000_000
    private static let contentCacheStoreRetryCount = 2
    private static let streamedReadChunkSize: UInt32 = 1_048_576
    private static let sharedCredentialStore = SharedCredentialStore()
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
                    try FileProviderExtension.sharedCredentialStore.store(updatedCredential, for: config.id)
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

            let bootstrapTask = await self.bootstrapTaskStore.take()
            bootstrapTask?.cancel()
            guard let bootstrapTask, let context = try? await bootstrapTask.value else { return }

            try? await context.fileSystem.disconnect()
            await context.cache.close()
            await context.contentCache.close()
            await context.anchorStore.close()
            context.stateStore.close()
        }

        Task {
            await cleanupTaskStore.replace(with: cleanupTask, id: cleanupTaskID)
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

                let context = try await runtimeContext()
                let path = identifier.remotePath
                let remoteItem = try await context.fileSystem.itemInfo(at: path)
                let parentID = parentIdentifier(for: path)
                completionHandler(FileProviderItem(remoteItem: remoteItem, parentID: parentID), nil)
            } catch {
                logger.error("item(for:) failed: \(error.localizedDescription)")
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
                let context = try await runtimeContext()
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
                logger.error("fetchContents failed: \(error.localizedDescription)")
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
                let context = try await runtimeContext()
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
                        logger.error("createItem content cache store failed: \(error.localizedDescription)")
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
                logger.error("createItem failed: \(error.localizedDescription)")
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
                let context = try await runtimeContext()
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
                        logger.error("modifyItem content cache store failed: \(error.localizedDescription)")
                        await context.contentCache.invalidate(path: remoteItem.path)
                    }
                } else {
                    await context.contentCache.invalidate(path: currentPath)
                }
                domainVersionState.advance()
                completionHandler(FileProviderItem(remoteItem: remoteItem, parentID: parentID), [], false, nil)
            } catch {
                logger.error("modifyItem failed: \(error.localizedDescription)")
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
                let context = try await runtimeContext()
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
                logger.error("deleteItem failed: \(error.localizedDescription)")
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
            return try await self.runtimeContext()
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
        let credential = try Self.sharedCredentialStore.credential(for: config.id) ?? Credential()

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
        let task = await currentOrCreateBootstrapTask()

        do {
            return try await task.value
        } catch {
            await bootstrapTaskStore.clearIfCurrent(task)
            throw error
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

    private func currentOrCreateBootstrapTask() async -> Task<FileProviderRuntimeContext, Error> {
        await bootstrapTaskStore.currentOrCreate {
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
                return NSError(domain: NSFileProviderErrorDomain,
                               code: NSFileProviderError.serverUnreachable.rawValue,
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
        if let mountError = error as? MountError {
            return NSError(
                domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.serverUnreachable.rawValue,
                userInfo: [NSLocalizedDescriptionKey: mountError.localizedDescription]
            )
        }
        return error as NSError
    }
}
