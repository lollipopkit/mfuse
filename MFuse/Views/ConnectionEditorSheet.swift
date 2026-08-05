import SwiftUI
import MFuseCore
import MFuseDropbox
import MFuseGoogleDrive
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
    /// Whether the stored credential could not be read. Saving replaces it outright, so
    /// there is then nothing to fall back on for a field the user leaves empty.
    @State private var didFailToLoadStoredCredential = false
    /// The method a backend switch installed, pending its change handler. See
    /// `onChange(of: authMethod)`.
    @State private var backendNormalizedAuthMethod: AuthMethod?
    /// Whether the user has chosen a different auth method, which is the one thing that
    /// gives up the saved credential for good.
    @State private var didDiscardSavedCredential = false
    @State private var currentTestTask: Task<Void, Never>?
    @State private var oauthAuthorizationTask: Task<Void, Never>?
    @State private var isAuthorizingOAuth = false

    private let existingID: UUID?
    private let draftID: UUID
    /// The key path this mount was saved with, so a save that cannot re-read the file can
    /// tell "the same key as before" from "a key the user just pointed us at".
    private let savedPrivateKeyPath: String
    private let savedPrivateKeyBookmark: String
    /// The account this mount was saved against, restored with its token. See
    /// `restoreSavedSecretsForCurrentTarget()`.
    private let savedOAuthAccountName: String
    private let savedOAuthAccountEmail: String
    /// The server this mount was saved against. See `savedCredentialForCurrentTarget`.
    private let savedServerIdentity: ServerIdentity
    /// The backend the stored credential was issued for. See
    /// `savedCredentialForCurrentTarget`.
    private let savedBackendType: BackendType?
    private let onSave: (ConnectionConfig, Credential) -> Void

    init(config: ConnectionConfig?, onSave: @escaping (ConnectionConfig, Credential) -> Void) {
        self.existingID = config?.id
        self.draftID = config?.id ?? UUID()
        self.savedPrivateKeyPath = config?.parameters["privateKeyPath"] ?? ""
        self.savedPrivateKeyBookmark = config?.parameters["privateKeyBookmark"] ?? ""
        self.savedOAuthAccountName = config?.parameters["oauthAccountName"] ?? ""
        self.savedOAuthAccountEmail = config?.parameters["oauthAccountEmail"] ?? ""
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
        let initialPort = config.map { existing in
            existing.backendType.usesHostBasedAddressing
                ? "\(existing.port)"
                : "\(existing.backendType.defaultPort)"
        } ?? ""
        _port = State(initialValue: initialPort)
        _username = State(initialValue: config?.username ?? "")
        // Normalized on open, not just on a backend switch: a config carrying a method its
        // backend does not support — written by an older build, or synced from one — has no
        // row in the picker to correct it, so it would be saved and tested as-is. An S3
        // mount stuck on `.password` saves with no access keys and then fails every time.
        let initialAuthMethod = config.map { existing in
            existing.backendType.supportedAuthMethods.contains(existing.authMethod)
                ? existing.authMethod
                : existing.backendType.supportedAuthMethods.first ?? existing.authMethod
        } ?? .password
        _authMethod = State(initialValue: initialAuthMethod)
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
        let initialS3Endpoint = config?.s3Endpoint ?? params["endpoint"] ?? ""
        _s3Endpoint = State(initialValue: initialS3Endpoint)
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
        // Built from the same values the fields above start with, so "back where it
        // started" is decided by exactly what the user sees.
        self.savedServerIdentity = Self.serverIdentity(
            backendType: config?.backendType ?? .sftp,
            usesUsername: (config?.backendType.usesUsername ?? false) && initialAuthMethod != .anonymous,
            values: ServerIdentityValues(
                host: config?.host ?? "",
                port: initialPort,
                username: config?.username ?? "",
                s3Endpoint: initialS3Endpoint,
                s3Bucket: params["bucket"] ?? "",
                s3Region: params["region"] ?? "us-east-1",
                s3PathStyle: params["pathStyle"] == "true",
                smbShare: params["share"] ?? "",
                smbDomain: params["domain"] ?? "",
                webdavTLS: params["tls"] != "false",
                ftpTLS: params["tls"] == "true",
                gdClientID: params["clientID"] ?? "",
                gdRedirectURI: params["redirectURI"] ?? ""
            )
        )
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
                        // …and put the saved one back when the picker lands where it came
                        // from. Without this a round trip left the field empty with Save
                        // still enabled, and saving wrote that emptiness over a working
                        // password.
                        restoreSavedSecretsForCurrentTarget()
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
                        // Google Drive signs in here too, from the sheet's own OAuth client
                        // fields. It used to promise a prompt "after saving" that nothing in
                        // the app ever issued, so a new mount was saved with no token and
                        // could never connect.
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
                                .disabled(isAuthorizingOAuth || !canAuthorizeOAuthAccount)

                                if isAuthorizingOAuth {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
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
        .onChange(of: serverIdentity) { _, _ in
            // A secret belongs to the server it was issued for, and these fields are what
            // name that server. Editing one — a host, an S3 endpoint, a Google OAuth client
            // — points the mount at a different party, and the password or token already on
            // screen would otherwise be saved and sent there. Clearing is visible: the field
            // empties, so what is saved is what the user can see.
            //
            // Restored when the fields name the saved server again, so correcting a typo
            // does not cost the credential this sheet cannot load a second time.
            clearEnteredSecrets()
            // The token a sign-in in this sheet produced goes with them: Google Drive's
            // OAuth client is one of the fields above, so a token authorized against the
            // client that was there before would otherwise be saved for the one there now,
            // and an authorization still running would deliver one to it.
            clearOAuthAuthorizationState()
            restoreSavedSecretsForCurrentTarget()
        }
        .onChange(of: authMethod) { _, newMethod in
            // A method the backend switch installed is not a choice about credentials: the
            // switch already cleared everything on screen, and destroying the saved
            // credential here as well would make a round trip through the picker — Google
            // Drive to SFTP and back — lose a refresh token this sheet cannot load again,
            // and then write the emptiness over it on save. `savedCredentialForCurrentTarget`
            // is what keeps it from reaching the wrong backend meanwhile.
            if backendNormalizedAuthMethod == newMethod {
                backendNormalizedAuthMethod = nil
                return
            }
            // Recorded so a load still in flight does not put back what this discards.
            didDiscardSavedCredential = true
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
        // Trimmed, because what is saved is: `makeConfig` trims the host, `sanitizeName`
        // builds the symlink filename from the name, and `ConnectionConfig.s3Bucket` reads
        // a whitespace-only bucket as none at all. Accepting one here let the user save a
        // mount whose row shows nothing and whose backend is handed a blank address.
        guard !Self.isBlank(name) else { return false }
        // A credential that could not be read cannot be kept, and Save writes whatever the
        // fields hold over it. See `loadStoredCredentialIfNeeded`.
        guard !didFailToLoadStoredCredential || hasEnteredCredential else { return false }
        if backendType == .googleDrive {
            // Trimmed, because `buildParameters` stores the trimmed value and the backend
            // refuses a blank one: a whitespace-only client id saved as configured, and
            // every token refresh then failed on it.
            //
            // The account counts as much as the fields do. Saving without one produced a
            // mount whose every connect fails on a missing token, and nothing in the app
            // asked for the sign-in it was waiting for.
            return !Self.isBlank(gdClientID)
                && !Self.isBlank(gdRedirectURI)
                && hasConnectedOAuthAccount
        }
        if usesBundledOAuthFlow {
            return hasConnectedOAuthAccount
        }
        if backendType == .s3 {
            let hasRequiredAccessKeyCredentials =
                authMethod != .accessKey || (!s3AccessKeyID.isEmpty && !s3SecretAccessKey.isEmpty)
            return !Self.isBlank(s3Bucket)
                && hasValidPort
                && hasValidS3Endpoint
                && hasRequiredAccessKeyCredentials
        }
        // A password mount saves the field as the credential outright, so an empty one is
        // stored as the secret and every connection then fails on it. The S3 keys above
        // are required for the same reason.
        if authMethod == .password, password.isEmpty {
            return false
        }
        return !backendType.requiresServerEndpoint || (!Self.isBlank(host) && hasValidPort)
    }

    /// A port the backends can dial. Zero parses and is persisted, but every host-based
    /// backend hands `config.port` straight to its client, where it is not an address.
    private var hasValidPort: Bool {
        guard !port.isEmpty else { return true }
        guard let parsed = UInt16(port) else { return false }
        return parsed != 0
    }

    /// A custom endpoint the S3 backend can address, or none at all.
    ///
    /// Soto is handed this string as its endpoint and `ConnectionConfig` folds a legacy
    /// port into it through `URLComponents`; neither can do anything with a value that is
    /// not an http(s) URL, so saving one produces a mount that cannot connect and a row
    /// whose address renders as the bucket alone.
    private var hasValidS3Endpoint: Bool {
        let trimmed = s3Endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            return false
        }
        return true
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the form itself carries the secret this mount needs, rather than relying on
    /// the stored one.
    ///
    /// Only consulted when that stored one could not be read: every method here is filled
    /// from it on open, so an empty field then means the save would write emptiness over a
    /// working secret. The OAuth backends have no field to fill, so only a sign-in run in
    /// this sheet can stand in for the credential it could not read.
    private var hasEnteredCredential: Bool {
        switch authMethod {
        case .password:
            return !password.isEmpty
        case .publicKey:
            return !privateKeyPath.isEmpty
        case .accessKey:
            return !s3AccessKeyID.isEmpty && !s3SecretAccessKey.isEmpty
        case .agent, .anonymous:
            return true
        case .oauth:
            return hasConnectedOAuthAccount
        }
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
            oauthToken: (oauthCredential ?? savedCredentialForCurrentTarget)?.token
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
                   let savedPrivateKey = savedCredentialForCurrentTarget?.privateKey {
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
            // Google Drive keeps its refresh token in `password` and has no field for
            // either half, so a credential rebuilt from what the editor shows would drop
            // both. A sign-in run in this sheet wins; otherwise the stored one is passed
            // through untouched.
            guard let oauthCredential else {
                return savedCredentialForCurrentTarget ?? Credential()
            }
            // Google issues a refresh token on the first consent and may withhold it on a
            // later one. Dropping the stored one then would leave a mount that works until
            // the access token expires and can never renew it.
            guard oauthCredential.password == nil,
                  let savedRefreshToken = savedCredentialForCurrentTarget?.password else {
                return oauthCredential
            }
            return Credential(password: savedRefreshToken, token: oauthCredential.token)
        }
    }

    @MainActor
    private func loadStoredCredentialIfNeeded() async {
        guard !didLoadStoredCredential, let existingID else { return }
        didLoadStoredCredential = true
        isLoadingStoredCredential = true
        defer { isLoadingStoredCredential = false }

        // The sheet stays on screen across this await — every address field included, none
        // of which is disabled — so what the credential belongs to has to be pinned before
        // it. Applying it to a backend or method the user has since switched to is not
        // merely wrong: a Google Drive refresh token lives in `password`, so a switch to
        // SFTP would drop it into the password field, and the next save would store it as
        // one. Pointing the form at another host is the same mistake with the secret
        // intact — it would then be saved, and tested, against a server it was never
        // issued for.
        let requestedCredentialTarget = credentialTarget

        let credential: Credential?
        do {
            credential = try await credentialProvider.credential(for: existingID)
        } catch {
            // Saving replaces the stored credential outright, so a load this sheet
            // silently swallowed would let an empty field wipe a working secret. Said
            // instead, and Save is held until the fields carry a credential of their own —
            // there is nothing here to keep the stored one with.
            didFailToLoadStoredCredential = true
            testResult = AppL10n.string(
                "editor.error.loadStoredCredential",
                fallback: "Could not read the saved credential: %@. Enter it again to save; what is entered here replaces it.",
                error.localizedDescription
            )
            testSuccess = false
            return
        }
        guard let credential else { return }

        // Kept even when the form has moved on, and whatever the method is: this credential
        // belongs to the mount as it was opened, and `savedCredentialForCurrentTarget` is
        // what decides when it may be used again. Discarding it here made an address the
        // user was midway through editing cost the credential outright — putting the field
        // back could restore nothing, and Save then wrote an empty one over a working
        // secret. The one thing that does discard it is the user choosing another auth
        // method, which is what `clearCredentialState(except:)` is for.
        if !didDiscardSavedCredential, storedCredential == nil {
            storedCredential = credential
        }

        // The visible fields are only filled when the form still describes what was
        // loaded; anything else would drop one server's secret into a form naming another.
        guard credentialTarget == requestedCredentialTarget else { return }

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
            if usesBundledOAuthFlow {
                // Only when nothing newer is there. `Connect Account` stays enabled while
                // this load is in flight — it is gated on the authorization, not on the
                // read — so an authorization that finished first would have its token
                // replaced here by the one it was meant to supersede, and the save would
                // write that older one back.
                if oauthCredential == nil {
                    oauthCredential = credential
                }
            }
        case .agent, .anonymous:
            break
        }
    }

    /// The server a secret would be sent to, as the fields currently name it.
    private var serverIdentity: ServerIdentity {
        Self.serverIdentity(
            backendType: backendType,
            usesUsername: usesUsernameField,
            values: ServerIdentityValues(
                host: host,
                port: port,
                username: username,
                s3Endpoint: s3Endpoint,
                s3Bucket: s3Bucket,
                s3Region: s3Region,
                s3PathStyle: s3PathStyle,
                smbShare: smbShare,
                smbDomain: smbDomain,
                webdavTLS: webdavTLS,
                ftpTLS: ftpTLS,
                gdClientID: gdClientID,
                gdRedirectURI: gdRedirectURI
            )
        )
    }

    /// Only the fields the selected backend actually addresses by.
    ///
    /// The others still hold whatever a detour through another backend left in them —
    /// a bucket typed while S3 was selected, say — and counting those would make an SFTP
    /// mount look like it had moved to a different server, leaving its saved credential
    /// unrestorable and Save ready to write an empty one over it. `makeConfig` drops the
    /// same fields for the same reason.
    private static func serverIdentity(
        backendType: BackendType,
        usesUsername: Bool,
        values: ServerIdentityValues
    ) -> ServerIdentity {
        let usesHostBasedAddressing = backendType.usesHostBasedAddressing
        return ServerIdentity(
            host: usesHostBasedAddressing
                ? values.host.trimmingCharacters(in: .whitespacesAndNewlines)
                : "",
            // Read the way `makeConfig` reads it, not as typed: "22", "022" and a value
            // too malformed to parse all reach the same server, and treating them as
            // different ones clears the loaded credential for an address that never moved
            // — then leaves Save to write the emptiness over it.
            port: usesHostBasedAddressing
                ? String(UInt16(values.port) ?? backendType.defaultPort)
                : "",
            username: usesUsername ? values.username : "",
            // Resolved the way `addressesSameServer` resolves them, not as typed: a port
            // that only repeats the scheme's default reaches the same endpoint, and a
            // bucket or region differs from itself by the whitespace `ConnectionConfig`
            // trims off before the backend ever sees it. Comparing the raw strings cleared
            // the loaded access keys for an address that never moved, and left Save to
            // write the emptiness over them.
            s3Endpoint: backendType == .s3
                ? ConnectionConfig.comparableS3Endpoint(
                    ConnectionConfig.trimmedParameter(values.s3Endpoint)
                ) ?? ""
                : "",
            s3Bucket: backendType == .s3
                ? ConnectionConfig.trimmedParameter(values.s3Bucket) ?? ""
                : "",
            s3Region: backendType == .s3
                ? ConnectionConfig.trimmedParameter(values.s3Region) ?? ConnectionConfig.defaultS3Region
                : "",
            smbShare: backendType == .smb ? values.smbShare : "",
            smbDomain: backendType == .smb ? values.smbDomain : "",
            // Trimmed for the same reason the S3 fields above are: `buildParameters` stores
            // the trimmed value, so whitespace around either of them names the same OAuth
            // client the mount was saved against.
            gdClientID: backendType == .googleDrive
                ? values.gdClientID.trimmingCharacters(in: .whitespacesAndNewlines)
                : "",
            gdRedirectURI: backendType == .googleDrive
                ? values.gdRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
                : "",
            transport: transportIdentity(backendType: backendType, values: values)
        )
    }

    /// The transport the secret would travel over, for the backends whose editor exposes a
    /// choice about it.
    ///
    /// Turning WebDAV's or FTP's TLS off does not move the mount to another host, but it
    /// hands the password to a cleartext channel to the same one — and S3's addressing
    /// style decides whether the request is signed for `bucket.endpoint` or for
    /// `endpoint/bucket`. A saved credential belongs to none of those by default, so each
    /// counts as naming a different party.
    private static func transportIdentity(
        backendType: BackendType,
        values: ServerIdentityValues
    ) -> String {
        switch backendType {
        case .webdav:
            return values.webdavTLS ? "https" : "http"
        case .ftp:
            return values.ftpTLS ? "ftps" : "ftp"
        case .s3:
            // Read the way `buildParameters` writes it: path style is persisted only
            // alongside a custom endpoint, so counting the toggle without one would clear
            // the access keys for a change that never reaches the config.
            let hasCustomEndpoint = !values.s3Endpoint
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            return values.s3PathStyle && hasCustomEndpoint ? "path-style" : "virtual-host"
        default:
            return ""
        }
    }

    /// Everything that decides *which server* a secret would be sent to, the backend and
    /// method included.
    ///
    /// The credential load suspends while all of it stays editable, so this is what its
    /// result has to be checked against — a password belongs to a host, not merely to a
    /// backend and a method.
    private var credentialTarget: CredentialTarget {
        CredentialTarget(
            backendType: backendType,
            authMethod: authMethod,
            server: serverIdentity
        )
    }

    /// Put back what this mount was saved with, once the picker lands on the backend it
    /// was saved for.
    ///
    /// Clearing on the way out is what stops a secret reaching another server; leaving it
    /// cleared on the way back would leave Save enabled over an empty field, and writing
    /// that emptiness destroys a working credential.
    private func restoreSavedSecretsForCurrentTarget() {
        guard let credential = savedCredentialForCurrentTarget else { return }
        switch authMethod {
        case .password:
            password = credential.password ?? ""
        case .publicKey:
            password = credential.passphrase ?? ""
            privateKeyPath = savedPrivateKeyPath
            privateKeyBookmark = savedPrivateKeyBookmark
        case .accessKey:
            s3AccessKeyID = credential.accessKeyID ?? ""
            s3SecretAccessKey = credential.secretAccessKey ?? ""
        case .oauth:
            // `clearOAuthAuthorizationState()` drops the token on the way out, and the
            // bundled flows read *only* `oauthCredential` to decide whether an account is
            // connected — so without this a round trip through the picker left Save and
            // Test disabled on a mount whose stored token is right here, demanding a
            // re-authorization for nothing. The account labels come back with it, or a
            // save would drop them from the config.
            guard usesBundledOAuthFlow, oauthCredential == nil else { return }
            oauthCredential = credential
            oauthAccountName = savedOAuthAccountName
            oauthAccountEmail = savedOAuthAccountEmail
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
    /// describes the server it was saved against.
    ///
    /// It survives a round trip through the picker or a retyped host — that is what keeps
    /// a Google Drive refresh token from being destroyed by one — but what one server
    /// issued must never be built into the credential written for another.
    private var savedCredentialForCurrentTarget: Credential? {
        guard backendType == savedBackendType, serverIdentity == savedServerIdentity else {
            return nil
        }
        return storedCredential
    }

    /// Drop the credential state an explicit change of method leaves behind.
    ///
    /// `password` goes with the rest, and that is the point: the account password and the
    /// key passphrase are one field of state behind two labels, so leaving it in place
    /// carried an SFTP password into the passphrase — where `buildCredential()` would sign
    /// a key with it — and a passphrase back out as the server password. Only what the
    /// chosen method has its own fields for is kept.
    private func clearCredentialState(except method: AuthMethod) {
        password = ""
        storedCredential = nil
        privateKeyPath = ""
        privateKeyBookmark = ""
        s3AccessKeyID = ""
        s3SecretAccessKey = ""
        if method != .oauth {
            oauthCredential = nil
            oauthAccountName = ""
            oauthAccountEmail = ""
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
            // Trimmed, and rejected when nothing is left: the backend tests these for
            // emptiness before it refreshes a token, so a whitespace-only value was saved
            // as a configured client and failed every refresh afterwards.
            let trimmedClientID = gdClientID.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedRedirectURI = gdRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedClientID.isEmpty, !trimmedRedirectURI.isEmpty else {
                throw RemoteFileSystemError.operationFailed(
                    AppL10n.string(
                        "editor.error.googleDriveOAuthFieldsRequired",
                        fallback: "Google Drive requires both OAuth Client ID and Redirect URI"
                    )
                )
            }
            params["clientID"] = trimmedClientID
            params["redirectURI"] = trimmedRedirectURI
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
        // Google Drive: the sign-in this sheet just ran, or the token the mount was already
        // saved with — reopening a working mount must not demand a new authorization.
        return (oauthCredential ?? savedCredentialForCurrentTarget)?.token?.isEmpty == false
    }

    /// Whether the sheet holds what the sign-in needs.
    ///
    /// The bundled flows carry their own client; Google Drive is authorized against the
    /// client the user types into this sheet, so there is nothing to authorize against
    /// until both fields are filled.
    private var canAuthorizeOAuthAccount: Bool {
        guard backendType == .googleDrive else { return true }
        return !Self.isBlank(gdClientID) && !Self.isBlank(gdRedirectURI)
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
        case .googleDrive:
            // Authorized against the client the sheet holds, trimmed the way
            // `buildParameters` stores it, so the token belongs to the client that is saved.
            let provider = GoogleOAuthProvider(
                clientID: gdClientID.trimmingCharacters(in: .whitespacesAndNewlines),
                redirectURI: gdRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let token = try await provider.authorize()
            // Split the way the backend reads them: `token` is the access token it presents,
            // `password` the refresh token it renews with. Google returns no profile with
            // either, so the account has no name to show.
            return OAuthAuthorizationResult(
                credential: Credential(
                    password: token.refreshToken,
                    token: token.accessToken
                ),
                displayName: "",
                email: nil
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

/// The address fields as the sheet currently holds them, before the selected backend
/// decides which of them mean anything.
private struct ServerIdentityValues {
    let host: String
    let port: String
    let username: String
    let s3Endpoint: String
    let s3Bucket: String
    let s3Region: String
    let s3PathStyle: Bool
    let smbShare: String
    let smbDomain: String
    let webdavTLS: Bool
    let ftpTLS: Bool
    let gdClientID: String
    let gdRedirectURI: String
}

/// The fields that name the server a secret would be sent to.
private struct ServerIdentity: Equatable {
    let host: String
    let port: String
    let username: String
    let s3Endpoint: String
    let s3Bucket: String
    let s3Region: String
    let smbShare: String
    let smbDomain: String
    let gdClientID: String
    let gdRedirectURI: String
    /// How the selected backend reaches that server, where the choice decides what the
    /// secret is handed to: WebDAV's and FTP's transports, and S3's request addressing.
    let transport: String
}

/// That server plus how the mount authenticates to it — what a stored credential belongs
/// to, in full.
private struct CredentialTarget: Equatable {
    let backendType: BackendType
    let authMethod: AuthMethod
    let server: ServerIdentity
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
