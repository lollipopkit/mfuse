import Foundation

/// Authentication method for a remote connection.
public enum AuthMethod: String, Codable, Sendable, CaseIterable {
    case password
    case publicKey
    case agent
    case accessKey   // S3: access key ID + secret
    case anonymous   // FTP / WebDAV public access
    case oauth       // Google Drive OAuth2

    public var displayName: String {
        switch self {
        case .password:
            return MFuseCoreL10n.string("auth.password", fallback: "Password")
        case .publicKey:
            return MFuseCoreL10n.string("auth.publicKey", fallback: "Public Key")
        case .agent:
            return MFuseCoreL10n.string("auth.agent", fallback: "SSH Agent")
        case .accessKey:
            return MFuseCoreL10n.string("auth.accessKey", fallback: "Access Key")
        case .anonymous:
            return MFuseCoreL10n.string("auth.anonymous", fallback: "Anonymous")
        case .oauth:
            return MFuseCoreL10n.string("auth.oauth", fallback: "OAuth")
        }
    }
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

    /// Short address shown in lists and menus.
    ///
    /// Built as plain text so the port is never rendered as a localized number (SwiftUI
    /// would turn 9000 into "9,000"), and so backends without a host — S3 and the OAuth
    /// providers — show something meaningful instead of a bare ":443".
    public var displayAddress: String {
        switch backendType {
        case .s3:
            // Two buckets on one endpoint are two different mounts, so the endpoint on
            // its own does not identify the row — it would give both the same subtitle.
            switch (s3Endpoint, s3Bucket) {
            case let (endpoint?, bucket):
                return Self.endpointDisplayAddress(endpoint, bucket: bucket)
            case let (nil, bucket?):
                return bucket
            case (nil, nil):
                return backendType.displayName
            }
        case .googleDrive, .dropbox, .oneDrive:
            // Coalesce on emptiness, not just nil: a stored-but-blank email would
            // otherwise mask a perfectly good account name.
            if let account = Self.trimmedParameter(parameters["oauthAccountEmail"])
                ?? Self.trimmedParameter(parameters["oauthAccountName"]) {
                return account
            }
            return backendType.displayName
        case .sftp, .webdav, .smb, .nfs, .ftp:
            // Trimmed like the parameters above: a stored blank host is nothing to show,
            // and rendering it leaves the row displaying whitespace or a bare ":2222".
            guard let host = Self.trimmedParameter(host) else { return backendType.displayName }
            guard port != backendType.defaultPort else { return host }
            // An IPv6 literal is all colons, so "2001:db8::1:2222" cannot be read as
            // host plus port. Brackets are what separates the two.
            let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            return "\(address):\(String(port))"
        }
    }

    /// Backend type and address on one line, e.g. "SFTP · example.com".
    ///
    /// Identifies the connection in list rows now that the backend is named rather than
    /// drawn as an icon. When the address falls back to the type name — a backend with no
    /// host and nothing configured yet — the name is not repeated.
    public var displaySubtitle: String {
        let type = backendType.displayName
        return displayAddress == type ? type : "\(type) · \(displayAddress)"
    }

    /// The S3 endpoint this connection actually reaches, or nil when none is configured.
    ///
    /// Resolved through `s3Endpoint(_:applyingConfiguredPort:)` so what is displayed
    /// matches what the backend connects to.
    public var s3Endpoint: String? {
        guard let raw = Self.trimmedParameter(parameters["endpoint"]) else {
            return nil
        }
        return Self.s3Endpoint(
            raw,
            applyingConfiguredPort: port,
            backendDefaultPort: backendType.defaultPort
        )
    }

    /// The configured S3 bucket, or nil when unset or blank.
    public var s3Bucket: String? {
        Self.trimmedParameter(parameters["bucket"])
    }

