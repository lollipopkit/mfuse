import Foundation
import MFuseCore
import Citadel
import CCryptoBoringSSL
import CCitadelBcrypt
import NIO
import NIOSSH
import Crypto
import os.log

/// SFTP implementation of `RemoteFileSystem` using Citadel.
public actor SFTPFileSystem: RemoteFileSystem {

    private static let enumerationTimeoutSeconds = 3.0
    private static let execResponseLimit = 4 * 1024 * 1024
    private static let copyChunkSize: UInt32 = 64 * 1024
    private static let logger = Logger(
        subsystem: "com.lollipopkit.mfuse.sftp",
        category: "SFTPFileSystem"
    )

    private let config: ConnectionConfig
    private let credential: Credential
    private let hostKeyStore: HostKeyStore
    private var client: SSHClient?
    private var sftp: SFTPClient?

    public var isConnected: Bool { sftp != nil }

    public init(config: ConnectionConfig, credential: Credential) {
        self.config = config
        self.credential = credential
        self.hostKeyStore = HostKeyStore()
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        let authMethod: SSHAuthenticationMethod
        switch config.authMethod {
        case .password:
            guard let password = credential.password else {
                throw RemoteFileSystemError.authenticationFailed
            }
            authMethod = .passwordBased(username: config.username, password: password)

        case .publicKey:
            guard let keyData = credential.privateKey, !keyData.isEmpty else {
                throw RemoteFileSystemError.authenticationFailed
            }
            authMethod = try Self.publicKeyAuthenticationMethod(
                username: config.username,
                keyData: keyData,
                passphrase: credential.passphrase
            )

        case .agent:
            throw RemoteFileSystemError.unsupported("SSH agent authentication is not supported for SFTP")

        case .accessKey, .anonymous, .oauth:
            throw RemoteFileSystemError.authenticationFailed
        }

        do {
            // Build TOFU (Trust-On-First-Use) host key validator
            let tofuValidator = TOFUHostKeyValidator(
                host: config.host,
                port: Int(config.port),
                store: hostKeyStore
            )

            let sshClient = try await SSHClient.connect(
                host: config.host,
                port: Int(config.port),
                authenticationMethod: authMethod,
                hostKeyValidator: .custom(tofuValidator),
                reconnect: .never
            )
            self.client = sshClient
            self.sftp = try await sshClient.openSFTP()
        } catch {
            if let sshClient = self.client {
                try? await sshClient.close()
            }
            self.client = nil
            self.sftp = nil
            throw mapConnectionError(error)
        }
    }

    public func disconnect() async throws {
        sftp = nil
        try await client?.close()
        client = nil
    }

    // MARK: - Enumeration

    public func enumerate(at path: RemotePath) async throws -> [RemoteItem] {
        do {
            let remotePath = resolvedPath(path)

            do {
                return try await withTimeout(seconds: Self.enumerationTimeoutSeconds) {
                    try await self.enumerateViaSFTP(at: path, remotePath: remotePath)
                }
            } catch {
                guard shouldFallbackEnumeration(after: error) else {
                    throw error
                }

                Self.logger.info(
                    "Falling back to exec-based enumeration for \(remotePath, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                return try await enumerateViaExec(at: path, remotePath: remotePath)
            }
        } catch {
            throw mapOperationError(error, path: path)
        }
    }

    public func itemInfo(at path: RemotePath) async throws -> RemoteItem {
        do {
            let sftp = try requireSFTP()
            let remotePath = resolvedPath(path)
            let attrs = try await sftp.getAttributes(at: remotePath)
            return remoteItem(from: attrs, path: path)
        } catch {
            throw mapOperationError(error, path: path)
        }
    }

    // MARK: - Read

    public func readFile(at path: RemotePath) async throws -> Data {
        do {
            let sftp = try requireSFTP()
            let remotePath = resolvedPath(path)
            let buffer: ByteBuffer = try await sftp.withFile(filePath: remotePath, flags: .read) { file in
                try await file.readAll()
            }
            return Data(buffer: buffer)
        } catch {
            throw mapOperationError(error, path: path)
        }
    }

    public func readFile(at path: RemotePath, offset: UInt64, length: UInt32) async throws -> Data {
        do {
            let sftp = try requireSFTP()
            let remotePath = resolvedPath(path)
            let buffer: ByteBuffer = try await sftp.withFile(filePath: remotePath, flags: .read) { file in
                try await file.read(from: offset, length: length)
            }
            return Data(buffer: buffer)
        } catch {
            throw mapOperationError(error, path: path)
        }
    }

    // MARK: - Write

    public func writeFile(at path: RemotePath, data: Data) async throws {
        do {
            let sftp = try requireSFTP()
            let remotePath = resolvedPath(path)
            try await sftp.withFile(filePath: remotePath, flags: [.write, .create, .truncate]) { file in
                try await file.write(ByteBuffer(data: data), at: 0)
            }
        } catch {
            throw mapOperationError(error, path: path)
        }
    }

    public func createFile(at path: RemotePath, data: Data) async throws {
        do {
            let sftp = try requireSFTP()
            let remotePath = resolvedPath(path)
            // forceCreate fails if file already exists
            try await sftp.withFile(filePath: remotePath, flags: [.write, .forceCreate]) { file in
                try await file.write(ByteBuffer(data: data), at: 0)
            }
        } catch {
            throw mapOperationError(error, path: path)
        }
    }

    // MARK: - Mutations

    public func createDirectory(at path: RemotePath) async throws {
        do {
            let sftp = try requireSFTP()
            let remotePath = resolvedPath(path)
            try await sftp.createDirectory(atPath: remotePath)
        } catch {
            throw mapOperationError(error, path: path)
        }
    }

    public func delete(at path: RemotePath) async throws {
        do {
            try await deleteRecursively(at: path)
        } catch {
            throw mapOperationError(error, path: path)
        }
    }

    public func move(from source: RemotePath, to destination: RemotePath) async throws {
        do {
            let sftp = try requireSFTP()
            try await sftp.rename(at: resolvedPath(source), to: resolvedPath(destination))
        } catch {
            throw mapOperationError(error, path: source)
        }
    }

    public func copy(from source: RemotePath, to destination: RemotePath) async throws {
        do {
            let sftp = try requireSFTP()
            let sourcePath = resolvedPath(source)
            let destinationPath = resolvedPath(destination)
            let sourceInfo = try await itemInfo(at: source)

            if sourceInfo.isDirectory {
                try await sftp.createDirectory(atPath: destinationPath)
                let children = try await enumerate(at: source)
                for child in children {
                    try await copy(from: child.path, to: destination.appending(child.path.name))
                }
                return
            }

            try await sftp.withFile(filePath: sourcePath, flags: .read) { sourceFile in
                try await sftp.withFile(filePath: destinationPath, flags: [.write, .create, .truncate]) { destinationFile in
                    var readOffset: UInt64 = 0
                    var writeOffset: UInt64 = 0

                    while true {
                        let chunk = try await sourceFile.read(from: readOffset, length: Self.copyChunkSize)
                        let chunkSize = chunk.readableBytes
                        guard chunkSize > 0 else {
                            break
                        }

                        try await destinationFile.write(chunk, at: writeOffset)
                        readOffset += UInt64(chunkSize)
                        writeOffset += UInt64(chunkSize)
                    }
                }
            }
        } catch {
            throw mapOperationError(error, path: source)
        }
    }

    private func deleteRecursively(at path: RemotePath) async throws {
        let sftp = try requireSFTP()
        let remotePath = resolvedPath(path)
        let info = try await itemInfo(at: path)
        if info.isDirectory {
            let children = try await enumerate(at: path)
            for child in children {
                try await deleteRecursively(at: child.path)
            }
            try await sftp.rmdir(at: remotePath)
        } else {
            try await sftp.remove(at: remotePath)
        }
    }

    public func setPermissions(_ permissions: UInt16, at path: RemotePath) async throws {
        do {
            let sftp = try requireSFTP()
            var attributes = SFTPFileAttributes()
            attributes.permissions = UInt32(permissions)
            try await sftp.setAttributes(
                at: resolvedPath(path),
                to: attributes
            )
        } catch {
            throw mapOperationError(error, path: path)
        }
    }

    // MARK: - Helpers

    private func requireSFTP() throws -> SFTPClient {
        guard let sftp = sftp else {
            throw RemoteFileSystemError.notConnected
        }
        return sftp
    }

    private func requireClient() throws -> SSHClient {
        guard let client = client else {
            throw RemoteFileSystemError.notConnected
        }
        return client
    }

    private func enumerateViaSFTP(at path: RemotePath, remotePath: String) async throws -> [RemoteItem] {
        let sftp = try requireSFTP()
        let names = try await sftp.listDirectory(atPath: remotePath)
        var items: [RemoteItem] = []
        for name in names {
            for component in name.components {
                let filename = component.filename
                guard filename != "." && filename != ".." else { continue }
                items.append(remoteItem(from: component, parentPath: path))
            }
        }
        return items
    }

    private func enumerateViaExec(at path: RemotePath, remotePath: String) async throws -> [RemoteItem] {
        let client = try requireClient()
        let command = Self.makeExecEnumerationCommand(for: remotePath)
        let output = try await client.executeCommand(
            command,
            maxResponseSize: Self.execResponseLimit,
            mergeStreams: false,
            inShell: true
        )

        guard let data = String(buffer: output).data(using: .utf8) else {
            throw RemoteFileSystemError.operationFailed("Failed to decode exec-based directory listing.")
        }

        do {
            return try Self.decodeExecEnumerationItems(from: data, parentPath: path)
        } catch let error as ExecEnumerationError {
            switch error.code {
            case "python_not_available":
                Self.logger.error(
                    "Exec enumeration fallback requires python3 on the remote host for path \(remotePath, privacy: .public)"
                )
                throw RemoteFileSystemError.operationFailed(
                    "Directory fallback enumeration requires python3 on the remote host."
                )
            default:
                Self.logger.error(
                    "Exec enumeration fallback failed for \(remotePath, privacy: .public): \(error.message, privacy: .public)"
                )
                throw RemoteFileSystemError.operationFailed(
                    "Exec-based directory enumeration failed: \(error.message)"
                )
            }
        }
    }

    private func shouldFallbackEnumeration(after error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if let remoteError = error as? RemoteFileSystemError {
            if case .notConnected = remoteError {
                return true
            }
        }

        if let sftpError = error as? SFTPError {
            switch sftpError {
            case .connectionClosed, .missingResponse, .noResponseTarget:
                return true
            case .errorStatus, .unknownMessage, .invalidPayload, .invalidResponse,
                 .fileHandleInvalid, .unsupportedVersion:
                return false
            }
        }

        let description = String(reflecting: error).lowercased()
        return description.contains("timed out")
            || description.contains("cancel")
            || description.contains("connection closed")
            || description.contains("missing response")
    }

    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw RemoteFileSystemError.operationFailed("Timed out while enumerating directory")
            }

            guard let result = try await group.next() else {
                group.cancelAll()
                throw RemoteFileSystemError.operationFailed(
                    "Operation cancelled or produced no result while enumerating directory"
                )
            }
            group.cancelAll()
            return result
        }
    }

    private func mapConnectionError(_ error: Error) -> RemoteFileSystemError {
        switch error {
        case is AuthenticationFailed:
            return .authenticationFailed
        case let error as SSHClientError:
            switch error {
            case .allAuthenticationOptionsFailed,
                 .unsupportedPasswordAuthentication,
                 .unsupportedPrivateKeyAuthentication,
                 .unsupportedHostBasedAuthentication:
                return .authenticationFailed
            case .channelCreationFailed:
                return .connectionFailed("SSH channel creation failed")
            }
        case let error as SFTPError:
            return .connectionFailed(describeSFTPError(error, path: nil))
        case let error as SFTPMessage.Status:
            return .connectionFailed(describeStatus(error, path: nil))
        default:
            return .connectionFailed(describe(error))
        }
    }

    private func mapOperationError(_ error: Error, path: RemotePath) -> RemoteFileSystemError {
        if let remoteError = error as? RemoteFileSystemError {
            return remoteError
        }

        if let status = error as? SFTPMessage.Status {
            return mapStatus(status, path: path)
        }

        if let sftpError = error as? SFTPError {
            switch sftpError {
            case .errorStatus(let status):
                return mapStatus(status, path: path)
            default:
                return .operationFailed(describeSFTPError(sftpError, path: path))
            }
        }

        return .operationFailed(describe(error))
    }

    private func mapStatus(_ status: SFTPMessage.Status, path: RemotePath?) -> RemoteFileSystemError {
        switch status.errorCode {
        case .noSuchFile:
            if let path {
                return .notFound(path)
            }
            return .operationFailed(describeStatus(status, path: nil))
        case .permissionDenied:
            if let path {
                return .permissionDenied(path)
            }
            return .operationFailed(describeStatus(status, path: nil))
        default:
            return .operationFailed(describeStatus(status, path: path))
        }
    }

    private func describeSFTPError(_ error: SFTPError, path: RemotePath?) -> String {
        switch error {
        case .unknownMessage:
            return "SFTP protocol error: unknown message"
        case .invalidPayload(let type):
            return "SFTP protocol error: invalid payload for \(type.description)"
        case .invalidResponse:
            return "SFTP server returned an invalid response"
        case .noResponseTarget:
            return "SFTP protocol error: response target missing"
        case .connectionClosed:
            return "SFTP connection closed unexpectedly"
        case .missingResponse:
            return "SFTP server did not return a response"
        case .fileHandleInvalid:
            return "SFTP server reported an invalid file handle"
        case .errorStatus(let status):
            return describeStatus(status, path: path)
        case .unsupportedVersion(let version):
            return "Unsupported SFTP protocol version: \(version.rawValue)"
        }
    }

    private func describeStatus(_ status: SFTPMessage.Status, path: RemotePath?) -> String {
        let message = status.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = path.map { " at \($0.absoluteString)" } ?? ""
        let base: String

        switch status.errorCode {
        case .ok:
            base = "SFTP ok"
        case .eof:
            base = "SFTP EOF"
        case .noSuchFile:
            base = "SFTP path not found"
        case .permissionDenied:
            base = "SFTP permission denied"
        case .failure:
            base = "SFTP failure"
        case .badMessage:
            base = "SFTP bad message"
        case .noConnection:
            base = "SFTP server has no connection"
        case .connectionLost:
            base = "SFTP connection lost"
        case .unsupportedOperation:
            base = "SFTP operation unsupported"
        case .unknown(let code):
            base = "SFTP status \(code)"
        }

        if message.isEmpty {
            return "\(base)\(suffix)"
        }
        return "\(base)\(suffix): \(message)"
    }

    static func publicKeyAuthenticationMethod(
        username: String,
        keyData: Data,
        passphrase: String?
    ) throws -> SSHAuthenticationMethod {
        guard let keyString = String(data: keyData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !keyString.isEmpty else {
            throw RemoteFileSystemError.unsupported("The private key file could not be read as text.")
        }

        if keyString.hasPrefix("ssh-") {
            throw RemoteFileSystemError.unsupported("Please select a private key file, not a public key (.pub).")
        }

        let decryptionKey = passphrase?.data(using: .utf8)

        do {
            switch try SSHKeyDetection.detectPrivateKeyType(from: keyString) {
            case .rsa:
                let key = try Insecure.RSA.PrivateKey(sshRsa: keyString, decryptionKey: decryptionKey)
                return .rsa(username: username, privateKey: key)
            case .ed25519:
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: keyString, decryptionKey: decryptionKey)
                return .ed25519(username: username, privateKey: key)
            case .ecdsaP256:
                let key = try OpenSSHECDSAPrivateKeyParser.p256Key(from: keyString, decryptionKey: decryptionKey)
                return .p256(username: username, privateKey: key)
            case .ecdsaP384:
                let key = try OpenSSHECDSAPrivateKeyParser.p384Key(from: keyString, decryptionKey: decryptionKey)
                return .p384(username: username, privateKey: key)
            case .ecdsaP521:
                let key = try OpenSSHECDSAPrivateKeyParser.p521Key(from: keyString, decryptionKey: decryptionKey)
                return .p521(username: username, privateKey: key)
            default:
                throw RemoteFileSystemError.unsupported("This SSH key type is not supported.")
            }
        } catch let error as RemoteFileSystemError {
            throw error
        } catch let error as SSHKeyDetectionError {
            throw Self.mapKeyDetectionError(error)
        } catch {
            throw RemoteFileSystemError.unsupported("Unsupported or invalid SSH private key: \(Self.describe(error))")
        }
    }

    private func describe(_ error: Error) -> String {
        Self.describe(error)
    }

    private static func describe(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty,
           !description.hasPrefix("The operation couldn’t be completed.") {
            return description
        }

        let reflected = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        if !reflected.isEmpty, reflected != String(reflecting: error) || !reflected.hasPrefix("(") {
            return reflected
        }

        let localized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return localized.isEmpty ? String(reflecting: error) : localized
    }

    private static func mapKeyDetectionError(_ error: SSHKeyDetectionError) -> RemoteFileSystemError {
        switch error {
        case .invalidPrivateKeyFormat:
            return .unsupported("Unsupported private key format. Use an OpenSSH private key.")
        case .passphraseRequired, .encryptedPrivateKey:
            return .unsupported("This private key is encrypted. Enter the passphrase and try again.")
        case .incorrectPassphrase:
            return .unsupported("The private key passphrase is incorrect.")
        case .unsupportedKeyType:
            return .unsupported("This SSH key type is not supported.")
        case .invalidKeyFormat, .malformedKey:
            return .unsupported("The SSH private key is malformed.")
        }
    }

    private func resolvedPath(_ path: RemotePath) -> String {
        if path.isRoot {
            return config.remotePath
        }
        let base = config.remotePath.hasSuffix("/") ? config.remotePath : config.remotePath + "/"
        let relative = path.components.joined(separator: "/")
        return base + relative
    }

    private func isDirectory(_ attrs: SFTPFileAttributes) -> Bool {
        guard let perms = attrs.permissions else { return false }
        return (perms & 0o170000) == 0o040000
    }

    private func remoteItem(from component: SFTPPathComponent, parentPath: RemotePath) -> RemoteItem {
        let childPath = parentPath.appending(component.filename)
        let attrs = component.attributes
        let type: RemoteItemType = isDirectory(attrs) ? .directory : .file
        return RemoteItem(
            path: childPath,
            type: type,
            size: attrs.size ?? 0,
            modificationDate: attrs.accessModificationTime?.modificationTime ?? Date(),
            creationDate: nil,
            permissions: attrs.permissions.map { UInt16($0 & 0o7777) }
        )
    }

    private func remoteItem(from attrs: SFTPFileAttributes, path: RemotePath) -> RemoteItem {
        let type: RemoteItemType = isDirectory(attrs) ? .directory : .file
        return RemoteItem(
            path: path,
            type: type,
            size: attrs.size ?? 0,
            modificationDate: attrs.accessModificationTime?.modificationTime ?? Date(),
            creationDate: nil,
            permissions: attrs.permissions.map { UInt16($0 & 0o7777) }
        )
    }

    /// Compute a SHA-256 fingerprint of an SSH public key for TOFU storage.
    private static func fingerprint(of key: NIOSSHPublicKey) -> String {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        key.write(to: &buffer)
        let keyBlob = Data(buffer.readableBytesView)
        let digest = Data(SHA256.hash(data: keyBlob))
        let base64 = digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(base64)"
    }

    static func makeExecEnumerationCommand(for remotePath: String) -> String {
        let script = """
        import base64
        import json
        import os
        import stat
        import sys

        try:
            path = base64.b64decode(sys.argv[1]).decode("utf-8")
            items = []

            with os.scandir(path) as iterator:
                for entry in iterator:
                    if entry.name in {".", ".."}:
                        continue

                    info = entry.stat(follow_symlinks=False)
                    mode = info.st_mode
                    if stat.S_ISDIR(mode):
                        item_type = "directory"
                        target = None
                    elif stat.S_ISLNK(mode):
                        item_type = "symlink"
                        try:
                            target = os.readlink(entry.path)
                        except OSError:
                            target = None
                    else:
                        item_type = "file"
                        target = None

                    items.append({
                        "name": entry.name,
                        "type": item_type,
                        "size": info.st_size,
                        "mtime": info.st_mtime,
                        "mode": stat.S_IMODE(mode),
                        "target": target,
                    })

            print(json.dumps(items, separators=(",", ":")))
        except Exception as exc:
            print(json.dumps({"error":"exec_enumeration_failed","message":str(exc)}, separators=(",", ":")))
            sys.exit(1)
        """

        let scriptBase64 = Data(script.utf8).base64EncodedString()
        let pathBase64 = Data(remotePath.utf8).base64EncodedString()
        return #"if command -v python3 >/dev/null 2>&1; then python3 -c "import base64; exec(base64.b64decode('\#(scriptBase64)'))" "\#(pathBase64)"; else printf '%s\n' '{"error":"python_not_available","message":"python3 is required on the remote host for exec-based enumeration"}'; exit 1; fi"#
    }

    static func decodeExecEnumerationItems(from data: Data, parentPath: RemotePath) throws -> [RemoteItem] {
        let decoder = JSONDecoder()
        if let execError = try? decoder.decode(ExecEnumerationError.self, from: data) {
            throw execError
        }
        let entries = try decoder.decode([ExecEnumerationEntry].self, from: data)
        return entries.map { entry in
            let childPath = parentPath.appending(entry.name)
            let type: RemoteItemType

            switch entry.type {
            case "directory":
                type = .directory
            case "symlink":
                type = .symlink(target: entry.target ?? "")
            default:
                type = .file
            }

            return RemoteItem(
                path: childPath,
                type: type,
                size: max(0, UInt64(entry.size)),
                modificationDate: Date(timeIntervalSince1970: entry.mtime),
                creationDate: nil,
                permissions: UInt16(entry.mode)
            )
        }
    }
}

