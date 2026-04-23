import SwiftUI
import MFuseCore
import AppKit

private final class EphemeralCredentialProvider: CredentialProvider, @unchecked Sendable {
    func credential(for connectionID: UUID) async throws -> Credential? { nil }
    func store(_ credential: Credential, for connectionID: UUID) async throws {}
    func delete(for connectionID: UUID) async throws {}
}

struct ConnectionEditorSheet: View {

    @MainActor
    private static let sharedTestConnectionManager = ConnectionManager(
        storage: SharedStorage(
            allowFallbackToTemporaryDirectory: true,
            containerURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("MFuseTestConnectionManager", isDirectory: true)
        ),
        credentialProvider: EphemeralCredentialProvider()
    )

    @Environment(\.credentialProvider) private var credentialProvider
    @Environment(\.dismiss) private var dismiss

    // Editing state
    @State private var name: String
    @State private var backendType: BackendType
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var authMethod: AuthMethod
    @State private var remotePath: String
    @State private var autoMountOnLaunch: Bool
    @State private var password: String = ""
    @State private var oauthToken: String = ""
    @State private var privateKeyPath: String = ""
    @State private var privateKeyBookmark: String = ""

    // Backend-specific parameters
    @State private var s3Bucket: String = ""
    @State private var s3Region: String = "us-east-1"
    @State private var s3Endpoint: String = ""
    @State private var s3PathStyle: Bool = false
    @State private var s3AccessKeyID: String = ""
    @State private var s3SecretAccessKey: String = ""
    @State private var webdavTLS: Bool = true
    @State private var smbShare: String = ""
    @State private var smbDomain: String = ""
    @State private var ftpTLS: Bool = false
    @State private var ftpPassive: Bool = true
    @State private var gdClientID: String = ""
    @State private var gdRedirectURI: String = ""

    // Test connection
    @State private var isTesting = false
    private let formAnimation: Animation = .easeInOut(duration: 0.3)
    @State private var testResult: String?
    @State private var testSuccess = false
    @State private var didLoadStoredCredential = false
    @State private var currentTestTask: Task<Void, Never>?

    private let existingID: UUID?
    private let draftID: UUID
    private let onSave: (ConnectionConfig, Credential) -> Void

