import XCTest
@testable import MFuseCore

/// Minimal backend used to verify registry wiring without touching a network.
private actor StubFileSystem: RemoteFileSystem {
    let config: ConnectionConfig

    init(config: ConnectionConfig) {
        self.config = config
    }

    var isConnected: Bool { false }
    func connect() async throws {}
    func disconnect() async throws {}
    func enumerate(at path: RemotePath) async throws -> [RemoteItem] { [] }
    func itemInfo(at path: RemotePath) async throws -> RemoteItem {
        throw RemoteFileSystemError.notFound(path)
    }
    func readFile(at path: RemotePath) async throws -> Data { Data() }
    func writeFile(at path: RemotePath, data: Data) async throws {}
    func createFile(at path: RemotePath, data: Data) async throws {}
    func createDirectory(at path: RemotePath) async throws {}
    func delete(at path: RemotePath) async throws {}
    func move(from source: RemotePath, to destination: RemotePath) async throws {}
}

final class BackendRegistryTests: XCTestCase {

    private func config(_ type: BackendType) -> ConnectionConfig {
        ConnectionConfig(
            name: "Test",
            backendType: type,
            host: "localhost",
            port: type.defaultPort,
            username: "user",
            authMethod: type.supportedAuthMethods.first ?? .password,
            remotePath: "/"
        )
    }

    func testRegisterAndCreate() async {
        // A dedicated instance rather than the shared singleton, whose contents depend on
        // whether a host app already registered its backends.
        let registry = BackendRegistry()
        XCTAssertFalse(registry.isSupported(.sftp))
        XCTAssertNil(registry.createFileSystem(config: config(.sftp), credential: Credential()))

        registry.register(.sftp) { config, _ in StubFileSystem(config: config) }

        XCTAssertTrue(registry.isSupported(.sftp))
        XCTAssertEqual(registry.supportedTypes, [.sftp])

        let created = registry.createFileSystem(config: config(.sftp), credential: Credential())
        XCTAssertTrue(created is StubFileSystem)
        // An unregistered type must still resolve to nil.
        XCTAssertNil(registry.createFileSystem(config: config(.s3), credential: Credential()))
    }

    func testIsSupported() {
        let registry = BackendRegistry.shared
        // We can't guarantee registrations in unit tests without the app target,
        // but the API should not crash
        _ = registry.isSupported(.sftp)
        _ = registry.isSupported(.s3)
    }

    func testCreateFileSystemForUnregisteredType() {
        // Create a fresh registry-like test
        // BackendRegistry.shared is a singleton, so we test nil return for un-registered types
        // by checking with a type that might not be registered in test context
        let config = ConnectionConfig(
            name: "Test",
            backendType: .nfs,
            host: "localhost",
            port: 2049,
            username: "user",
            authMethod: .anonymous,
            remotePath: "/"
        )
        // In test context without app registration, this may return nil
        let fs = BackendRegistry.shared.createFileSystem(config: config, credential: Credential())
        // We just verify no crash — fs may or may not be nil depending on test setup
        _ = fs
    }
}

final class BackendTypeTests: XCTestCase {

    func testAllCases() {
        XCTAssertEqual(
            Set(BackendType.allCases),
            [.sftp, .s3, .webdav, .smb, .nfs, .ftp, .googleDrive, .dropbox, .oneDrive]
        )
    }

    func testDisplayName() {
        XCTAssertEqual(BackendType.sftp.displayName, "SFTP")
        XCTAssertEqual(BackendType.s3.displayName, "S3")
        XCTAssertEqual(BackendType.webdav.displayName, "WebDAV")
        XCTAssertEqual(BackendType.smb.displayName, "SMB")
        XCTAssertEqual(BackendType.nfs.displayName, "NFS")
        XCTAssertEqual(BackendType.ftp.displayName, "FTP")
        XCTAssertEqual(BackendType.googleDrive.displayName, "Google Drive")
    }