private struct ExecEnumerationEntry: Decodable {
    let name: String
    let type: String
    let size: Int64
    let mtime: TimeInterval
    let mode: UInt32
    let target: String?
}

private struct ExecEnumerationError: Error, Decodable {
    let error: String
    let message: String

    var code: String { error }
}

private enum OpenSSHECDSAPrivateKeyParser {
    static func p256Key(from key: String, decryptionKey: Data?) throws -> P256.Signing.PrivateKey {
        let scalar = try privateScalar(from: key, expectedKeyType: "ecdsa-sha2-nistp256", decryptionKey: decryptionKey)
        return try P256.Signing.PrivateKey(rawRepresentation: scalar)
    }

    static func p384Key(from key: String, decryptionKey: Data?) throws -> P384.Signing.PrivateKey {
        let scalar = try privateScalar(from: key, expectedKeyType: "ecdsa-sha2-nistp384", decryptionKey: decryptionKey)
        return try P384.Signing.PrivateKey(rawRepresentation: scalar)
    }

    static func p521Key(from key: String, decryptionKey: Data?) throws -> P521.Signing.PrivateKey {
        let scalar = try privateScalar(from: key, expectedKeyType: "ecdsa-sha2-nistp521", decryptionKey: decryptionKey)
        return try P521.Signing.PrivateKey(rawRepresentation: scalar)
    }

