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

    /// The region requests are signed for. Absent means AWS's default, which is what the
    /// editor stores as "nothing".
    ///
    /// Trimmed like the bucket and the endpoint, and read as absent when it holds only
    /// whitespace: the editor writes the Region field through as typed and an emptied one
    /// as `""`, so `"us-east-1 "` or `""` reached Soto as `Region(rawValue:)` and signed
    /// and routed requests for a region that does not exist.
    public var s3Region: String {
        Self.trimmedParameter(parameters["region"]) ?? Self.defaultS3Region
    }

    /// Whether requests address the bucket by path. Anything but an explicit "true" is
    /// virtual-host style, which is what the backend does with it.
    public var s3UsesPathStyle: Bool {
        parameters["pathStyle"] == "true"
    }

    public static let defaultS3Region = "us-east-1"

    /// The parameter keys that spell out an S3 address, each of which has a resolved form
    /// above. Everything else in `parameters` is compared as written.
    private static let s3AddressingParameterKeys: Set<String> = [
        "endpoint",
        "bucket",
        "region",
        "pathStyle"
    ]

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
              authMethod == other.authMethod else {
            return false
        }

        // Compared only where the backend reads them. S3 addresses by endpoint and the
        // account backends by their token; none of them is handed a host, a port or a
        // username, so a value left in one of those fields by an older build — or synced
        // from a device still writing it — is not part of the address. Comparing it anyway
        // made the save that normalizes it away read as a move to another server, which
        // took a working mount down and then refused to bring it back up. `makeConfig`
        // drops the same fields, and the editor's own `serverIdentity` ignores them for the
        // same reason.
        // Trimmed the way `makeConfig` writes them, not as they are stored: a legacy row —
        // or one synced from a build that saved the field as typed — can carry whitespace
        // around a host that reaches exactly the same server. Comparing the raw strings
        // reported the save that normalizes it away as a move to another server, which took
        // a working mount down and then refused to bring it back up.
        if backendType.usesHostBasedAddressing,
           Self.comparableField(host) != Self.comparableField(other.host) || port != other.port {
            return false
        }
        // The username names the target only where the backend sends it. An anonymous
        // login does not: FTP sends a fixed `USER anonymous` and WebDAV omits the
        // Authorization header entirely, so neither runtime reads `config.username`, and
        // the editor saves the field empty. Comparing it anyway made the save that clears
        // a legacy value read as a move to another server, which took a working mount
        // down and then refused to bring it back up.
        if backendType.usesUsername, !authenticatesAnonymously, username != other.username {
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
            // Compared as the backend resolves them, not as they happen to be written: an
            // absent region and an explicit "us-east-1" are one region, `pathStyle=false`
            // and no `pathStyle` are one addressing style, and a bucket differs from itself
            // by the whitespace around it. Reading the raw dictionary called each of those
            // pairs a different server and left a working mount down for nothing.
            guard Self.comparableS3Endpoint(s3Endpoint) == Self.comparableS3Endpoint(other.s3Endpoint),
                  s3Bucket == other.s3Bucket,
                  s3Region == other.s3Region else {
                return false
            }
            // Only where it reaches the wire. Soto is handed the addressing style with a
            // custom endpoint and nowhere else — against AWS itself the flag is dropped —
            // so a legacy row carrying `pathStyle=true` with no endpoint builds the same
            // client as one without the key, and calling the two different servers tore
            // down and rebuilt a mount that had not moved.
            if s3Endpoint != nil || other.s3Endpoint != nil,
               s3UsesPathStyle != other.s3UsesPathStyle {
                return false
            }
            return Self.comparableParameters(parameters, excluding: Self.s3AddressingParameterKeys)
                == Self.comparableParameters(other.parameters, excluding: Self.s3AddressingParameterKeys)
        }

        return Self.comparableParameters(parameters) == Self.comparableParameters(other.parameters)
    }

    /// Parameters as the editor would write them back.
    ///
    /// The account labels are stored as typed and read back trimmed — `displaySubtitle` and
    /// every other reader go through `trimmedParameter` — so a legacy or synced row holding
    /// `" user@example.com "` names the same account as the normalized one beside it.
    /// Comparing the dictionaries raw called that a move to another account, which for the
    /// OAuth backends is what leaves a mount down and its token unusable.
    private static func comparableParameters(
        _ parameters: [String: String],
        excluding excludedKeys: Set<String> = []
    ) -> [String: String] {
        parameters.reduce(into: [String: String]()) { result, entry in
            guard !excludedKeys.contains(entry.key) else { return }
            guard normalizedParameterKeys.contains(entry.key) else {
                result[entry.key] = entry.value
                return
            }
            // A key whose value is only whitespace reads as absent everywhere else, so it
            // is dropped rather than compared against a row that never had it.
            if let trimmed = trimmedParameter(entry.value) {
                result[entry.key] = trimmed
            }
        }
    }

    /// Parameters every reader takes through `trimmedParameter`.
    private static let normalizedParameterKeys: Set<String> = [
        "oauthAccountName",
        "oauthAccountEmail",
        "clientID",
        "redirectURI"
    ]

    /// Whether this config logs in without a name the backend would send.
    ///
    /// Checked against the backend's own list rather than the stored method alone, so a
    /// config pairing a backend with a method it never offered is still compared in full.
    private var authenticatesAnonymously: Bool {
        authMethod == .anonymous && backendType.supportedAuthMethods.contains(.anonymous)
    }

    /// A stored field as the editor would write it back.
    ///
    /// Only whitespace, and only where the editor itself trims: the username is saved as
    /// typed, because a server is handed that string verbatim and " user" is a different
    /// login from "user".
    static func comparableField(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An endpoint reduced to the address it reaches, for comparing two of them.
    ///
    /// A port that only repeats the scheme's default is not part of that address:
    /// `http://host:80` and `http://host` reach one server, as do `https://host:443` and
    /// `https://host`. Comparing them as written called one a move to another server and
    /// left a working mount down. Any other port is the address and is kept, as is an
    /// endpoint too malformed to parse.
    public static func comparableS3Endpoint(_ endpoint: String?) -> String? {
        guard let endpoint else { return nil }
        guard var components = URLComponents(string: endpoint),
              let port = components.port,
              port == schemeDefaultPort(for: components.scheme).map(Int.init) else {
            return endpoint
        }
        components.port = nil
        return components.string ?? endpoint
    }

    /// The port a scheme reaches when the endpoint does not spell one out.
    private static func schemeDefaultPort(for scheme: String?) -> UInt16? {
        switch scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }

    /// A parameter with surrounding whitespace removed, or nil when it holds nothing.
    public static func trimmedParameter(_ value: String?) -> String? {
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

        let schemeDefaultPort = schemeDefaultPort(for: components.scheme)

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