    /// The endpoint with the bucket appended to its *path*, stripped of anything secret.
    ///
    /// Joining the raw strings puts the bucket after whatever the endpoint ends with, so
    /// `https://host/api?token=x` would be shown as `https://host/api?token=x/b` — a
    /// location that is not where the bucket lives. The credentials and query an endpoint
    /// can carry (`https://key:secret@host`, a pre-signed `?X-Amz-Signature=…`) are
    /// dropped rather than rendered into the sidebar, the detail view and the menu bar.
    /// Endpoints too malformed to parse show host and path only, for the same reason.
    static func endpointDisplayAddress(_ endpoint: String, bucket: String?) -> String {
        guard var components = URLComponents(string: endpoint),
              components.scheme != nil,
              components.host != nil else {
            return bucket ?? BackendType.s3.displayName
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        if let bucket {
            let path = components.path
            components.path = path.hasSuffix("/") ? "\(path)\(bucket)" : "\(path)/\(bucket)"
        }
        return components.string ?? bucket ?? BackendType.s3.displayName
    }

    /// Whether this and `other` address the same server with the same identity.
    ///
    /// Credentials are stored against a connection's id, not against what it points at, so
    /// this is the question to ask before reusing one: a changed backend, host, port,
    /// username, auth method or backend parameter means the secret would be sent somewhere
    /// it was never issued for.
    ///
    /// Every parameter counts, the OAuth account name and email included. They look like
    /// labels, but for Dropbox and OneDrive they are the only part of the account identity
    /// the config carries — the token is device-local — so a changed one means this
    /// device's token belongs to a different account than the row now names.
    public func addressesSameServer(as other: ConnectionConfig) -> Bool {
        guard backendType == other.backendType,
              host == other.host,
              username == other.username,
              authMethod == other.authMethod else {
            return false
        }

        // S3 addresses by endpoint, and the legacy shim folds a hidden port into it — so
        // `endpoint=http://host` + port 9000 and `endpoint=http://host:9000` + port 443 are
        // the same server written two ways. Comparing the raw pair reported a config that
        // had merely been through the editor's normalization as a different one, and left
        // a working mount down for nothing. The resolved endpoint is the address; the port
        // beside it is noise.
        // TODO: fold back into the plain comparison once the port shim itself is gone.
        if backendType == .s3 {
            var address = parameters
            var otherAddress = other.parameters
            address["endpoint"] = s3Endpoint
            otherAddress["endpoint"] = other.s3Endpoint
            return address == otherAddress
        }

        return port == other.port && parameters == other.parameters
    }

    /// A parameter with surrounding whitespace removed, or nil when it holds nothing.
    static func trimmedParameter(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Apply a connection's port to a custom S3 endpoint that doesn't carry one.
    ///
    /// TODO: remove once no configs predate the editor change. The editor used to show a
    /// Port field for S3 even though the backend only ever used the endpoint, so existing
    /// self-hosted setups are stored as endpoint `http://localhost` plus port `9000`.
    /// Without this the port is dropped and the client connects to the scheme default
    /// (80/443), failing with "connection refused". New configs carry the port in the
    /// endpoint, because the editor no longer offers a separate Port field for S3.
    public static func s3Endpoint(
        _ endpoint: String,
        applyingConfiguredPort port: UInt16,
        backendDefaultPort: UInt16 = BackendType.s3.defaultPort
    ) -> String {
        guard var components = URLComponents(string: endpoint), components.port == nil else {
            return endpoint
        }

        let schemeDefaultPort: UInt16?
        switch components.scheme?.lowercased() {
        case "http":
            schemeDefaultPort = 80
        case "https":
            schemeDefaultPort = 443
        default:
            schemeDefaultPort = nil
        }

        // Port 0 is unset, a port matching the scheme default adds nothing, and a port
        // still at the backend default was never chosen by anyone — the editor no longer
        // offers the field. Without that last check "http://host" would be rewritten to
        // "http://host:443" simply because S3 defaults to 443.
        guard port != 0, port != schemeDefaultPort, port != backendDefaultPort else {
            return endpoint
        }

        components.port = Int(port)
        return components.string ?? endpoint
    }

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
