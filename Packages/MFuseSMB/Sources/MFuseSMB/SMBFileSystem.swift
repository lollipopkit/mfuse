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
        let client = try requireClient()
        let smbPath = resolvedPath(path)
        let files = try await client.listDirectory(path: smbPath)
        return files.compactMap { file -> RemoteItem? in
            let name = file.name
            guard name != "." && name != ".." else { return nil }
            guard !file.isHidden else { return nil }
            let childPath = path.appending(name)
            return RemoteItem(
                path: childPath,
                type: file.isDirectory ? .directory : .file,
                size: file.size,
                modificationDate: file.lastWriteTime,
                creationDate: file.creationTime
            )
        }
    }

    public func itemInfo(at path: RemotePath) async throws -> RemoteItem {
        let client = try requireClient()
        let smbPath = resolvedPath(path)
        let stat = try await client.fileStat(path: smbPath)
        return RemoteItem(
            path: path,
            type: stat.isDirectory ? .directory : .file,
            size: stat.size,
            modificationDate: stat.lastWriteTime,
            creationDate: stat.creationTime
        )
    }

    // MARK: - Read

    public func readFile(at path: RemotePath) async throws -> Data {
        let client = try requireClient()
        let smbPath = resolvedPath(path)
        return try await client.download(path: smbPath)
    }

    // MARK: - Write

    public func writeFile(at path: RemotePath, data: Data) async throws {
        let client = try requireClient()
        let smbPath = resolvedPath(path)
        try await client.upload(content: data, path: smbPath)
    }

    public func createFile(at path: RemotePath, data: Data) async throws {
        let client = try requireClient()
        let smbPath = resolvedPath(path)
        do {
            try await client.upload(content: data, path: smbPath)
        } catch let error as ErrorResponse where NTStatus(error.header.status) == .objectNameCollision {
            throw RemoteFileSystemError.alreadyExists(path)
        } catch {
            throw error
        }
    }

    // MARK: - Mutations

    public func createDirectory(at path: RemotePath) async throws {
        let client = try requireClient()
        let smbPath = resolvedPath(path)
        try await client.createDirectory(path: smbPath)
    }

    public func delete(at path: RemotePath) async throws {
        let client = try requireClient()
        let smbPath = resolvedPath(path)
        let stat = try await client.fileStat(path: smbPath)
        if stat.isDirectory {
            try await client.deleteDirectory(path: smbPath)
        } else {
            try await client.deleteFile(path: smbPath)
        }
    }

    public func move(from source: RemotePath, to destination: RemotePath) async throws {
        let client = try requireClient()
        try await client.move(from: resolvedPath(source), to: resolvedPath(destination))
    }

    // MARK: - Helpers

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