    func testLocalizedDisplayNamesFromBundle() {
        XCTAssertEqual(
            MFuseCoreL10n.string(
                "backend.googleDrive",
                localeIdentifier: "zh-CN",
                fallback: "Google Drive"
            ),
            "Google 云端硬盘"
        )
        XCTAssertEqual(
            MFuseCoreL10n.string(
                "backend.googleDrive",
                localeIdentifier: "fr",
                fallback: "Google Drive"
            ),
            "Google Drive"
        )
    }

    /// The fallbacks here deliberately differ from the expected values so a missing
    /// resource key fails the assertion instead of silently degrading to the fallback.
    ///
    /// Every locale asserts the actual value, including Google Drive's two translated
    /// names — checking only for presence would let a wrong provider name through.
    func testEveryBackendHasLocalizedDisplayNameResource() {
        let locales = ["en", "es", "fr", "id", "it", "ja", "ko", "zh-Hans", "zh-Hant"]
        let translatedGoogleDrive = [
            "zh-Hans": "Google 云端硬盘",
            "zh-Hant": "Google 雲端硬碟"
        ]

        for localeIdentifier in locales {
            let expectedByKey = [
                "backend.googleDrive": translatedGoogleDrive[localeIdentifier] ?? "Google Drive",
                "backend.dropbox": "Dropbox",
                "backend.oneDrive": "OneDrive"
            ]
            for (key, expected) in expectedByKey {
                let value = MFuseCoreL10n.string(
                    key,
                    localeIdentifier: localeIdentifier,
                    fallback: "<missing>"
                )
                XCTAssertNotEqual(value, "<missing>", "\(key) is missing from \(localeIdentifier).lproj")
                XCTAssertEqual(value, expected, "\(key) in \(localeIdentifier).lproj")
            }
        }
    }

    func testDefaultPort() {
        XCTAssertEqual(BackendType.sftp.defaultPort, 22)
        XCTAssertEqual(BackendType.s3.defaultPort, 443)
        XCTAssertEqual(BackendType.webdav.defaultPort, 443)
        XCTAssertEqual(BackendType.smb.defaultPort, 445)
        XCTAssertEqual(BackendType.nfs.defaultPort, 2049)
        XCTAssertEqual(BackendType.ftp.defaultPort, 21)
        XCTAssertEqual(BackendType.googleDrive.defaultPort, 443)
        XCTAssertEqual(BackendType.dropbox.defaultPort, 443)
        XCTAssertEqual(BackendType.oneDrive.defaultPort, 443)
    }

    func testIconName() {
        for type in BackendType.allCases {
            XCTAssertFalse(type.iconName.isEmpty, "\(type) should have an icon name")
        }
    }

    func testSupportedAuthMethods() {
        XCTAssertTrue(BackendType.sftp.supportedAuthMethods.contains(.password))
        XCTAssertTrue(BackendType.sftp.supportedAuthMethods.contains(.publicKey))
        XCTAssertTrue(BackendType.s3.supportedAuthMethods.contains(.accessKey))
        XCTAssertTrue(BackendType.googleDrive.supportedAuthMethods.contains(.oauth))
        XCTAssertTrue(BackendType.ftp.supportedAuthMethods.contains(.anonymous))

        for type in BackendType.allCases {
            XCTAssertFalse(type.supportedAuthMethods.isEmpty, "\(type) should have at least one auth method")
        }
    }

    func testCodableRoundTrip() throws {
        for type in BackendType.allCases {
            let data = try JSONEncoder().encode(type)
            let decoded = try JSONDecoder().decode(BackendType.self, from: data)
            XCTAssertEqual(type, decoded)
        }
    }

    func testIdentifiable() {
        for type in BackendType.allCases {
            XCTAssertEqual(type.id, type.rawValue)
        }
    }

    func testAuthMethodDisplayNameUsesLocalizationResources() {
        XCTAssertEqual(
            AuthMethod.password.displayName,
            MFuseCoreL10n.string(
                "auth.password",
                localeIdentifier: "en",
                fallback: "Password"
            )
        )
        XCTAssertEqual(
            MFuseCoreL10n.string(
                "auth.publicKey",
                localeIdentifier: "zh-CN",
                fallback: "Public Key"
            ),
            "公钥"
        )
    }