    private static func privateScalar(from key: String, expectedKeyType: String, decryptionKey: Data?) throws -> Data {
        let reader = try OpenSSHPrivateKeyReader(key)
        let privateBlock = try reader.privateKeyBlock(decryptionKey: decryptionKey)
        var privateReader = SSHBinaryReader(data: privateBlock)

        let check0 = try privateReader.readUInt32()
        let check1 = try privateReader.readUInt32()
        guard check0 == check1 else {
            if reader.cipherName == "none" {
                throw RemoteFileSystemError.unsupported("The OpenSSH private key checksum is invalid.")
            }
            throw SSHKeyDetectionError.incorrectPassphrase
        }

        let keyType = try privateReader.readString()
        guard keyType == expectedKeyType else {
            throw RemoteFileSystemError.unsupported("The OpenSSH private key type does not match the expected algorithm.")
        }

        _ = try privateReader.readString() // curve name
        _ = try privateReader.readData()   // public key blob

        let scalar = try privateReader.readMPInt()
        return normalizeScalar(scalar, expectedLength: expectedScalarLength(for: expectedKeyType))
    }

    private static func expectedScalarLength(for keyType: String) -> Int {
        switch keyType {
        case "ecdsa-sha2-nistp256": return 32
        case "ecdsa-sha2-nistp384": return 48
        case "ecdsa-sha2-nistp521": return 66
        default: return 0
        }
    }

