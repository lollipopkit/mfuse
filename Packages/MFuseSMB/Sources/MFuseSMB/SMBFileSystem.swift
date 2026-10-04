import Foundation
import MFuseCore
import SMBClient

/// SMB implementation of `RemoteFileSystem` using SMBClient.
public actor SMBFileSystem: RemoteFileSystem {

    private let config: ConnectionConfig
    private let credential: Credential
    private var client: SMBClient?

    public var isConnected: Bool { client != nil }

    public init(config: ConnectionConfig, credential: Credential) {
        self.config = config
        self.credential = credential
    }

    // MARK: - Config Helpers

    private var share: String { config.parameters["share"] ?? "" }
    private var domain: String? { config.parameters["domain"] }

    // MARK: - Lifecycle

    public func connect() async throws {
        guard !share.isEmpty else {
            throw RemoteFileSystemError.connectionFailed("SMB share name is required")
        }

        let smb = SMBClient(host: config.host, port: Int(config.port))

        do {
            try await smb.login(
                username: config.username.isEmpty ? nil : config.username,
                password: credential.password,
                domain: domain
            )
            try await smb.connectShare(share)
        } catch {
            throw RemoteFileSystemError.connectionFailed(error.localizedDescription)
        }

        self.client = smb
    }

    public func disconnect() async throws {
        if let client = client {
            _ = try? await client.disconnectShare()
            _ = try? await client.logoff()
        }
        client = nil
    }

    // MARK: - Enumeration

    public func enumerate(at path: RemotePath) async throws -> [RemoteItem] {
        let files = try await perform(on: path) { client, smbPath in
            try await client.listDirectory(path: smbPath)
        }
        return files.compactMap { file -> RemoteItem? in
            let name = file.name
            guard name != "." && name != ".." else { return nil }
            let childPath = path.appending(name)
            return RemoteItem(
                path: childPath,
                type: file.isDirectory ? .directory : .file,
                size: file.size,
                modificationDate: file.lastWriteTime,
                creationDate: file.creationTime,
                isHidden: file.isHidden
            )
        }
    }

    public func itemInfo(at path: RemotePath) async throws -> RemoteItem {
        let stat = try await perform(on: path) { client, smbPath in
            try await client.fileStat(path: smbPath)
        }
        return RemoteItem(
            path: path,
            type: stat.isDirectory ? .directory : .file,
            size: stat.size,
            modificationDate: stat.lastWriteTime,
            creationDate: stat.creationTime,
            isHidden: stat.isHidden
        )
    }

    // MARK: - Read

    public func readFile(at path: RemotePath) async throws -> Data {
        try await perform(on: path) { client, smbPath in
            try await client.download(path: smbPath)
        }
    }

    // MARK: - Write

    public func writeFile(at path: RemotePath, data: Data) async throws {
        // Not `upload`: SMBClient opens with `.create`, which refuses a file that exists,
        // so replacing one — every save from Finder — failed with "object name already
        // exists". `.overwriteIf` truncates the existing file, or creates it when missing.
        try await perform(on: path) { client, smbPath in
            try await Self.write(data, to: smbPath, session: client.session, disposition: .overwriteIf)
        }
    }

    public func writeFile(at path: RemotePath, from localFileURL: URL) async throws {
        let data = try Data(contentsOf: localFileURL, options: .mappedIfSafe)
        try await writeFile(at: path, data: data)
    }

    public func createFile(at path: RemotePath, data: Data) async throws {
        try await perform(on: path) { client, smbPath in
            try await Self.write(data, to: smbPath, session: client.session, disposition: .create)
        }
    }

    public func createFile(at path: RemotePath, from localFileURL: URL) async throws {
        let data = try Data(contentsOf: localFileURL, options: .mappedIfSafe)
        try await createFile(at: path, data: data)
    }

    // MARK: - Mutations

    public func createDirectory(at path: RemotePath) async throws {
        try await perform(on: path) { client, smbPath in
            try await client.createDirectory(path: smbPath)
        }
    }

    /// Deletes a file, or a directory with everything in it — what every other backend
    /// does, and what the extension asks for. SMB refuses to delete a directory that is not
    /// empty, so its contents go first.
    public func delete(at path: RemotePath) async throws {
        let item = try await itemInfo(at: path)
        if item.isDirectory {
            for child in try await enumerate(at: path) {
                try await delete(at: child.path)
            }
            try await perform(on: path) { client, smbPath in
                try await client.deleteDirectory(path: smbPath)
            }
        } else {
            try await perform(on: path) { client, smbPath in
                try await client.deleteFile(path: smbPath)
            }
        }
    }

    public func move(from source: RemotePath, to destination: RemotePath) async throws {
        let client = try requireClient()
        do {
            try await client.move(from: resolvedPath(source), to: resolvedPath(destination))
        } catch {
            // A name collision is about where the item was going; anything else is about
            // the item being moved.
            let mapped = Self.mapped(error, path: source)
            if case RemoteFileSystemError.alreadyExists = mapped {
                throw RemoteFileSystemError.alreadyExists(destination)
            }
            throw mapped
        }
    }

    // MARK: - Helpers

    /// Runs one SMB request for `path`, with its failure translated.
    private func perform<T>(
        on path: RemotePath,
        _ body: (SMBClient, String) async throws -> T
    ) async throws -> T {
        let client = try requireClient()
        do {
            return try await body(client, resolvedPath(path))
        } catch {
            throw Self.mapped(error, path: path)
        }
    }

    /// SMBClient reports failures as raw NT status codes. The File Provider extension maps
    /// `RemoteFileSystemError` onto the errors Finder acts on — a missing item, a name
    /// collision — so an untranslated status reached Finder as a generic failure: a file
    /// that was simply gone read as an error.
    static func mapped(_ error: Error, path: RemotePath) -> Error {
        guard let response = error as? ErrorResponse else { return error }
        let status = NTStatus(response.header.status)
        if status == .objectNameNotFound || status == .objectPathNotFound || status == .noSuchFile {
            return RemoteFileSystemError.notFound(path)
        }
        if status == .objectNameCollision {
            return RemoteFileSystemError.alreadyExists(path)
        }
        if status == .accessDenied {
            return RemoteFileSystemError.permissionDenied(path)
        }
        if status == .notADirectory {
            return RemoteFileSystemError.notDirectory(path)
        }
        if status == .fileIsADirectory {
            return RemoteFileSystemError.notFile(path)
        }
        return error
    }

    /// Writes `data` to a file opened with `disposition`, in chunks the server accepts.
    private static func write(
        _ data: Data,
        to smbPath: String,
        session: Session,
        disposition: Create.CreateDisposition
    ) async throws {
        let created = try await session.create(
            desiredAccess: [.readData, .writeData, .appendData, .readAttributes, .readControl, .writeDac],
            fileAttributes: [.archive, .normal],
            shareAccess: [.read, .write, .delete],
            createDisposition: disposition,
            createOptions: [],
            name: smbPath
        )
        do {
            let chunkSize = max(Int(session.maxWriteSize), 1)
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                _ = try await session.write(
                    data: data.subdata(in: offset..<end),
                    fileId: created.fileId,
                    offset: UInt64(offset)
                )
                offset = end
            }
        } catch {
            _ = try? await session.close(fileId: created.fileId)
            throw error
        }
        _ = try await session.close(fileId: created.fileId)
    }

    private func requireClient() throws -> SMBClient {
        guard let client = client else {
            throw RemoteFileSystemError.notConnected
        }
        return client
    }

    /// Convert RemotePath to SMB path (backslash-separated, relative to share root).
    private func resolvedPath(_ path: RemotePath) -> String {
        let baseParts = config.remotePath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
            .split(separator: "/").map(String.init)

        let allParts = baseParts + path.components
        if allParts.isEmpty { return "" }
        return allParts.joined(separator: "\\")
    }
}