    func testConnectionAndMountStatusFormatting() {
        XCTAssertEqual(
            MFuseCoreL10n.string(
                "connection.error",
                localeIdentifier: "en",
                fallback: "Error: %@",
                "boom"
            ),
            "Error: boom"
        )
        XCTAssertEqual(
            MFuseCoreL10n.string(
                "mount.error.status",
                localeIdentifier: "zh-CN",
                fallback: "Mount error: %@",
                "失败"
            ),
            "挂载错误：失败"
        )
    }

    /// The connection lifecycle messages are the only report of a failed removal or
    /// rollback, so a locale missing one — or dropping a positional placeholder — would
    /// leave the user with an unusable error.
    func testConnectionManagerErrorResourcesExistInEveryLocale() {
        let placeholderCounts = [
            "connectionManager.error.cleanupFailed": 1,
            "connectionManager.error.restoreRemovedConnection": 1,
            "connectionManager.error.restoreCredential": 1,
            "connectionManager.error.deleteCredentialWithRestoreFailures": 3,
            "connectionManager.error.deleteCredentialRecovered": 2,
            "connectionManager.error.unsupportedBackend": 1
        ]
        let locales = ["en", "es", "fr", "id", "it", "ja", "ko", "zh-Hans", "zh-Hant"]

        for locale in locales {
            for (key, expectedPlaceholders) in placeholderCounts {
                let sentinel = "<missing>"
                let template = MFuseCoreL10n.string(key, localeIdentifier: locale, fallback: sentinel)
                XCTAssertNotEqual(template, sentinel, "\(key) is missing for \(locale)")
                XCTAssertFalse(template.isEmpty, "\(key) is empty for \(locale)")
                XCTAssertEqual(
                    template.components(separatedBy: "%").count - 1,
                    expectedPlaceholders,
                    "\(key) has the wrong number of placeholders for \(locale)"
                )
            }
        }
    }

    func testLocalizedErrorsAreNonEmpty() {
        XCTAssertFalse(RemoteFileSystemError.notConnected.localizedDescription.isEmpty)
        XCTAssertFalse(MountError.extensionNotEnabled.localizedDescription.isEmpty)
        XCTAssertFalse(ConnectionManagerError.cleanupFailed(UUID()).localizedDescription.isEmpty)
    }
}

final class ConnectionConfigDisplayAddressTests: XCTestCase {

    private func config(
        _ type: BackendType,
        host: String = "",
        port: UInt16? = nil,
        parameters: [String: String] = [:]
    ) -> ConnectionConfig {
        ConnectionConfig(
            name: "Test",
            backendType: type,
            host: host,
            port: port ?? type.defaultPort,
            username: "user",
            authMethod: type.supportedAuthMethods.first ?? .password,
            remotePath: "/",
            parameters: parameters
        )
    }

    /// Regression: the sidebar rendered "\(host):\(port)" through SwiftUI's localized
    /// string interpolation, which formatted 9000 as "9,000".
    func testNonDefaultPortIsRenderedWithoutGroupingSeparator() {
        let address = config(.sftp, host: "localhost", port: 2222).displayAddress
        XCTAssertEqual(address, "localhost:2222")
        XCTAssertFalse(address.contains(","))
    }

    func testDefaultPortIsOmitted() {
        XCTAssertEqual(config(.sftp, host: "example.com", port: 22).displayAddress, "example.com")
    }

    /// A stored host of pure whitespace is nothing to show, so it must fall back like an
    /// empty one instead of rendering blanks or a bare ":2222".
    func testBlankHostFallsBackToTheBackendName() {
        XCTAssertEqual(config(.sftp, host: "   ").displayAddress, BackendType.sftp.displayName)
        XCTAssertEqual(
            config(.sftp, host: "   ", port: 2222).displayAddress,
            BackendType.sftp.displayName
        )
        XCTAssertEqual(config(.sftp, host: "  example.com  ").displayAddress, "example.com")
    }

    /// An IPv6 literal is all colons, so the port has to be told apart with brackets.
    func testIPv6HostIsBracketedBeforeThePort() {
        XCTAssertEqual(config(.sftp, host: "2001:db8::1", port: 2222).displayAddress, "[2001:db8::1]:2222")
        XCTAssertEqual(config(.sftp, host: "[2001:db8::1]", port: 2222).displayAddress, "[2001:db8::1]:2222")
        XCTAssertEqual(config(.sftp, host: "2001:db8::1", port: 22).displayAddress, "2001:db8::1")
    }

