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
public final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    private static let bootstrapTimeoutSeconds = 15.0
    private let domain: NSFileProviderDomain
    private let storage = SharedStorage()
    private let logger = Logger(subsystem: "com.lollipopkit.mfuse.provider", category: "Extension")
    private let bootstrapTaskStore = BootstrapTaskStore()
    private let cleanupTaskStore = CleanupTaskStore()

    public required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        registerBackends()
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
            guard !Task.isCancelled else { return }
            await context.cache.close()
            guard !Task.isCancelled else { return }
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

                let data = try await context.fileSystem.readFile(at: path)
                progress.completedUnitCount = 80
                let cachedURL = try await context.contentCache.store(data: data, for: remoteItem)
                await context.cache.put(item: remoteItem)

                let parentID = parentIdentifier(for: path)
                let item = FileProviderItem(remoteItem: remoteItem, parentID: parentID)
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
                var createdData: Data?

                if itemTemplate.contentType == .folder {
                    try await context.fileSystem.createDirectory(at: newPath)
                } else if let url = url {
                    let data = try Data(contentsOf: url)
                    try await context.fileSystem.createFile(at: newPath, data: data)
                    createdData = data
                } else {
                    let data = Data()
                    try await context.fileSystem.createFile(at: newPath, data: data)
                    createdData = data
                }

                let remoteItem = try await context.fileSystem.itemInfo(at: newPath)
                await context.cache.put(item: remoteItem)
                await context.cache.invalidateChildren(of: parentPath)
                if let createdData, !remoteItem.isDirectory {
                    _ = try await context.contentCache.store(data: createdData, for: remoteItem)
                }
                let newItem = FileProviderItem(
                    remoteItem: remoteItem,
                    parentID: itemTemplate.parentItemIdentifier
                )
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
                var updatedData: Data?
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
                    await context.contentCache.invalidate(path: originalPath)
                    currentPath = finalPath
                }

                if changedFields.contains(.contents), let url = newContents {
                    let data = try Data(contentsOf: url)
                    try await context.fileSystem.writeFile(at: currentPath, data: data)
                    updatedData = data
                }

                let remoteItem = try await context.fileSystem.itemInfo(at: currentPath)
                let parentID = parentIdentifier(for: currentPath)
                await context.cache.put(item: remoteItem)
                if let updatedData {
                    _ = try await context.contentCache.store(data: updatedData, for: remoteItem)
                } else {
                    await context.contentCache.invalidate(path: currentPath)
                }
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
                try await context.fileSystem.delete(at: path)
                await context.cache.invalidate(path: path)
                await context.contentCache.invalidate(path: path)
                if let parent = path.parent {
                    await context.cache.invalidateChildren(of: parent)
                }
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

    private func registerBackends() {
        BackendRegistry.shared.register(.sftp) { config, credential in
            SFTPFileSystem(config: config, credential: credential)
        }
        BackendRegistry.shared.register(.s3) { config, credential in
            S3FileSystem(config: config, credential: credential)
        }
        BackendRegistry.shared.register(.webdav) { config, credential in
            WebDAVFileSystem(config: config, credential: credential)
        }
        BackendRegistry.shared.register(.smb) { config, credential in
            SMBFileSystem(config: config, credential: credential)
        }
        BackendRegistry.shared.register(.ftp) { config, credential in
            FTPFileSystem(config: config, credential: credential)
        }
        BackendRegistry.shared.register(.nfs) { config, credential in
            NFSFileSystem(config: config, credential: credential)
        }
        BackendRegistry.shared.register(.googleDrive) { config, credential in
            let keychain = KeychainService()
            return GoogleDriveFileSystem(
                config: config,
                credential: credential
            ) { updatedCredential in
                try await keychain.store(updatedCredential, for: config.id)
            }
        }
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
            try await withOperationTimeout(
                seconds: Self.bootstrapTimeoutSeconds,
                operation: "connecting remote filesystem for domain \(config.domainIdentifier)"
            ) {
                try await fileSystem.connect()
            }
            logger.info("Opening metadata cache at \(metadataCacheURL.path, privacy: .public)")
            try await cache.open()
            logger.info("Opening sync anchor store at \(syncAnchorStoreURL.path, privacy: .public)")
            try await anchorStore.open()
        } catch {
            logger.error(
                "Bootstrap failed for domain \(config.domainIdentifier, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            try? await fileSystem.disconnect()
            await cache.close()
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
        return context
    }

    private func requireCredential(for config: ConnectionConfig) async throws -> Credential {
        let keychain = KeychainService()
        let credential = try await keychain.credential(for: config.id) ?? Credential()

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
            case .alreadyExists:
                return NSError(domain: NSFileProviderErrorDomain,
                               code: NSFileProviderError.filenameCollision.rawValue)
            case .notConnected, .connectionFailed:
                return NSError(domain: NSFileProviderErrorDomain,
                               code: NSFileProviderError.serverUnreachable.rawValue,
                               userInfo: [NSLocalizedDescriptionKey: "\(rfsError)"])
            case .permissionDenied:
                return NSError(domain: NSFileProviderErrorDomain,
                               code: NSFileProviderError.notAuthenticated.rawValue)
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
