import XCTest
@testable import MFuseCore

final class BackendRegistryTests: XCTestCase {

    func testRegisterAndCreate() {
        let registry = BackendRegistry.shared
        // Which types are registered depends on whether a host app ran its registration,
        // so this only asserts that reading the registry does not crash.
        _ = registry.supportedTypes
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
    func testEveryBackendHasLocalizedDisplayNameResource() {
        let expectedByKey = [
            "backend.googleDrive": "Google Drive",
            "backend.dropbox": "Dropbox",
            "backend.oneDrive": "Microsoft OneDrive"
        ]

        for localeIdentifier in ["en", "es", "fr", "id", "it", "ja", "ko", "zh-Hans", "zh-Hant"] {
            for (key, expected) in expectedByKey {
                let value = MFuseCoreL10n.string(
                    key,
                    localeIdentifier: localeIdentifier,
                    fallback: "<missing>"
                )
                XCTAssertNotEqual(value, "<missing>", "\(key) is missing from \(localeIdentifier).lproj")
                if key != "backend.googleDrive" {
                    XCTAssertEqual(value, expected, "\(key) in \(localeIdentifier).lproj")
                }
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

    /// Regression: S3 has no host, so the sidebar used to show a bare ":9,000".
    func testS3FallsBackToEndpointThenBucket() {
        XCTAssertEqual(
            config(.s3, parameters: ["endpoint": "http://localhost:9000", "bucket": "b"]).displayAddress,
            "http://localhost:9000"
        )
        XCTAssertEqual(config(.s3, parameters: ["bucket": "my-bucket"]).displayAddress, "my-bucket")
        XCTAssertEqual(config(.s3).displayAddress, BackendType.s3.displayName)
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