    private static func normalizeScalar(_ scalar: Data, expectedLength: Int) -> Data {
        let trimmed = scalar.drop { $0 == 0 }
        if trimmed.count >= expectedLength {
            return Data(trimmed.suffix(expectedLength))
        }

        var normalized = Data(repeating: 0, count: expectedLength - trimmed.count)
        normalized.append(trimmed)
        return normalized
    }
}

private struct OpenSSHPrivateKeyReader {
    let cipherName: String
    private let kdfName: String
    private let kdfOptions: Data
    private let encryptedPrivateKeyBlock: Data

    init(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            trimmed.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"),
            trimmed.hasSuffix("-----END OPENSSH PRIVATE KEY-----")
        else {
            throw RemoteFileSystemError.unsupported("Unsupported private key format. Use an OpenSSH private key.")
        }

        let base64 = trimmed
            .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = Data(base64Encoded: base64) else {
            throw RemoteFileSystemError.unsupported("The OpenSSH private key payload is not valid base64.")
        }

        var reader = SSHBinaryReader(data: data)
        let magic = try reader.readBytes(count: "openssh-key-v1\u{0}".utf8.count)
        guard Data(magic) == Data("openssh-key-v1\u{0}".utf8) else {
            throw RemoteFileSystemError.unsupported("The OpenSSH private key header is invalid.")
        }

        self.cipherName = try reader.readString()
        self.kdfName = try reader.readString()
        self.kdfOptions = try reader.readData()

        let keyCount = try reader.readUInt32()
        guard keyCount == 1 else {
            throw RemoteFileSystemError.unsupported("OpenSSH private keys containing multiple identities are not supported.")
        }

        _ = try reader.readData() // public key blob
        self.encryptedPrivateKeyBlock = try reader.readData()
    }

