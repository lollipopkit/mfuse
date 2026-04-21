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
    public var autoMountOnLaunch: Bool

    /// Used as the File Provider domain identifier.
    public var domainIdentifier: String { id.uuidString }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case backendType
        case host
        case port
        case username
        case authMethod
        case remotePath
        case parameters
        case autoMountOnLaunch
    }

    public init(
        id: UUID = UUID(),
        name: String,
        backendType: BackendType,
        host: String,
        port: UInt16? = nil,
        username: String = "",
        authMethod: AuthMethod = .password,
        remotePath: String = "/",
        parameters: [String: String] = [:],
        autoMountOnLaunch: Bool = false
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
        self.autoMountOnLaunch = autoMountOnLaunch
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        backendType = try container.decode(BackendType.self, forKey: .backendType)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(UInt16.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        authMethod = try container.decode(AuthMethod.self, forKey: .authMethod)
        remotePath = try container.decode(String.self, forKey: .remotePath)
        parameters = try container.decode([String: String].self, forKey: .parameters)
        autoMountOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .autoMountOnLaunch) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(backendType, forKey: .backendType)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(authMethod, forKey: .authMethod)
        try container.encode(remotePath, forKey: .remotePath)
        try container.encode(parameters, forKey: .parameters)
        try container.encode(autoMountOnLaunch, forKey: .autoMountOnLaunch)
    }
}
