import Foundation
import MFuseCore
import NIO
import NIOFoundationCompat

/// FTP/FTPS implementation of `RemoteFileSystem` using SwiftNIO.
public actor FTPFileSystem: RemoteFileSystem {

    private let config: ConnectionConfig
    private let credential: Credential
    private var connection: FTPConnection?

    public var isConnected: Bool { connection != nil }

    public init(config: ConnectionConfig, credential: Credential) {
        self.config = config
        self.credential = credential
    }

    // MARK: - Config Helpers

    private var useTLS: Bool { config.parameters["tls"] == "true" }
    private var passiveMode: Bool { config.parameters["passive"] != "false" }

    // MARK: - Lifecycle

    public func connect() async throws {
        let conn = FTPConnection(host: config.host, port: Int(config.port), useTLS: useTLS)

        do {
            try await conn.connect()
        } catch {
            throw RemoteFileSystemError.connectionFailed(error.localizedDescription)
        }

        do {
            // Authenticate
            if config.authMethod == .anonymous {
                let userResp = try await conn.sendCommand("USER anonymous")
                if userResp.code == 331 {
                    let passResp = try await conn.sendCommand("PASS anonymous@")
                    guard passResp.code == 230 else {
                        throw RemoteFileSystemError.authenticationFailed
                    }
                } else if userResp.code != 230 {
                    throw RemoteFileSystemError.authenticationFailed
                }
            } else {
                let userResp = try await conn.sendCommand("USER \(config.username)")
                if userResp.code == 331 {
                    let passResp = try await conn.sendCommand("PASS \(credential.password ?? "")")
                    guard passResp.code == 230 else {
                        throw RemoteFileSystemError.authenticationFailed
                    }
                } else if userResp.code != 230 {
                    throw RemoteFileSystemError.authenticationFailed
                }
            }

            // Set binary mode
            _ = try await conn.sendCommand("TYPE I")
        } catch {
            try? await conn.close()
            throw error
        }

        self.connection = conn
    }

    public func disconnect() async throws {
        if let conn = connection {
            _ = try? await conn.sendCommand("QUIT")
            try? await conn.close()
        }
        connection = nil
    }

    // MARK: - Enumeration

    public func enumerate(at path: RemotePath) async throws -> [RemoteItem] {
        let conn = try requireConnection()
        let remotePath = resolvedPath(path)

        // Open data connection and send LIST
        let (dataChannel, dataHandler) = try await conn.openDataConnection()
        let response = try await conn.sendCommand("LIST \(remotePath)")
        guard response.code == 150 || response.code == 125 else {
            try await dataChannel.close()
            throw RemoteFileSystemError.operationFailed("LIST failed: \(response.text)")
        }

        let rawData = try await dataHandler.collectData()
        // Read transfer complete
        _ = try await conn.readResponse() // wait for server-initiated transfer completion
        let listing = String(data: rawData, encoding: .utf8) ?? ""

        return FTPDirectoryParser.parse(listing).map { entry in
            let childPath = path.appending(entry.name)
            return RemoteItem(
                path: childPath,
                type: entry.isDirectory ? .directory : .file,
                size: entry.size,
                modificationDate: entry.modificationDate ?? Date(),
                permissions: entry.permissions
            )
        }
    }

    public func itemInfo(at path: RemotePath) async throws -> RemoteItem {
        let conn = try requireConnection()
        let remotePath = resolvedPath(path)

        let mlstResp = try await conn.sendCommand("MLST \(remotePath)")
        if mlstResp.code == 250 {
            guard let item = parseMLSTResponse(mlstResp.text, path: path) else {
                throw RemoteFileSystemError.operationFailed("MLST parse failed: \(mlstResp.text)")
            }
            return item
        }

        if mlstResp.code == 550 {
            throw RemoteFileSystemError.notFound(path)
        }

        guard isUnsupportedMLSTResponse(mlstResp) else {
            throw RemoteFileSystemError.operationFailed("MLST failed: \(mlstResp.text)")
        }

        // Fall back for servers without MLST support.
        let sizeResp = try await conn.sendCommand("SIZE \(remotePath)")
        if sizeResp.code == 213 {
            let size = sizeResp.text.split(separator: " ").last.flatMap { UInt64($0) } ?? 0
            let mdtmResp = try await conn.sendCommand("MDTM \(remotePath)")
            let date = mdtmResp.code == 213 ? (parseMDTM(mdtmResp.text) ?? Date()) : Date()
            return RemoteItem(path: path, type: .file, size: size, modificationDate: date)
        }

        return try await itemInfoFromListingFallback(at: path, using: conn)
    }

    // MARK: - Read

    public func readFile(at path: RemotePath) async throws -> Data {
        let conn = try requireConnection()
        let remotePath = resolvedPath(path)

        let (dataChannel, dataHandler) = try await conn.openDataConnection()
        let response = try await conn.sendCommand("RETR \(remotePath)")
        guard response.code == 150 || response.code == 125 else {
            try await dataChannel.close()
            if response.code == 550 {
                throw RemoteFileSystemError.notFound(path)
            }
            throw RemoteFileSystemError.operationFailed("RETR failed: \(response.text)")
        }

        let data = try await dataHandler.collectData()
        // Wait for transfer complete (226)
        let doneResp = try await conn.readResponse()
        if doneResp.code != 226 && doneResp.code != 250 {
            // Some servers are lenient
        }
        return data
    }

    // MARK: - Write

    public func writeFile(at path: RemotePath, data: Data) async throws {
        let conn = try requireConnection()
        let remotePath = resolvedPath(path)

        let (dataChannel, _) = try await conn.openDataConnection()
        let response = try await conn.sendCommand("STOR \(remotePath)")
        guard response.code == 150 || response.code == 125 else {
            try await dataChannel.close()
            throw RemoteFileSystemError.operationFailed("STOR failed: \(response.text)")
        }

        var buffer = dataChannel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await dataChannel.writeAndFlush(buffer)
        try await dataChannel.close()

        // Wait for transfer complete
        let doneResp = try await conn.readResponse()
        if doneResp.code != 226 && doneResp.code != 250 {
            throw RemoteFileSystemError.operationFailed("Upload failed: \(doneResp.text)")
        }
    }

    public func createFile(at path: RemotePath, data: Data) async throws {
        do {
            _ = try await itemInfo(at: path)
            throw RemoteFileSystemError.alreadyExists(path)
        } catch let error as RemoteFileSystemError {
            switch error {
            case .notFound:
                try await writeFile(at: path, data: data)
            default:
                throw error
            }
        }
    }

    // MARK: - Mutations

    public func createDirectory(at path: RemotePath) async throws {
        let conn = try requireConnection()
        let remotePath = resolvedPath(path)
        let resp = try await conn.sendCommand("MKD \(remotePath)")
        guard resp.code == 257 else {
            throw RemoteFileSystemError.operationFailed("MKD failed: \(resp.text)")
        }
    }

    public func delete(at path: RemotePath) async throws {
        let conn = try requireConnection()
        let remotePath = resolvedPath(path)

        // Try DELE (file) first, then RMD (directory)
        let deleResp = try await conn.sendCommand("DELE \(remotePath)")
        if deleResp.code == 250 { return }

        let rmdResp = try await conn.sendCommand("RMD \(remotePath)")
        guard rmdResp.code == 250 else {
            throw RemoteFileSystemError.operationFailed("Delete failed: \(rmdResp.text)")
        }
    }

    public func move(from source: RemotePath, to destination: RemotePath) async throws {
        let conn = try requireConnection()
        let srcPath = resolvedPath(source)
        let dstPath = resolvedPath(destination)

        let rnfrResp = try await conn.sendCommand("RNFR \(srcPath)")
        guard rnfrResp.code == 350 else {
            throw RemoteFileSystemError.operationFailed("RNFR failed: \(rnfrResp.text)")
        }
        let rntoResp = try await conn.sendCommand("RNTO \(dstPath)")
        guard rntoResp.code == 250 else {
            throw RemoteFileSystemError.operationFailed("RNTO failed: \(rntoResp.text)")
        }
    }

    // MARK: - Helpers

    private func requireConnection() throws -> FTPConnection {
        guard let connection = connection else {
            throw RemoteFileSystemError.notConnected
        }
        return connection
    }

    private func resolvedPath(_ path: RemotePath) -> String {
        if path.isRoot { return config.remotePath }
        let base = config.remotePath.hasSuffix("/") ? config.remotePath : config.remotePath + "/"
        return base + path.components.joined(separator: "/")
    }

    private func isUnsupportedMLSTResponse(_ response: FTPResponse) -> Bool {
        [500, 501, 502, 504].contains(response.code)
    }

    private func itemInfoFromListingFallback(at path: RemotePath, using conn: FTPConnection) async throws -> RemoteItem {
        let targetPath = path.parent ?? path
        let remotePath = resolvedPath(targetPath)
        let (dataChannel, dataHandler) = try await conn.openDataConnection()
        let response = try await conn.sendCommand("LIST \(remotePath)")
        guard response.code == 150 || response.code == 125 else {
            try await dataChannel.close()
            if response.code == 550 {
                throw RemoteFileSystemError.notFound(path)
            }
            throw RemoteFileSystemError.operationFailed("LIST failed: \(response.text)")
        }

        let rawData = try await dataHandler.collectData()
        let doneResp = try await conn.readResponse()
        if doneResp.code != 226 && doneResp.code != 250 {
            throw RemoteFileSystemError.operationFailed("LIST completion failed: \(doneResp.text)")
        }

        if path.isRoot {
            return RemoteItem(path: path, type: .directory, modificationDate: Date())
        }

        let listing = String(data: rawData, encoding: .utf8) ?? ""
        guard let entry = FTPDirectoryParser.parse(listing).first(where: { $0.name == path.name }) else {
            throw RemoteFileSystemError.notFound(path)
        }

        return RemoteItem(
            path: path,
            type: entry.isDirectory ? .directory : .file,
            size: entry.size,
            modificationDate: entry.modificationDate ?? Date(),
            permissions: entry.permissions
        )
    }

    private func parseMLSTResponse(_ text: String, path: RemotePath) -> RemoteItem? {
        let lines = text.components(separatedBy: .newlines)
        guard let factsLine = lines
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { $0.contains("=") && $0.contains(";") && !$0.hasPrefix("250 ") && !$0.hasPrefix("250-") })
        else {
            return nil
        }

        let factsPart = factsLine.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)
            ?? factsLine
        let facts = factsPart
            .split(separator: ";", omittingEmptySubsequences: true)
            .reduce(into: [String: String]()) { result, fact in
                let parts = fact.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return }
                result[String(parts[0]).lowercased()] = String(parts[1])
            }

        guard let typeFact = facts["type"]?.lowercased() else { return nil }

        let itemType: RemoteItemType = typeFact.contains("dir") ? .directory : .file
        let size = UInt64(facts["size"] ?? "") ?? 0
        let modificationDate = facts["modify"].flatMap(parseMDTM) ?? Date()
        let permissions = facts["unix.mode"].flatMap { UInt16($0, radix: 8) }

        return RemoteItem(
            path: path,
            type: itemType,
            size: size,
            modificationDate: modificationDate,
            permissions: permissions
        )
    }

    /// Parse MDTM response: "213 20250101120000" → Date
    private func parseMDTM(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        guard let rawTimeStr = parts.last else { return nil }
        let timeStr = String(rawTimeStr.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first ?? rawTimeStr)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: timeStr)
    }
}