    func privateKeyBlock(decryptionKey: Data?) throws -> Data {
        switch cipherName {
        case "none":
            return encryptedPrivateKeyBlock
        case "aes128-ctr", "aes256-ctr":
            guard let decryptionKey else {
                throw SSHKeyDetectionError.passphraseRequired
            }
            let derived = try deriveKeyAndIV(
                cipherName: cipherName,
                decryptionKey: decryptionKey
            )
            do {
                return try decryptAESCTR(
                    encryptedPrivateKeyBlock,
                    cipherName: cipherName,
                    key: derived.key,
                    iv: derived.iv
                )
            } catch {
                throw SSHKeyDetectionError.incorrectPassphrase
            }
        default:
            throw RemoteFileSystemError.unsupported("Unsupported OpenSSH cipher: \(cipherName)")
        }
    }

    private func deriveKeyAndIV(cipherName: String, decryptionKey: Data) throws -> (key: [UInt8], iv: [UInt8]) {
        guard kdfName == "bcrypt" else {
            throw RemoteFileSystemError.unsupported("Unsupported OpenSSH KDF: \(kdfName)")
        }

        var options = SSHBinaryReader(data: kdfOptions)
        let salt = try options.readData()
        let rounds = try options.readUInt32()
        let keyLength: Int
        let ivLength = 16

        switch cipherName {
        case "aes128-ctr":
            keyLength = 16
        case "aes256-ctr":
            keyLength = 32
        default:
            throw RemoteFileSystemError.unsupported("Unsupported OpenSSH cipher: \(cipherName)")
        }

        guard BCryptSHA512Initializer.didInit else {
            throw RemoteFileSystemError.unsupported("Failed to initialize bcrypt support.")
        }

        var derived = [UInt8](repeating: 0, count: keyLength + ivLength)
        let status = decryptionKey.withUnsafeBytes { passBytes in
            salt.withUnsafeBytes { saltBytes in
                citadel_bcrypt_pbkdf(
                    passBytes.baseAddress!,
                    passBytes.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress!,
                    salt.count,
                    &derived,
                    derived.count,
                    rounds
                )
            }
        }
        guard status == 0 else {
            throw RemoteFileSystemError.unsupported("Failed to derive OpenSSH key material.")
        }

        return (Array(derived[..<keyLength]), Array(derived[keyLength...]))
    }

