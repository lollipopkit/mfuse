import Foundation

/// Authentication method for a remote connection.
public enum AuthMethod: String, Codable, Sendable, CaseIterable {
    case password
    case publicKey
    case agent
    case accessKey   // S3: access key ID + secret
    case anonymous   // FTP / WebDAV public access
    case oauth       // Google Drive OAuth2
}

/// Persistent configuration for a single remote filesystem connection.
/// Credentials are NOT stored here — they go in the Keychain.
public struct ConnectionConfig: Codable, Identifiable, Sendable, Equatable, Hashable {

    public let id: UUID
    public var name: String
    public var backendType: BackendType
    public var host: String
    public var port: UInt16
    public var username: String
    public var authMethod: AuthMethod
    public var remotePath: String           // starting directory on the remote
    public var parameters: [String: String] // backend-specific extra params

    /// Used as the File Provider domain identifier.
    public var domainIdentifier: String { id.uuidString }

    public init(
        id: UUID = UUID(),
        name: String,
        backendType: BackendType,
        host: String,
        port: UInt16? = nil,
        username: String = "",
        authMethod: AuthMethod = .password,
        remotePath: String = "/",
        parameters: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.backendType = backendType
        self.host = host
        self.port = port ?? backendType.defaultPort
        self.username = username
        self.authMethod = authMethod
        self.remotePath = remotePath
        self.parameters = parameters
    }
}
