import SwiftUI
import MFuseCore
import MFuseDropbox
import MFuseOneDrive
import AppKit

private final class EphemeralCredentialProvider: CredentialProvider, @unchecked Sendable {
    func credential(for connectionID: UUID) async throws -> Credential? { nil }
    func store(_ credential: Credential, for connectionID: UUID) async throws {}
    func delete(for connectionID: UUID) async throws {}
}

struct ConnectionEditorSheet: View {

    /// The backends a connection test runs against, registered so a token they refresh is
    /// discarded rather than written into the app's credential store: the config under
    /// test carries a throwaway id, and a secret persisted for it would outlive the test
    /// under an id no connection will ever have.
    private static let testBackendRegistry: BackendRegistry = {
        let registry = BackendRegistry()
        BackendRegistryFactory.register(into: registry) { _, _ in }
        return registry
    }()

    @MainActor
    private static let sharedTestConnectionManager = ConnectionManager(
        storage: SharedStorage(
            allowFallbackToTemporaryDirectory: true,
            containerURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("MFuseTestConnectionManager", isDirectory: true)
        ),
        credentialProvider: EphemeralCredentialProvider(),
        registry: testBackendRegistry
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
    @State private var oauthCredential: Credential?
    /// The credential this mount was saved with, kept so a save cannot destroy the parts
    /// of it the editor has no field for — Google Drive's refresh token above all.
    @State private var storedCredential: Credential?
    @State private var oauthAccountName: String = ""
    @State private var oauthAccountEmail: String = ""
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
    @State private var isLoadingStoredCredential = false
    /// The method a backend switch installed, pending its change handler. See
    /// `onChange(of: authMethod)`.
    @State private var backendNormalizedAuthMethod: AuthMethod?
    @State private var currentTestTask: Task<Void, Never>?
    @State private var oauthAuthorizationTask: Task<Void, Never>?
    @State private var isAuthorizingOAuth = false

    private let existingID: UUID?
    private let draftID: UUID
    /// The key path this mount was saved with, so a save that cannot re-read the file can
    /// tell "the same key as before" from "a key the user just pointed us at".
    private let savedPrivateKeyPath: String
    /// The backend the stored credential was issued for. See
    /// `savedCredentialForCurrentBackend`.
    private let savedBackendType: BackendType?
    private let onSave: (ConnectionConfig, Credential) -> Void

    init(config: ConnectionConfig?, onSave: @escaping (ConnectionConfig, Credential) -> Void) {
        self.existingID = config?.id
        self.draftID = config?.id ?? UUID()
        self.savedPrivateKeyPath = config?.parameters["privateKeyPath"] ?? ""
        self.savedBackendType = config?.backendType
        self.onSave = onSave
        _name = State(initialValue: config?.name ?? "")
        _backendType = State(initialValue: config?.backendType ?? .sftp)
        _host = State(initialValue: config?.host ?? "")
        // A backend the port field is hidden for has its stored port folded into the
        // address it belongs to (see `_s3Endpoint` below) and reset here. Carrying the
        // old value forward would silently stamp it onto whatever address is saved next:
        // a legacy "http://localhost" + 9000 config re-pointed at "https://s3.example.com"
        // would go on connecting to port 9000.
        _port = State(initialValue: config.map { existing in
            existing.backendType.usesHostBasedAddressing
                ? "\(existing.port)"
                : "\(existing.backendType.defaultPort)"
        } ?? "")
        _username = State(initialValue: config?.username ?? "")
        // Normalized on open, not just on a backend switch: a config carrying a method its
        // backend does not support — written by an older build, or synced from one — has no
        // row in the picker to correct it, so it would be saved and tested as-is. An S3
        // mount stuck on `.password` saves with no access keys and then fails every time.
        _authMethod = State(initialValue: config.map { existing in
            existing.backendType.supportedAuthMethods.contains(existing.authMethod)
                ? existing.authMethod
                : existing.backendType.supportedAuthMethods.first ?? existing.authMethod
        } ?? .password)
        _remotePath = State(initialValue: config?.remotePath ?? "/")
        _autoMountOnLaunch = State(initialValue: config?.autoMountOnLaunch ?? false)
        // Backend-specific parameters
        let params = config?.parameters ?? [:]
        _privateKeyPath = State(initialValue: params["privateKeyPath"] ?? "")
        _privateKeyBookmark = State(initialValue: params["privateKeyBookmark"] ?? "")
        _s3Bucket = State(initialValue: params["bucket"] ?? "")
        _s3Region = State(initialValue: params["region"] ?? "us-east-1")
        // Resolved, not raw: this is where a legacy config's hidden port is folded into
        // the endpoint, so editing one keeps reaching the server it reached before.
        _s3Endpoint = State(initialValue: config?.s3Endpoint ?? params["endpoint"] ?? "")
        _s3PathStyle = State(initialValue: params["pathStyle"] == "true")
        _webdavTLS = State(initialValue: params["tls"] != "false")
        _smbShare = State(initialValue: params["share"] ?? "")
        _smbDomain = State(initialValue: params["domain"] ?? "")
        _ftpTLS = State(initialValue: params["tls"] == "true")
        _ftpPassive = State(initialValue: params["passive"] != "false")
        _gdClientID = State(initialValue: params["clientID"] ?? "")
        _gdRedirectURI = State(initialValue: params["redirectURI"] ?? "")
        _oauthAccountName = State(initialValue: params["oauthAccountName"] ?? "")
        _oauthAccountEmail = State(initialValue: params["oauthAccountEmail"] ?? "")
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
                    .onChange(of: backendType) { oldType, newType in
                        // Only a port the user actually chose survives the switch. A value
                        // left at the previous backend's default is not a choice — carrying
                        // it over silently mounted SFTP on 443 after a switch from S3 — and
                        // one belonging to a backend whose port field is hidden is invisible
                        // yet still reaches the endpoint shim in S3FileSystem.
                        let currentPort = UInt16(port)
                        if !newType.usesHostBasedAddressing
                            || currentPort == nil
                            || currentPort == oldType.defaultPort {
                            port = "\(newType.defaultPort)"
                        }
                        // Reset auth method if not supported. Recorded, because the change
                        // handler below cannot otherwise tell this from the user picking a
                        // different method — and it answers the two very differently.
                        if !newType.supportedAuthMethods.contains(authMethod) {
                            let normalizedMethod = newType.supportedAuthMethods.first ?? .password
                            backendNormalizedAuthMethod = normalizedMethod
                            authMethod = normalizedMethod
                        }
                        // A secret belongs to the server it was entered for, and this
                        // switch points the mount at a different one. The auth method can
                        // survive the switch — SFTP and SMB both use `.password` — so
                        // nothing else clears it: `clearCredentialState(except:)` runs only
                        // when the *method* changes, and deliberately keeps the field the
                        // current method needs, which here is exactly the one that must not
                        // travel.
                        clearEnteredSecrets()
                        clearOAuthAuthorizationState()
                    }
                    // Locked while the stored credential is on its way: what it belongs
                    // to must not move under it.
                    .disabled(isLoadingStoredCredential)
                    Toggle(AppL10n.string("editor.field.autoMountOnAppLaunch", fallback: "Auto-Mount on App Launch"), isOn: $autoMountOnLaunch)
                }

                if backendType.requiresServerEndpoint {
                    Section(AppL10n.string("detail.section.server", fallback: "Server")) {
                        // Showing fields the backend ignores invites configurations like
                        // "http://localhost" + port 9000, which connect to port 80.
                        if backendType.usesHostBasedAddressing {
                            TextField(AppL10n.string("detail.field.host", fallback: "Host"), text: $host, prompt: Text(AppL10n.string("editor.prompt.host", fallback: "example.com")))
                            TextField(AppL10n.string("detail.field.port", fallback: "Port"), text: $port, prompt: Text("\(backendType.defaultPort)"))
                            // NFS addresses by host but authorizes by UID, and an anonymous
                            // login carries no name either, so neither has a username to
                            // offer — and one left over from the backend or method selected
                            // before must not be saved with it.
                            if usesUsernameField {
                                TextField(AppL10n.string("detail.field.username", fallback: "Username"), text: $username, prompt: Text(AppL10n.string("editor.prompt.username", fallback: "user")))
                            }
                        }
                        TextField(AppL10n.string("detail.field.remotePath", fallback: "Remote Path"), text: $remotePath, prompt: Text("/"))
                    }
                }

                // Backend-specific parameters
                switch backendType {
                case .s3:
                    Section {
                        TextField(AppL10n.string("editor.field.bucket", fallback: "Bucket"), text: $s3Bucket, prompt: Text(AppL10n.string("editor.prompt.bucket", fallback: "my-bucket")))
                        TextField(AppL10n.string("editor.field.region", fallback: "Region"), text: $s3Region, prompt: Text("us-east-1"))
                        TextField(AppL10n.string("editor.field.customEndpoint", fallback: "Custom Endpoint (optional)"), text: $s3Endpoint, prompt: Text("http://localhost:9000"))
                        // Only offered with an endpoint: AWS requests always go out in
                        // virtual-host form, so the toggle would do nothing there.
                        if hasCustomS3Endpoint {
                            Toggle(AppL10n.string("editor.field.pathStyleAccess", fallback: "Path-Style Access"), isOn: $s3PathStyle)
                        }
                    } header: {
                        Text(AppL10n.string("editor.section.s3", fallback: "S3 Settings"))
                    } footer: {
                        Text(AppL10n.string(
                            "editor.footer.s3Endpoint",
                            fallback: "Leave the endpoint empty for AWS. For a self-hosted server, include the port in the endpoint."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        .disabled(isLoadingStoredCredential)
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
                        if usesBundledOAuthFlow {
                            VStack(alignment: .leading, spacing: 10) {
                                if hasConnectedOAuthAccount {
                                    Label(
                                        oauthAccountSummary,
                                        systemImage: "person.crop.circle.badge.checkmark"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                } else {
                                    Text(
                                        AppL10n.string(
                                            "editor.message.connectAccountBeforeSaving",
                                            fallback: "Connect your account before testing or saving this mount."
                                        )
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }

                                HStack(spacing: 12) {
                                    Button(
                                        hasConnectedOAuthAccount
                                            ? AppL10n.string("editor.action.reauthenticate", fallback: "Re-authenticate")
                                            : AppL10n.string("editor.action.connectAccount", fallback: "Connect Account")
                                    ) {
                                        connectOAuthAccount()
                                    }
                                    .disabled(isAuthorizingOAuth)

                                    if isAuthorizingOAuth {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                }
                            }
                        } else {
                            Text(AppL10n.string("editor.message.googleSignInAfterSaving", fallback: "You will be prompted to sign in with Google after saving."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                    .disabled(isTesting || isAuthorizingOAuth || isLoadingStoredCredential || !isValid)
                if isTesting || isAuthorizingOAuth || isLoadingStoredCredential {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button(AppL10n.string("common.action.cancel", fallback: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AppL10n.string("common.action.save", fallback: "Save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    // Saving replaces the stored credential outright, and the fields start
                    // empty: saving before the stored one has been read writes that
                    // emptiness over a working password.
                    .disabled(!isValid || isLoadingStoredCredential)
            }
            .padding()
        }
        .task(id: existingID) {
            await loadStoredCredentialIfNeeded()
        }
        .onChange(of: authMethod) { _, newMethod in
            // A method the backend switch installed is not a choice about credentials: the
            // switch already cleared everything on screen, and destroying the saved
            // credential here as well would make a round trip through the picker — Google
            // Drive to SFTP and back — lose a refresh token this sheet cannot load again,
            // and then write the emptiness over it on save. `savedCredentialForCurrentBackend`
            // is what keeps it from reaching the wrong backend meanwhile.
            if backendNormalizedAuthMethod == newMethod {
                backendNormalizedAuthMethod = nil
                return
            }
            clearCredentialState(except: newMethod)
        }
        .onChange(of: privateKeyPath) { _, newPath in
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
            oauthAuthorizationTask?.cancel()
            oauthAuthorizationTask = nil
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        guard !name.isEmpty else { return false }
        if backendType == .googleDrive {
            return !gdClientID.isEmpty && !gdRedirectURI.isEmpty
        }
        if usesBundledOAuthFlow {
            return hasConnectedOAuthAccount
        }
        if backendType == .s3 {
            let hasValidPort = UInt16(port) != nil || port.isEmpty
            let hasRequiredAccessKeyCredentials =
                authMethod != .accessKey || (!s3AccessKeyID.isEmpty && !s3SecretAccessKey.isEmpty)
            return !s3Bucket.isEmpty && hasValidPort && hasRequiredAccessKeyCredentials
        }
        return !backendType.requiresServerEndpoint || (!host.isEmpty && (UInt16(port) != nil || port.isEmpty))
    }

    // MARK: - Actions

    /// Build the config to save or test.
    ///
    /// Host and username are dropped for backends that address by endpoint or account:
    /// the editor hides those fields, so whatever they still hold belongs to a backend
    /// that was selected earlier and would otherwise be written into `connections.json`
    /// and every File Provider bootstrap snapshot.
    ///
    /// The host is trimmed for the same reason `displayAddress` trims it: without this the
    /// row shows "example.com" while the backend is handed " example.com" and cannot
    /// resolve it.
    private func makeConfig(id: UUID) throws -> ConnectionConfig {
        let usesHostBasedAddressing = backendType.usesHostBasedAddressing
        return ConnectionConfig(
            id: id,
            name: name,
            backendType: backendType,
            host: usesHostBasedAddressing
                ? host.trimmingCharacters(in: .whitespacesAndNewlines)
                : "",
            port: UInt16(port) ?? backendType.defaultPort,
            username: usesUsernameField ? username : "",
            authMethod: authMethod,
            remotePath: remotePath.isEmpty ? "/" : remotePath,
            parameters: try buildParameters(),
            autoMountOnLaunch: autoMountOnLaunch
        )
    }

    private func save() {
        do {
            let credential = try buildCredential()
            let config = try makeConfig(id: draftID)
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
            // A throwaway id, so a test can never touch what the saved mount stored.
            let testConnectionID = UUID()
            let config = try makeConfig(id: testConnectionID)
            credential = try buildCredential()
            let testedSubject = currentTestSubject()

            currentTestTask = Task {
                let result = await Self.sharedTestConnectionManager.testConnection(
                    config,
                    credential: credential
                )
                // Belt and braces over the ephemeral registry above: an id that never
                // belonged to a connection must hold nothing in the app's store either way,
                // and this runs before the cancellation check so a dismissed sheet leaves
                // nothing behind.
                try? await credentialProvider.delete(for: testConnectionID)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    isTesting = false
                    currentTestTask = nil
                    // The sheet stays editable for the whole test, and the verdict is read
                    // as one on what is on screen now: shown against changed fields,
                    // "Access successful" claims a configuration nobody tested works.
                    guard currentTestSubject() == testedSubject else {
                        testResult = nil
                        return
                    }
                    switch result {
                    case .success:
                        testResult = AppL10n.string("editor.message.accessSuccessful", fallback: "Access successful!")
                        testSuccess = true
                    case .failure(let error):
                        testResult = error.localizedDescription
                        testSuccess = false
                    }
                }
            }
        } catch {
            testResult = error.localizedDescription
            testSuccess = false
            isTesting = false
            return
        }
    }

    /// Everything a connection test is a verdict on: the config it builds plus the secrets
    /// that never reach one. `nil` while the form cannot produce a config at all.
    private func currentTestSubject() -> TestSubject? {
        guard let config = try? makeConfig(id: draftID) else { return nil }
        return TestSubject(
            config: config,
            password: password,
            privateKeyPath: privateKeyPath,
            privateKeyBookmark: privateKeyBookmark,
            accessKeyID: s3AccessKeyID,
            secretAccessKey: s3SecretAccessKey,
            oauthToken: (usesBundledOAuthFlow ? oauthCredential : savedCredentialForCurrentBackend)?.token
        )
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
                // The file cannot be read right now — moved, or outside what this sandbox
                // may open without a fresh bookmark — but the mount already has key
                // material saved for this exact path. Renaming it or toggling auto-mount
                // must not fail on that, nor replace a working key with nothing.
                if privateKeyPath == savedPrivateKeyPath,
                   let savedPrivateKey = savedCredentialForCurrentBackend?.privateKey {
                    return Credential(
                        password: nil,
                        privateKey: savedPrivateKey,
                        passphrase: password.isEmpty ? nil : password
                    )
                }
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
            if usesBundledOAuthFlow {
                guard let oauthCredential,
                      oauthCredential.token?.isEmpty == false else {
                    throw RemoteFileSystemError.authenticationFailed
                }
                return oauthCredential
            }
            // Google Drive has no token field in this sheet — sign-in happens after
            // saving, and the refresh token lives in `password`. Reconstructing the
            // credential from what the editor shows would drop it, leaving a mount that
            // can never refresh; the stored one is passed through untouched instead.
            return savedCredentialForCurrentBackend ?? Credential()
        }
    }

    @MainActor
    private func loadStoredCredentialIfNeeded() async {
        guard !didLoadStoredCredential, let existingID else { return }
        didLoadStoredCredential = true
        isLoadingStoredCredential = true
        defer { isLoadingStoredCredential = false }

        // The sheet stays on screen across this await, so what the credential belongs to
        // has to be pinned before it. Applying it to a backend or method the user has
        // since switched to is not merely wrong: a Google Drive refresh token lives in
        // `password`, so a switch to SFTP would drop it into the password field — and the
        // next save would store it as one.
        let requestedBackendType = backendType
        let requestedAuthMethod = authMethod

        let credential: Credential?
        do {
            credential = try await credentialProvider.credential(for: existingID)
        } catch {
            // Saving replaces the stored credential outright, so a load this sheet
            // silently swallowed would let an empty field wipe a working secret. Say so
            // instead — Save stays available, but the user knows what it will write.
            testResult = AppL10n.string(
                "editor.error.loadStoredCredential",
                fallback: "Could not read the saved credential: %@. Saving will replace it with what is entered here.",
                error.localizedDescription
            )
            testSuccess = false
            return
        }
        guard let credential else { return }
        guard backendType == requestedBackendType, authMethod == requestedAuthMethod else {
            return
        }

        switch authMethod {
        case .password:
            if password.isEmpty {
                password = credential.password ?? ""
            }
        case .publicKey:
            if password.isEmpty {
                password = credential.passphrase ?? ""
            }
            // Kept for the same reason Google Drive's is: the sheet has no field holding
            // the key material, so a save that cannot re-read the file would otherwise
            // have nothing to write back. See `buildCredential()`.
            if storedCredential == nil {
                storedCredential = credential
            }
        case .accessKey:
            if s3AccessKeyID.isEmpty {
                s3AccessKeyID = credential.accessKeyID ?? ""
            }
            if s3SecretAccessKey.isEmpty {
                s3SecretAccessKey = credential.secretAccessKey ?? ""
            }
        case .oauth:
            if usesBundledOAuthFlow {
                oauthCredential = credential
            } else if storedCredential == nil {
                storedCredential = credential
            }
        case .agent, .anonymous:
            break
        }
    }

    /// Drop every secret the sheet is showing, whichever method it belongs to.
    private func clearEnteredSecrets() {
        password = ""
        privateKeyPath = ""
        privateKeyBookmark = ""
        s3AccessKeyID = ""
        s3SecretAccessKey = ""
    }

    /// The credential this mount was saved with, offered only while the sheet still
    /// describes the backend it was saved for.
    ///
    /// It survives a round trip through the backend picker — that is what keeps a Google
    /// Drive refresh token from being destroyed by one — but what one server issued must
    /// never be built into the credential written for another.
    private var savedCredentialForCurrentBackend: Credential? {
        guard backendType == savedBackendType else { return nil }
        return storedCredential
    }

    private func clearCredentialState(except method: AuthMethod) {
        switch method {
        case .password:
            storedCredential = nil
            oauthCredential = nil
            oauthAccountName = ""
            oauthAccountEmail = ""
            privateKeyPath = ""
            privateKeyBookmark = ""
            s3AccessKeyID = ""
            s3SecretAccessKey = ""
        case .publicKey:
            storedCredential = nil
            oauthCredential = nil
            oauthAccountName = ""
            oauthAccountEmail = ""
            s3AccessKeyID = ""
            s3SecretAccessKey = ""
        case .agent, .anonymous:
            password = ""
            storedCredential = nil
            oauthCredential = nil
            oauthAccountName = ""
            oauthAccountEmail = ""
            privateKeyPath = ""
            privateKeyBookmark = ""
            s3AccessKeyID = ""
            s3SecretAccessKey = ""
        case .accessKey:
            password = ""
            storedCredential = nil
            oauthCredential = nil
            oauthAccountName = ""
            oauthAccountEmail = ""
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
            // Trimmed, and dropped when nothing is left: `hasCustomS3Endpoint` reads a
            // whitespace-only field as "no endpoint" and so does `ConnectionConfig`, so
            // storing one raw left a config claiming a custom endpoint it does not have.
            let trimmedS3Endpoint = s3Endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedS3Endpoint.isEmpty { params["endpoint"] = trimmedS3Endpoint }
            // Persisted only where it has an effect, so a saved config never claims an
            // addressing style the backend cannot apply.
            if s3PathStyle && hasCustomS3Endpoint { params["pathStyle"] = "true" }
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
        case .dropbox, .oneDrive:
            if !oauthAccountName.isEmpty { params["oauthAccountName"] = oauthAccountName }
            if !oauthAccountEmail.isEmpty { params["oauthAccountEmail"] = oauthAccountEmail }
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

    /// Whether the selected backend *and* method carry a username.
    ///
    /// An anonymous FTP login sends a fixed `anonymous`, and anonymous WebDAV sends no
    /// credentials at all, so neither backend reads `config.username` on that path.
    private var usesUsernameField: Bool {
        backendType.usesUsername && authMethod != .anonymous
    }

    private var hasCustomS3Endpoint: Bool {
        !s3Endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var usesBundledOAuthFlow: Bool {
        backendType == .dropbox || backendType == .oneDrive
    }

    private var hasConnectedOAuthAccount: Bool {
        if usesBundledOAuthFlow {
            return oauthCredential?.token?.isEmpty == false
        }
        return savedCredentialForCurrentBackend?.token?.isEmpty == false
    }

    private var oauthAccountSummary: String {
        let pieces = [oauthAccountName, oauthAccountEmail]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if pieces.isEmpty {
            return AppL10n.string("editor.message.accountConnected", fallback: "Account connected")
        }
        return pieces.joined(separator: " · ")
    }

    private func clearOAuthAuthorizationState() {
        oauthAuthorizationTask?.cancel()
        oauthAuthorizationTask = nil
        isAuthorizingOAuth = false
        oauthCredential = nil
        oauthAccountName = ""
        oauthAccountEmail = ""
        // `storedCredential` deliberately survives: it is only ever emitted for a Google
        // Drive mount, and the sheet cannot load it a second time, so clearing it here
        // would let a round trip through the backend picker destroy a refresh token.
        // Switching *auth method* does clear it — see `clearCredentialState(except:)`.
    }

    private func connectOAuthAccount() {
        oauthAuthorizationTask?.cancel()
        isAuthorizingOAuth = true
        testResult = nil
        oauthAuthorizationTask = Task {
            do {
                let authorized = try await authorizeOAuthAccount()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    oauthCredential = authorized.credential
                    oauthAccountName = authorized.displayName
                    oauthAccountEmail = authorized.email ?? ""
                    isAuthorizingOAuth = false
                    oauthAuthorizationTask = nil
                    testResult = AppL10n.string(
                        "editor.message.accountConnected",
                        fallback: "Account connected"
                    )
                    testSuccess = true
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isAuthorizingOAuth = false
                    oauthAuthorizationTask = nil
                    testResult = error.localizedDescription
                    testSuccess = false
                }
            }
        }
    }

    @MainActor
    private func authorizeOAuthAccount() async throws -> OAuthAuthorizationResult {
        switch backendType {
        case .dropbox:
            let account = try await DropboxOAuthProvider.builtIn().authorize()
            return OAuthAuthorizationResult(
                credential: account.credential,
                displayName: account.displayName,
                email: account.email
            )
        case .oneDrive:
            let account = try await OneDriveOAuthProvider.builtIn().authorize()
            return OAuthAuthorizationResult(
                credential: account.credential,
                displayName: account.displayName,
                email: account.email
            )
        default:
            throw RemoteFileSystemError.unsupported(
                AppL10n.string(
                    "editor.error.oauthProviderUnavailable",
                    fallback: "This backend does not support built-in OAuth authorization."
                )
            )
        }
    }
}

/// A snapshot of everything a connection test depends on, so its result can be dropped
/// when the form no longer holds what was tested.
private struct TestSubject: Equatable {
    let config: ConnectionConfig
    let password: String
    let privateKeyPath: String
    let privateKeyBookmark: String
    let accessKeyID: String
    let secretAccessKey: String
    let oauthToken: String?
}

private struct OAuthAuthorizationResult {
    let credential: Credential
    let displayName: String
    let email: String?
}