    private func decryptAESCTR(_ data: Data, cipherName: String, key: [UInt8], iv: [UInt8]) throws -> Data {
        guard data.count.isMultiple(of: 16) else {
            throw RemoteFileSystemError.unsupported("The encrypted OpenSSH private key payload is malformed.")
        }

        let cipher: OpaquePointer
        switch cipherName {
        case "aes128-ctr":
            cipher = CCryptoBoringSSL_EVP_aes_128_ctr()
        case "aes256-ctr":
            cipher = CCryptoBoringSSL_EVP_aes_256_ctr()
        default:
            throw RemoteFileSystemError.unsupported("Unsupported OpenSSH cipher: \(cipherName)")
        }

        let context = CCryptoBoringSSL_EVP_CIPHER_CTX_new()
        defer { CCryptoBoringSSL_EVP_CIPHER_CTX_free(context) }

        guard CCryptoBoringSSL_EVP_CipherInit(context, cipher, key, iv, 0) == 1 else {
            throw RemoteFileSystemError.unsupported("Failed to initialize OpenSSH decryption.")
        }

        var output = data
        try output.withUnsafeMutableBytes { outputBytes in
            let outBase = outputBytes.bindMemory(to: UInt8.self).baseAddress!
            try data.withUnsafeBytes { inputBytes in
                let inBase = inputBytes.bindMemory(to: UInt8.self).baseAddress!
                try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 16) { block in
                    for offset in stride(from: 0, to: data.count, by: 16) {
                        guard CCryptoBoringSSL_EVP_Cipher(context, block.baseAddress!, inBase + offset, 16) == 1 else {
                            throw RemoteFileSystemError.unsupported("Failed to decrypt OpenSSH private key.")
                        }
                        (outBase + offset).update(from: block.baseAddress!, count: 16)
                    }
                }
            }
        }

