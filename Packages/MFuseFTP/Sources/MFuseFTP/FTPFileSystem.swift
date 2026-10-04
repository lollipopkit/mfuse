import Foundation
import MFuseCore
import NIO
import NIOFoundationCompat
import NIOSSL

/// FTP/FTPS implementation of `RemoteFileSystem` using SwiftNIO.
public actor FTPFileSystem: RemoteFileSystem {
    private static let uploadChunkSize = 1_048_576
    private static let mdtmFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter
    }()

    private let config: ConnectionConfig
    private let credential: Credential
    private let additionalTrustRoots: [NIOSSLCertificate]
    private var connection: FTPConnection?
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public var isConnected: Bool { connection != nil }

    public init(config: ConnectionConfig, credential: Credential) {
        self.init(config: config, credential: credential, additionalTrustRoots: [])
    }

    /// For tests against servers whose certificate a private CA signed.
    init(config: ConnectionConfig, credential: Credential, additionalTrustRoots: [NIOSSLCertificate]) {
        self.config = config
        self.credential = credential
        self.additionalTrustRoots = additionalTrustRoots
    }

    // MARK: - Config Helpers

    /// With TLS on, port 990 means implicit FTPS, the port's registered use; any other port
    /// means explicit FTPS (`AUTH TLS`), the standard form.
    private var security: FTPSecurity {
        guard config.parameters["tls"] == "true" else { return .none }
        return config.port == 990 ? .implicit : .explicit
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        try await serialized { try await openConnection() }
    }

    public func disconnect() async throws {
        try await serialized {
            guard let conn = connection else { return }
            defer { connection = nil }
            _ = try? await conn.sendCommand("QUIT")
            try await conn.close()
        }
    }

    private func openConnection() async throws {
        let conn: FTPConnection
        do {
            conn = try FTPConnection(
                host: config.host,
                port: Int(config.port),
                security: security,
                additionalTrustRoots: additionalTrustRoots
            )
            try await conn.connect()
        } catch {
            throw RemoteFileSystemError.connectionFailed(error.localizedDescription)
        }

        do {
            let user = config.authMethod == .anonymous ? "anonymous" : config.username
            let password = config.authMethod == .anonymous ? "anonymous@" : (credential.password ?? "")
            let userResp = try await conn.sendCommand("USER \(user)")
            if userResp.code == 331 {
                let passResp = try await conn.sendCommand("PASS \(password)")
                guard passResp.code == 230 else {
                    throw RemoteFileSystemError.authenticationFailed
                }
            } else if userResp.code != 230 {
                throw RemoteFileSystemError.authenticationFailed
            }

            if security != .none {
                // Without `PROT P` data connections stay in plain text (RFC 4217 section 9).
                for command in ["PBSZ 0", "PROT P"] {
                    let response = try await conn.sendCommand(command)
                    guard (200..<300).contains(response.code) else {
                        throw RemoteFileSystemError.connectionFailed(
                            "Server refused to protect data connections (\(command)): \(response.text)"
                        )
                    }
                }
            }

            let typeResp = try await conn.sendCommand("TYPE I")
            guard (200..<300).contains(typeResp.code) else {
                throw FTPError.unexpectedResponse(typeResp)
            }
        } catch {
            try? await conn.close()
            throw mapConnectionError(error)
        }

        self.connection = conn
    }

    // MARK: - Enumeration

    public func enumerate(at path: RemotePath) async throws -> [RemoteItem] {
        try await serialized {
            let listing = try await download("LIST \(resolvedPath(path))", path: path)
            return Self.entries(in: listing).map { entry in
                RemoteItem(
                    path: path.appending(entry.name),
                    type: entry.isDirectory ? .directory : .file,
                    size: entry.size,
                    modificationDate: entry.modificationDate ?? Date(),
                    permissions: entry.permissions
                )
            }
        }
    }

    public func itemInfo(at path: RemotePath) async throws -> RemoteItem {
        try await serialized { try await info(at: path) }
    }

    private func info(at path: RemotePath) async throws -> RemoteItem {
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

        return try await infoFromParentListing(at: path)
    }

    private func infoFromParentListing(at path: RemotePath) async throws -> RemoteItem {
        if path.isRoot {
            return RemoteItem(path: path, type: .directory, modificationDate: Date())
        }
        let parent = path.parent ?? path
        let listing = try await download("LIST \(resolvedPath(parent))", path: path)
        guard let entry = Self.entries(in: listing)
            .first(where: { $0.name == path.name }) else {
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

    // MARK: - Read

    public func readFile(at path: RemotePath) async throws -> Data {
        try await serialized { try await download("RETR \(resolvedPath(path))", path: path) }
    }

    // MARK: - Write

    public func writeFile(at path: RemotePath, data: Data) async throws {
        try await serialized { try await store(data, at: path) }
    }

    public func writeFile(at path: RemotePath, from localFileURL: URL) async throws {
        try await serialized { try await store(contentsOf: localFileURL, at: path) }
    }

    public func createFile(at path: RemotePath, data: Data) async throws {
        try await serialized {
            try await requireMissing(path)
            try await store(data, at: path)
        }
    }

    public func createFile(at path: RemotePath, from localFileURL: URL) async throws {
        try await serialized {
            try await requireMissing(path)
            try await store(contentsOf: localFileURL, at: path)
        }
    }

    private func requireMissing(_ path: RemotePath) async throws {
        do {
            _ = try await info(at: path)
        } catch RemoteFileSystemError.notFound {
            return
        }
        throw RemoteFileSystemError.alreadyExists(path)
    }

    private func store(_ data: Data, at path: RemotePath) async throws {
        try await upload(to: path) { channel in
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            try await channel.writeAndFlush(buffer)
        }
    }

    private func store(contentsOf localFileURL: URL, at path: RemotePath) async throws {
        let handle = try FileHandle(forReadingFrom: localFileURL)
        defer { try? handle.close() }
        try await upload(to: path) { channel in
            while let chunk = try handle.read(upToCount: Self.uploadChunkSize), !chunk.isEmpty {
                var buffer = channel.allocator.buffer(capacity: chunk.count)
                buffer.writeBytes(chunk)
                try await channel.writeAndFlush(buffer)
            }
        }
    }

    // MARK: - Mutations

    public func createDirectory(at path: RemotePath) async throws {
        try await serialized {
            let resp = try await requireConnection().sendCommand("MKD \(resolvedPath(path))")
            guard resp.code == 257 else {
                throw RemoteFileSystemError.operationFailed("MKD failed: \(resp.text)")
            }
        }
    }

    public func delete(at path: RemotePath) async throws {
        try await serialized { try await deleteRecursively(at: path) }
    }

    private func deleteRecursively(at path: RemotePath) async throws {
        let item = try await info(at: path)
        if item.isDirectory {
            let listing = try await download("LIST \(resolvedPath(path))", path: path)
            for entry in Self.entries(in: listing) {
                try await deleteRecursively(at: path.appending(entry.name))
            }
        }
        try await deleteFileOrEmptyDirectory(at: path)
    }

    private func deleteFileOrEmptyDirectory(at path: RemotePath) async throws {
        let conn = try requireConnection()
        let remotePath = resolvedPath(path)

        // Try DELE (file) first, then RMD (directory)
        let deleResp = try await conn.sendCommand("DELE \(remotePath)")
        if deleResp.code == 250 { return }
        let normalizedDeleText = deleResp.text.lowercased()
        if deleResp.code == 550 &&
            (normalizedDeleText.contains("permission") || normalizedDeleText.contains("denied")) {
            throw RemoteFileSystemError.operationFailed("Delete failed: \(deleResp.text)")
        }

        let rmdResp = try await conn.sendCommand("RMD \(remotePath)")
        guard rmdResp.code == 250 else {
            throw RemoteFileSystemError.operationFailed("Delete failed: \(rmdResp.text)")
        }
    }

    public func move(from source: RemotePath, to destination: RemotePath) async throws {
        try await serialized {
            let conn = try requireConnection()
            let rnfrResp = try await conn.sendCommand("RNFR \(resolvedPath(source))")
            guard rnfrResp.code == 350 else {
                throw RemoteFileSystemError.operationFailed("RNFR failed: \(rnfrResp.text)")
            }
            let rntoResp = try await conn.sendCommand("RNTO \(resolvedPath(destination))")
            guard rntoResp.code == 250 else {
                throw RemoteFileSystemError.operationFailed("RNTO failed: \(rntoResp.text)")
            }
        }
    }

    // MARK: - Transfers

    /// Runs `command` (`RETR`, `LIST`) and returns what the server sends on the data connection.
    private func download(_ command: String, path: RemotePath) async throws -> Data {
        let conn = try requireConnection()
        let transfer = try await beginTransfer(command, path: path, on: conn)
        let data: Data
        do {
            data = try await transfer.handler.collectData(timeout: FTPConnection.operationTimeout)
        } catch {
            await abort(transfer, on: conn)
            throw error
        }
        try await conn.finishTransfer()
        return data
    }

    /// `STOR`s whatever `write` sends on the data connection.
    private func upload(to path: RemotePath, write: (Channel) async throws -> Void) async throws {
        let conn = try requireConnection()
        let transfer = try await beginTransfer("STOR \(resolvedPath(path))", path: path, on: conn)
        do {
            try await write(transfer.channel)
            try await transfer.channel.close()
        } catch {
            await abort(transfer, on: conn)
            throw error
        }
        try await conn.finishTransfer()
    }

    /// Cleans up after a failed transfer. A control connection that could not be brought
    /// back in step is dropped, so the next operation fails as not connected and the caller
    /// reconnects instead of reading a stale reply as its own.
    private func abort(_ transfer: FTPDataConnection, on conn: FTPConnection) async {
        do {
            try await conn.abortTransfer(transfer)
        } catch {
            await drop(conn)
        }
    }

    private func drop(_ conn: FTPConnection) async {
        if connection === conn {
            connection = nil
        }
        try? await conn.close()
    }

    private func beginTransfer(
        _ command: String,
        path: RemotePath,
        on conn: FTPConnection
    ) async throws -> FTPDataConnection {
        do {
            return try await conn.beginTransfer(command)
        } catch FTPError.controlConnectionLost(let message) {
            await drop(conn)
            throw FTPError.controlConnectionLost(message)
        } catch FTPError.unexpectedResponse(let response) {
            let verb = command.prefix { $0 != " " }
            // For `STOR` a 550 means the server will not take the file, not that it is missing.
            if response.code == 550 && verb != "STOR" {
                throw RemoteFileSystemError.notFound(path)
            }
            throw RemoteFileSystemError.operationFailed("\(verb) failed: \(response.text)")
        }
    }

    // MARK: - Helpers

    /// Runs one operation at a time. The control connection carries one command sequence
    /// at a time, and actor reentrancy would otherwise let a second call send its commands
    /// while the first awaits its replies, so each would read the other's.
    private func serialized<T>(_ operation: () async throws -> T) async throws -> T {
        while isBusy {
            await withCheckedContinuation { waiters.append($0) }
        }
        isBusy = true
        defer {
            isBusy = false
            if !waiters.isEmpty {
                waiters.removeFirst().resume()
            }
        }
        do {
            return try await operation()
        } catch let error as FTPError {
            throw mapConnectionError(error)
        }
    }

    private func requireConnection() throws -> FTPConnection {
        guard let connection = connection else {
            throw RemoteFileSystemError.notConnected
        }
        return connection
    }

    private func mapConnectionError(_ error: Error) -> RemoteFileSystemError {
        if let error = error as? RemoteFileSystemError {
            return error
        }

        if let error = error as? FTPError {
            switch error {
            case .authenticationFailed:
                return .authenticationFailed
            case .notConnected:
                return .notConnected
            case .connectionTimedOut:
                return .connectionFailed(error.localizedDescription)
            case .connectionFailed(let message), .controlConnectionLost(let message):
                return .connectionFailed(message)
            case .unexpectedResponse, .protocolError, .transferFailed:
                return .operationFailed(error.localizedDescription)
            }
        }

        return .operationFailed(error.localizedDescription)
    }

    private func resolvedPath(_ path: RemotePath) -> String {
        if path.isRoot { return config.remotePath }
        let base = if config.remotePath == "/" {
            "/"
        } else if config.remotePath.hasSuffix("/") {
            config.remotePath
        } else {
            config.remotePath + "/"
        }
        return base + path.components.joined(separator: "/")
    }

    private static func entries(in listing: Data) -> [FTPDirectoryParser.Entry] {
        FTPDirectoryParser.parse(String(bytes: listing, encoding: .utf8) ?? "")
    }

    private func isUnsupportedMLSTResponse(_ response: FTPResponse) -> Bool {
        [500, 501, 502, 504].contains(response.code)
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
        return Self.mdtmFormatter.date(from: timeStr)
    }

}
