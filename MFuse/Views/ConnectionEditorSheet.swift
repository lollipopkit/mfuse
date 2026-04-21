import SwiftUI
import MFuseCore

struct ConnectionEditorSheet: View {

    @Environment(\.dismiss) private var dismiss

    // Editing state
    @State private var name: String
    @State private var backendType: BackendType
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var authMethod: AuthMethod
    @State private var remotePath: String
    @State private var password: String = ""
    @State private var oauthToken: String = ""
    @State private var privateKeyPath: String = ""

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
    @State private var testResult: String?
    @State private var testSuccess = false
    @State private var didLoadStoredCredential = false

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
        // Backend-specific parameters
        let params = config?.parameters ?? [:]
        _privateKeyPath = State(initialValue: params["privateKeyPath"] ?? "")
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
                Text(existingID != nil ? "Edit Connection" : "New Connection")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            // Form
            Form {
                Section("General") {
                    TextField("Name", text: $name, prompt: Text("My Server"))
                    Picker("Type", selection: $backendType) {
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
                }

                // Hide host/port for Google Drive (cloud-only)
                if backendType != .googleDrive {
                    Section("Server") {
                        if backendType != .s3 {
                            TextField("Host", text: $host, prompt: Text("example.com"))
                        }
                        TextField("Port", text: $port, prompt: Text("\(backendType.defaultPort)"))
                        if backendType != .s3 {
                            TextField("Username", text: $username, prompt: Text("user"))
                        }
                        TextField("Remote Path", text: $remotePath, prompt: Text("/"))
                    }
                }

                // Backend-specific parameters
                switch backendType {
                case .s3:
                    Section("S3 Settings") {
                        TextField("Bucket", text: $s3Bucket, prompt: Text("my-bucket"))
                        TextField("Region", text: $s3Region, prompt: Text("us-east-1"))
                        TextField("Custom Endpoint (optional)", text: $s3Endpoint, prompt: Text("https://s3.amazonaws.com"))
                        Toggle("Path-Style Access", isOn: $s3PathStyle)
                    }
                case .webdav:
                    Section("WebDAV Settings") {
                        Toggle("Use TLS (HTTPS)", isOn: $webdavTLS)
                    }
                case .smb:
                    Section("SMB Settings") {
                        TextField("Share Name", text: $smbShare, prompt: Text("shared"))
                        TextField("Domain (optional)", text: $smbDomain, prompt: Text("WORKGROUP"))
                    }
                case .ftp:
                    Section("FTP Settings") {
                        Toggle("Use TLS (FTPS)", isOn: $ftpTLS)
                        Toggle("Passive Mode", isOn: $ftpPassive)
                    }
                case .googleDrive:
                    Section("Google Drive Settings") {
                        TextField("OAuth Client ID", text: $gdClientID, prompt: Text("xxxx.apps.googleusercontent.com"))
                        TextField("Redirect URI", text: $gdRedirectURI, prompt: Text("com.lollipopkit.mfuse:/oauth"))
                    }
                default:
                    EmptyView()
                }

                Section("Authentication") {
                    let methods = backendType.supportedAuthMethods
                    if methods.count > 1 {
                        Picker("Method", selection: $authMethod) {
                            ForEach(methods, id: \.self) { method in
                                Text(method.rawValue.capitalized).tag(method)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    switch authMethod {
                    case .password:
                        SecureField("Password", text: $password)
                    case .publicKey:
                        HStack {
                            TextField("Private Key Path", text: $privateKeyPath)
                            Button("Browse…") { browseKeyFile() }
                                .controlSize(.small)
                        }
                        SecureField("Passphrase (optional)", text: $password)
                    case .agent:
                        Text("SSH Agent will be used for authentication.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .accessKey:
                        TextField("Access Key ID", text: $s3AccessKeyID)
                        SecureField("Secret Access Key", text: $s3SecretAccessKey)
                    case .anonymous:
                        Text("No credentials required.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .oauth:
                        Text("You will be prompted to sign in with Google after saving.")
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
                            Text("Credentials will be sent in cleartext. Enable TLS to encrypt your connection.")
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
                            Text(result)
                                .font(.caption)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // Buttons
            HStack {
                Button("Test Connection") { testConnection() }
                    .disabled(isTesting || !isValid)
                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
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
    }

    // MARK: - Validation

    private var isValid: Bool {
        !name.isEmpty && (
            if backendType == .googleDrive {
                true
            } else if backendType == .s3 {
                UInt16(port) != nil || port.isEmpty
            } else {
                !host.isEmpty && (UInt16(port) != nil || port.isEmpty)
            }
        )
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
                parameters: buildParameters()
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
        let config = ConnectionConfig(
            name: name,
            backendType: backendType,
            host: host,
            port: UInt16(port) ?? backendType.defaultPort,
            username: username,
            authMethod: authMethod,
            remotePath: remotePath.isEmpty ? "/" : remotePath,
            parameters: buildParameters()
        )
        let credential: Credential
        do {
            credential = try buildCredential()
        } catch {
            testResult = error.localizedDescription
            testSuccess = false
            isTesting = false
            return
        }

        Task {
            let storage = SharedStorage.withLegacyMigration()
            let keychain = KeychainService()
            let manager = await ConnectionManager(
                storage: storage,
                credentialProvider: keychain
            )
            let result = await manager.testConnection(config, credential: credential)
            await MainActor.run {
                switch result {
                case .success:
                    testResult = "Connection successful!"
                    testSuccess = true
                case .failure(let error):
                    testResult = error.localizedDescription
                    testSuccess = false
                }
                isTesting = false
            }
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
            let keyURL = URL(fileURLWithPath: privateKeyPath)
            do {
                let keyData = try Data(contentsOf: keyURL)
                return Credential(
                    password: nil,
                    privateKey: keyData,
                    passphrase: password.isEmpty ? nil : password
                )
            } catch {
                throw RemoteFileSystemError.operationFailed(
                    "Unable to read private key at \(privateKeyPath): \(error.localizedDescription)"
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

        let keychain = KeychainService()
        guard let credential = try? await keychain.credential(for: existingID) else { return }

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
            password = ""
            oauthToken = ""
            privateKeyPath = ""
            s3AccessKeyID = ""
            s3SecretAccessKey = ""
        case .publicKey:
            password = ""
            oauthToken = ""
            s3AccessKeyID = ""
            s3SecretAccessKey = ""
        case .agent, .anonymous:
            password = ""
            oauthToken = ""
            privateKeyPath = ""
            s3AccessKeyID = ""
            s3SecretAccessKey = ""
        case .accessKey:
            password = ""
            oauthToken = ""
            privateKeyPath = ""
        case .oauth:
            password = ""
            privateKeyPath = ""
            s3AccessKeyID = ""
            s3SecretAccessKey = ""
        }
    }

    private func buildParameters() -> [String: String] {
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
            if !gdClientID.isEmpty { params["clientID"] = gdClientID }
            if !gdRedirectURI.isEmpty { params["redirectURI"] = gdRedirectURI }
        default:
            break
        }
        if authMethod == .publicKey, !privateKeyPath.isEmpty {
            params["privateKeyPath"] = privateKeyPath
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
                }
            }
        }
    }
}