    init(config: ConnectionConfig?, onSave: @escaping (ConnectionConfig, Credential) -> Void) {
        self.existingID = config?.id
        self.draftID = config?.id ?? UUID()
        self.onSave = onSave
        _name = State(initialValue: config?.name ?? "")
        _backendType = State(initialValue: config?.backendType ?? .sftp)
        _host = State(initialValue: config?.host ?? "")
        _port = State(initialValue: config.map { "\($0.port)" } ?? "")
        _username = State(initialValue: config?.username ?? "")
        _authMethod = State(initialValue: config?.authMethod ?? .password)
        _remotePath = State(initialValue: config?.remotePath ?? "/")
        _autoMountOnLaunch = State(initialValue: config?.autoMountOnLaunch ?? false)
        // Backend-specific parameters
        let params = config?.parameters ?? [:]
        _privateKeyPath = State(initialValue: params["privateKeyPath"] ?? "")
        _privateKeyBookmark = State(initialValue: params["privateKeyBookmark"] ?? "")
        _s3Bucket = State(initialValue: params["bucket"] ?? "")
        _s3Region = State(initialValue: params["region"] ?? "us-east-1")
        _s3Endpoint = State(initialValue: params["endpoint"] ?? "")
        _s3PathStyle = State(initialValue: params["pathStyle"] == "true")
        _webdavTLS = State(initialValue: params["tls"] != "false")
        _smbShare = State(initialValue: params["share"] ?? "")
        _smbDomain = State(initialValue: params["domain"] ?? "")
        _ftpTLS = State(initialValue: params["tls"] == "true")
        _ftpPassive = State(initialValue: params["passive"] != "false")
        _gdClientID = State(initialValue: params["clientID"] ?? "")
        _gdRedirectURI = State(initialValue: params["redirectURI"] ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title
            HStack {
                Text(
                    existingID != nil
                        ? AppL10n.string("editor.title.editMount", fallback: "Edit Mount")
                        : AppL10n.string("editor.title.newMount", fallback: "New Mount")
                )
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            // Form
            Form {
                Section(AppL10n.string("editor.section.general", fallback: "General")) {
                    TextField(
                        AppL10n.string("editor.field.name", fallback: "Name"),
                        text: $name,
                        prompt: Text(AppL10n.string("editor.prompt.name", fallback: "My Server"))
                    )
                    Picker(AppL10n.string("detail.field.type", fallback: "Type"), selection: $backendType) {
                        ForEach(BackendType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .onChange(of: backendType) { newType in
                        if port.isEmpty || UInt16(port) == nil {
                            port = "\(newType.defaultPort)"
                        }
                        // Reset auth method if not supported
                        if !newType.supportedAuthMethods.contains(authMethod) {
                            authMethod = newType.supportedAuthMethods.first ?? .password
                        }
                    }
                    Toggle(AppL10n.string("editor.field.autoMountOnAppLaunch", fallback: "Auto-Mount on App Launch"), isOn: $autoMountOnLaunch)
                }

                // Hide host/port for Google Drive (cloud-only)
                if backendType != .googleDrive {
                    Section(AppL10n.string("detail.section.server", fallback: "Server")) {
                        if backendType != .s3 {
                            TextField(AppL10n.string("detail.field.host", fallback: "Host"), text: $host, prompt: Text(AppL10n.string("editor.prompt.host", fallback: "example.com")))
                        }
                        TextField(AppL10n.string("detail.field.port", fallback: "Port"), text: $port, prompt: Text("\(backendType.defaultPort)"))
                        if backendType != .s3 {
                            TextField(AppL10n.string("detail.field.username", fallback: "Username"), text: $username, prompt: Text(AppL10n.string("editor.prompt.username", fallback: "user")))
                        }
                        TextField(AppL10n.string("detail.field.remotePath", fallback: "Remote Path"), text: $remotePath, prompt: Text("/"))
                    }
                }

                // Backend-specific parameters
                switch backendType {
                case .s3:
                    Section(AppL10n.string("editor.section.s3", fallback: "S3 Settings")) {
                        TextField(AppL10n.string("editor.field.bucket", fallback: "Bucket"), text: $s3Bucket, prompt: Text(AppL10n.string("editor.prompt.bucket", fallback: "my-bucket")))
                        TextField(AppL10n.string("editor.field.region", fallback: "Region"), text: $s3Region, prompt: Text("us-east-1"))
                        TextField(AppL10n.string("editor.field.customEndpoint", fallback: "Custom Endpoint (optional)"), text: $s3Endpoint, prompt: Text("https://s3.amazonaws.com"))
                        Toggle(AppL10n.string("editor.field.pathStyleAccess", fallback: "Path-Style Access"), isOn: $s3PathStyle)
                    }
                case .webdav:
                    Section(AppL10n.string("editor.section.webdav", fallback: "WebDAV Settings")) {
                        Toggle(AppL10n.string("editor.field.useTLSHTTPS", fallback: "Use TLS (HTTPS)"), isOn: $webdavTLS)
                    }
                case .smb:
                    Section(AppL10n.string("editor.section.smb", fallback: "SMB Settings")) {
                        TextField(AppL10n.string("editor.field.shareName", fallback: "Share Name"), text: $smbShare, prompt: Text("shared"))
                        TextField(AppL10n.string("editor.field.domainOptional", fallback: "Domain (optional)"), text: $smbDomain, prompt: Text("WORKGROUP"))
                    }
                case .ftp:
                    Section(AppL10n.string("editor.section.ftp", fallback: "FTP Settings")) {
                        Toggle(AppL10n.string("editor.field.useTLSFTPS", fallback: "Use TLS (FTPS)"), isOn: $ftpTLS)
                        Toggle(AppL10n.string("editor.field.passiveMode", fallback: "Passive Mode"), isOn: $ftpPassive)
                    }
                case .googleDrive:
                    Section(AppL10n.string("editor.section.googleDrive", fallback: "Google Drive Settings")) {
                        TextField(
                            AppL10n.string("editor.field.oauthClientID", fallback: "OAuth Client ID"),
                            text: $gdClientID,
                            prompt: Text(
                                AppL10n.string(
                                    "editor.prompt.oauthClientID",
                                    fallback: "your-client-id.apps.googleusercontent.com"
                                )
                            )
                        )
                        TextField(AppL10n.string("editor.field.redirectURI", fallback: "Redirect URI"), text: $gdRedirectURI, prompt: Text("com.lollipopkit.mfuse:/oauth"))
                    }
                default:
                    EmptyView()
                }

                Section(AppL10n.string("editor.section.authentication", fallback: "Authentication")) {
                    let methods = backendType.supportedAuthMethods
                    if methods.count > 1 {
                        Picker(AppL10n.string("editor.field.method", fallback: "Method"), selection: $authMethod) {
                            ForEach(methods, id: \.self) { method in
                                Text(method.displayName).tag(method)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    switch authMethod {
                    case .password:
                        SecureField(AppL10n.string("editor.field.password", fallback: "Password"), text: $password)
                    case .publicKey:
                        HStack {
                            TextField(AppL10n.string("editor.field.privateKeyPath", fallback: "Private Key Path"), text: $privateKeyPath)
                            Button(AppL10n.string("editor.action.browse", fallback: "Browse…")) { browseKeyFile() }
                                .controlSize(.small)
                        }
                        SecureField(AppL10n.string("editor.field.passphraseOptional", fallback: "Passphrase (optional)"), text: $password)
                    case .agent:
                        Text(AppL10n.string("editor.message.sshAgent", fallback: "SSH Agent will be used for authentication."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .accessKey:
                        TextField(AppL10n.string("editor.field.accessKeyID", fallback: "Access Key ID"), text: $s3AccessKeyID)
                        SecureField(AppL10n.string("editor.field.secretAccessKey", fallback: "Secret Access Key"), text: $s3SecretAccessKey)
                    case .anonymous:
                        Text(AppL10n.string("editor.message.noCredentialsRequired", fallback: "No credentials required."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .oauth:
                        Text(AppL10n.string("editor.message.googleSignInAfterSaving", fallback: "You will be prompted to sign in with Google after saving."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Insecure protocol warning
                if (backendType == .ftp && !ftpTLS) || (backendType == .webdav && !webdavTLS) {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(AppL10n.string("editor.warning.cleartextCredentials", fallback: "Credentials will be sent in cleartext. Enable TLS to encrypt this mount."))
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                // Test result
                if let result = testResult {
                    Section {
                        HStack {
                            Image(systemName: testSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(testSuccess ? .green : .red)
                                .contentTransition(.symbolEffect(.replace))
                            Text(result)
                                .font(.caption)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .formStyle(.grouped)
            .animation(formAnimation, value: backendType)
            .animation(formAnimation, value: authMethod)
            .animation(formAnimation, value: testResult)

            Divider()

            // Buttons
            HStack {
                Button(AppL10n.string("editor.action.testAccess", fallback: "Test Access")) { testConnection() }
                    .disabled(isTesting || !isValid)
                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button(AppL10n.string("common.action.cancel", fallback: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AppL10n.string("common.action.save", fallback: "Save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .task(id: existingID) {
            await loadStoredCredentialIfNeeded()
        }
        .onChange(of: authMethod) { newMethod in
            clearCredentialState(except: newMethod)
        }
        .onChange(of: privateKeyPath) { newPath in
            guard authMethod == .publicKey else { return }
            if newPath.isEmpty {
                privateKeyBookmark = ""
                return
            }
            if let bookmarkedPath = bookmarkedPrivateKeyPath(), bookmarkedPath != newPath {
                privateKeyBookmark = ""
            }
        }
        .onDisappear {
            currentTestTask?.cancel()
            currentTestTask = nil
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        guard !name.isEmpty else { return false }
        if backendType == .googleDrive {
            return !gdClientID.isEmpty && !gdRedirectURI.isEmpty
        }
        if backendType == .s3 {
            let hasValidPort = UInt16(port) != nil || port.isEmpty
            let hasRequiredAccessKeyCredentials =
                authMethod != .accessKey || (!s3AccessKeyID.isEmpty && !s3SecretAccessKey.isEmpty)
            return !s3Bucket.isEmpty && hasValidPort && hasRequiredAccessKeyCredentials
        }
        return !host.isEmpty && (UInt16(port) != nil || port.isEmpty)
    }

    // MARK: - Actions

    private func save() {
        do {
            let credential = try buildCredential()
            let config = ConnectionConfig(
                id: draftID,
                name: name,
                backendType: backendType,
                host: host,
                port: UInt16(port) ?? backendType.defaultPort,
                username: username,
                authMethod: authMethod,
                remotePath: remotePath.isEmpty ? "/" : remotePath,
                parameters: try buildParameters(),
                autoMountOnLaunch: autoMountOnLaunch
            )
            onSave(config, credential)
        } catch {
            testResult = error.localizedDescription
            testSuccess = false
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        currentTestTask?.cancel()
        currentTestTask = nil
        let credential: Credential
        do {
            let parameters = try buildParameters()
            let config = ConnectionConfig(
                name: name,
                backendType: backendType,
                host: host,
                port: UInt16(port) ?? backendType.defaultPort,
                username: username,
                authMethod: authMethod,
                remotePath: remotePath.isEmpty ? "/" : remotePath,
                parameters: parameters,
                autoMountOnLaunch: autoMountOnLaunch
            )
            credential = try buildCredential()

            currentTestTask = Task {
                let result = await Self.sharedTestConnectionManager.testConnection(
                    config,
                    credential: credential
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    switch result {
                    case .success:
                        testResult = AppL10n.string("editor.message.accessSuccessful", fallback: "Access successful!")
                        testSuccess = true
                    case .failure(let error):
                        testResult = error.localizedDescription
                        testSuccess = false
                    }
                    isTesting = false
                    currentTestTask = nil
                }
            }
        } catch {
            testResult = error.localizedDescription
            testSuccess = false
            isTesting = false
            return
        }
    }

    private func buildCredential() throws -> Credential {
        switch authMethod {
        case .password:
            return Credential(password: password)
        case .publicKey:
            guard !privateKeyPath.isEmpty else {
                throw RemoteFileSystemError.authenticationFailed
            }
            do {
                let keyData = try readPrivateKeyData()
                return Credential(
                    password: nil,
                    privateKey: keyData,
                    passphrase: password.isEmpty ? nil : password
                )
            } catch {
                throw RemoteFileSystemError.operationFailed(
                    AppL10n.string(
                        "editor.error.readPrivateKey",
                        fallback: "Unable to read private key at %@: %@",
                        privateKeyPath,
                        error.localizedDescription
                    )
                )
            }
        case .agent:
            return Credential()
        case .accessKey:
            return Credential(
                accessKeyID: s3AccessKeyID,
                secretAccessKey: s3SecretAccessKey
            )
        case .anonymous:
            return Credential()
        case .oauth:
            return Credential(token: oauthToken.isEmpty ? nil : oauthToken)
        }
    }

    @MainActor
    private func loadStoredCredentialIfNeeded() async {
        guard !didLoadStoredCredential, let existingID else { return }
        didLoadStoredCredential = true

        guard let credential = try? await credentialProvider.credential(for: existingID) else { return }

        switch authMethod {
        case .password:
            if password.isEmpty {
                password = credential.password ?? ""
            }
        case .publicKey:
            if password.isEmpty {
                password = credential.passphrase ?? ""
            }
        case .accessKey:
            if s3AccessKeyID.isEmpty {
                s3AccessKeyID = credential.accessKeyID ?? ""
            }
            if s3SecretAccessKey.isEmpty {
                s3SecretAccessKey = credential.secretAccessKey ?? ""
            }
        case .oauth:
            if oauthToken.isEmpty {
                oauthToken = credential.token ?? ""
            }
        case .agent, .anonymous:
            break
        }
    }

    private func clearCredentialState(except method: AuthMethod) {
        switch method {
        case .password:
            oauthToken = ""
            privateKeyPath = ""
            privateKeyBookmark = ""
            s3AccessKeyID = ""
            s3SecretAccessKey = ""
        case .publicKey:
            oauthToken = ""
            s3AccessKeyID = ""
            s3SecretAccessKey = ""
        case .agent, .anonymous:
            password = ""
            oauthToken = ""
            privateKeyPath = ""
            privateKeyBookmark = ""
            s3AccessKeyID = ""
            s3SecretAccessKey = ""
        case .accessKey:
            password = ""
            oauthToken = ""
            privateKeyPath = ""
            privateKeyBookmark = ""
        case .oauth:
            password = ""
            privateKeyPath = ""
            privateKeyBookmark = ""
            s3AccessKeyID = ""
            s3SecretAccessKey = ""
        }
    }

    private func buildParameters() throws -> [String: String] {
        var params: [String: String] = [:]
        switch backendType {
        case .s3:
            if !s3Bucket.isEmpty { params["bucket"] = s3Bucket }
            if s3Region != "us-east-1" { params["region"] = s3Region }
            if !s3Endpoint.isEmpty { params["endpoint"] = s3Endpoint }
            if s3PathStyle { params["pathStyle"] = "true" }
        case .webdav:
            if !webdavTLS { params["tls"] = "false" }
        case .smb:
            if !smbShare.isEmpty { params["share"] = smbShare }
            if !smbDomain.isEmpty { params["domain"] = smbDomain }
        case .ftp:
            if ftpTLS { params["tls"] = "true" }
            if !ftpPassive { params["passive"] = "false" }
        case .googleDrive:
            guard !gdClientID.isEmpty, !gdRedirectURI.isEmpty else {
                throw RemoteFileSystemError.operationFailed(
                    AppL10n.string(
                        "editor.error.googleDriveOAuthFieldsRequired",
                        fallback: "Google Drive requires both OAuth Client ID and Redirect URI"
                    )
                )
            }
            params["clientID"] = gdClientID
            params["redirectURI"] = gdRedirectURI
        default:
            break
        }
        if authMethod == .publicKey, !privateKeyPath.isEmpty {
            params["privateKeyPath"] = privateKeyPath
            if !privateKeyBookmark.isEmpty {
                params["privateKeyBookmark"] = privateKeyBookmark
            }
        }
        return params
    }

    private func browseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")
        panel.begin { response in
            if response == .OK, let url = panel.url {
                DispatchQueue.main.async {
                    self.privateKeyPath = url.path
                    self.privateKeyBookmark = self.makePrivateKeyBookmark(for: url) ?? ""
                }
            }
        }
    }

    private func readPrivateKeyData() throws -> Data {
        if let bookmarkedURL = resolvedPrivateKeyURLFromBookmark() {
            let didAccess = bookmarkedURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    bookmarkedURL.stopAccessingSecurityScopedResource()
                }
            }
            return try Data(contentsOf: bookmarkedURL)
        }

        return try Data(contentsOf: URL(fileURLWithPath: privateKeyPath))
    }

    private func resolvedPrivateKeyURLFromBookmark() -> URL? {
        guard !privateKeyBookmark.isEmpty,
              let bookmarkData = Data(base64Encoded: privateKeyBookmark) else {
            return nil
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        if !privateKeyPath.isEmpty && url.path != privateKeyPath {
            return nil
        }

        if isStale, let refreshedBookmark = makePrivateKeyBookmark(for: url) {
            privateKeyBookmark = refreshedBookmark
        }

        return url
    }

    private func bookmarkedPrivateKeyPath() -> String? {
        guard let url = resolvedPrivateKeyURLFromBookmark() else {
            return nil
        }
        return url.path
    }

    private func makePrivateKeyBookmark(for url: URL) -> String? {
        guard let bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return nil
        }
        return bookmarkData.base64EncodedString()
    }
}