        return output
    }
}

private enum BCryptSHA512Initializer {
    static let didInit: Bool = {
        citadel_set_crypto_hash_sha512 { output, input, inputLength in
            CCryptoBoringSSL_EVP_Digest(
                input,
                Int(inputLength),
                output,
                nil,
                CCryptoBoringSSL_EVP_sha512(),
                nil
            )
        }
        return true
    }()
}

private struct SSHBinaryReader {
    private let data: Data
    private var offset: Int = 0

    init(data: Data) {
        self.data = data
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(count: 4)
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func readString() throws -> String {
        let data = try readData()
        guard let string = String(data: data, encoding: .utf8) else {
            throw RemoteFileSystemError.unsupported("The SSH key contains invalid UTF-8 data.")
        }
        return string
    }

    mutating func readData() throws -> Data {
        let length = Int(try readUInt32())
        return Data(try readBytes(count: length))
    }

    mutating func readMPInt() throws -> Data {
        try readData()
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= data.count else {
            throw RemoteFileSystemError.unsupported("The SSH key is truncated or malformed.")
        }
        let slice = data[offset..<(offset + count)]
        offset += count
        return Array(slice)
    }
}

// MARK: - TOFU Host Key Validator

/// Trust-On-First-Use validator: stores the host key on first connection,
/// rejects connections if the key changes on subsequent connections.
private final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {

    private let host: String
    private let port: Int
    private let store: HostKeyStore

    init(host: String, port: Int, store: HostKeyStore) {
        self.host = host
        self.port = port
        self.store = store
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = Self.fingerprint(of: hostKey)
        if let known = store.knownFingerprint(for: host, port: port) {
            if fingerprint == known {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(
                    RemoteFileSystemError.operationFailed("Host key mismatch — possible MITM attack")
                )
            }
        } else {
            // First connection — trust and store
            store.store(fingerprint: fingerprint, for: host, port: port)
            validationCompletePromise.succeed(())
        }
    }

    private static func fingerprint(of key: NIOSSHPublicKey) -> String {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        key.write(to: &buffer)
        let keyBlob = Data(buffer.readableBytesView)
        let digest = Data(SHA256.hash(data: keyBlob))
        let base64 = digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(base64)"
    }
}