    /// Regression: S3 has no host, so the sidebar used to show a bare ":9,000".
    func testS3FallsBackToEndpointThenBucket() {
        XCTAssertEqual(
            config(.s3, parameters: ["endpoint": "http://localhost:9000", "bucket": "b"]).displayAddress,
            "http://localhost:9000"
        )
        XCTAssertEqual(config(.s3, parameters: ["bucket": "my-bucket"]).displayAddress, "my-bucket")
        XCTAssertEqual(config(.s3).displayAddress, BackendType.s3.displayName)
    }

    /// What is displayed must match what the backend connects to, including for configs
    /// that still carry the port outside the endpoint.
    func testS3DisplayAddressShowsTheEffectiveEndpoint() {
        XCTAssertEqual(
            config(.s3, port: 9000, parameters: ["endpoint": "http://localhost"]).displayAddress,
            "http://localhost:9000"
        )
    }

    func testS3EndpointAppliesConfiguredPortOnlyWhenItAddsInformation() {
        XCTAssertEqual(
            ConnectionConfig.s3Endpoint("http://localhost", applyingConfiguredPort: 9000),
            "http://localhost:9000"
        )
        XCTAssertEqual(
            ConnectionConfig.s3Endpoint("http://localhost:9000", applyingConfiguredPort: 443),
            "http://localhost:9000"
        )
        XCTAssertEqual(
            ConnectionConfig.s3Endpoint("https://s3.amazonaws.com", applyingConfiguredPort: 443),
            "https://s3.amazonaws.com"
        )
        XCTAssertEqual(
            ConnectionConfig.s3Endpoint("http://minio.internal", applyingConfiguredPort: 80),
            "http://minio.internal"
        )
        // Regression: a new S3 config keeps the backend default port because the editor
        // no longer offers the field, so it must not be written onto a plain-HTTP endpoint.
        XCTAssertEqual(
            ConnectionConfig.s3Endpoint(
                "http://localhost",
                applyingConfiguredPort: BackendType.s3.defaultPort
            ),
            "http://localhost"
        )
        XCTAssertEqual(
            ConnectionConfig.s3Endpoint("not a url", applyingConfiguredPort: 9000),
            "not a url"
        )
    }

    func testOAuthBackendsShowAccountInsteadOfEmptyHost() {
        XCTAssertEqual(
            config(.dropbox, parameters: ["oauthAccountEmail": "a@b.com"]).displayAddress,
            "a@b.com"
        )
        XCTAssertEqual(config(.oneDrive).displayAddress, BackendType.oneDrive.displayName)
    }

    func testNoBackendRendersEmptyOrBareColon() {
        for type in BackendType.allCases {
            let address = config(type).displayAddress
            XCTAssertFalse(address.isEmpty, "\(type) should have a display address")
            XCTAssertFalse(address.hasPrefix(":"), "\(type) rendered a bare port")
        }
    }
}

final class ConnectionConfigSubtitleTests: XCTestCase {

    private func config(_ type: BackendType, host: String = "", parameters: [String: String] = [:]) -> ConnectionConfig {
        ConnectionConfig(
            name: "Test",
            backendType: type,
            host: host,
            port: type.defaultPort,
            username: "user",
            authMethod: type.supportedAuthMethods.first ?? .password,
            remotePath: "/",
            parameters: parameters
        )
    }

    func testSubtitleCombinesTypeAndAddress() {
        XCTAssertEqual(config(.sftp, host: "example.com").displaySubtitle, "SFTP · example.com")
    }

    /// The type must not be printed twice when displayAddress already fell back to it.
    func testSubtitleDoesNotRepeatTypeWhenAddressIsUnknown() {
        XCTAssertEqual(config(.dropbox).displaySubtitle, BackendType.dropbox.displayName)
        XCTAssertEqual(config(.s3).displaySubtitle, BackendType.s3.displayName)
    }
}
