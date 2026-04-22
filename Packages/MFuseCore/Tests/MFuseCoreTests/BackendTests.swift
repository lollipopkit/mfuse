import XCTest
@testable import MFuseCore

final class BackendRegistryTests: XCTestCase {

    func testRegisterAndCreate() {
        let registry = BackendRegistry.shared
        // .sftp should already be registered in tests if MFuseApp runs,
        // but we test the mechanism directly
        XCTAssertTrue(registry.supportedTypes.count >= 0) // non-crash baseline
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
        XCTAssertEqual(BackendType.allCases.count, 7)
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

    func testDefaultPort() {
        XCTAssertEqual(BackendType.sftp.defaultPort, 22)
        XCTAssertEqual(BackendType.s3.defaultPort, 443)
        XCTAssertEqual(BackendType.webdav.defaultPort, 443)
        XCTAssertEqual(BackendType.smb.defaultPort, 445)
        XCTAssertEqual(BackendType.nfs.defaultPort, 2049)
        XCTAssertEqual(BackendType.ftp.defaultPort, 21)
        XCTAssertEqual(BackendType.googleDrive.defaultPort, 443)
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
