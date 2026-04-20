import XCTest
@testable import MFuseSFTP
import MFuseCore
final class SFTPFileSystemTests: XCTestCase {

    /// Test that SFTPFileSystem can be instantiated.
    func testInit() {
        let config = ConnectionConfig(
            name: "Test SFTP",
            backendType: .sftp,
            host: "example.com",
            port: 22,
            username: "testuser",
            authMethod: .password
        )
        let credential = Credential(password: "testpass")
        let fs = SFTPFileSystem(config: config, credential: credential)
        XCTAssertNotNil(fs)
    }

    /// Test that operations throw when not connected.
    func testNotConnectedThrows() async {
        let config = ConnectionConfig(
            name: "Test",
            backendType: .sftp,
            host: "nonexistent.invalid",
            username: "user"
        )
        let fs = SFTPFileSystem(config: config, credential: Credential(password: "pass"))

        do {
            _ = try await fs.enumerate(at: .root)
            XCTFail("Should throw when not connected")
        } catch {
            if case RemoteFileSystemError.notConnected = error {
                // Expected
            } else {
                XCTFail("Expected notConnected error, got: \(error)")
            }
        }
    }

    func testPublicKeyAuthenticationMethodSupportsED25519() throws {
        let privateKey = try TestSSHKeyFixtures.ed25519PrivateKey()

        let authMethod = try SFTPFileSystem.publicKeyAuthenticationMethod(
            username: "test",
            keyData: privateKey,
            passphrase: nil
        )

        XCTAssertNotNil(authMethod)
    }

    func testPublicKeyAuthenticationMethodSupportsOpenSSHECDSAP256() throws {
        let privateKey = try TestSSHKeyFixtures.ecdsaP256PrivateKey()

        let authMethod = try SFTPFileSystem.publicKeyAuthenticationMethod(
            username: "test",
            keyData: privateKey,
            passphrase: nil
        )

        XCTAssertNotNil(authMethod)
    }

    func testPublicKeyAuthenticationMethodSupportsEncryptedOpenSSHECDSAP256() throws {
        let privateKey = try TestSSHKeyFixtures.encryptedECDSAP256PrivateKey()

        let authMethod = try SFTPFileSystem.publicKeyAuthenticationMethod(
            username: "test",
            keyData: privateKey,
            passphrase: TestSSHKeyFixtures.encryptedKeyPassphrase
        )

        XCTAssertNotNil(authMethod)
    }

    func testPublicKeyAuthenticationMethodRejectsWrongPassphrase() throws {
        let privateKey = try TestSSHKeyFixtures.encryptedECDSAP256PrivateKey()
        XCTAssertThrowsError(
            try SFTPFileSystem.publicKeyAuthenticationMethod(
                username: "test",
                keyData: privateKey,
                passphrase: "wrong-passphrase"
            )
        ) { error in
            guard case RemoteFileSystemError.unsupported(let message) = error else {
                return XCTFail("Expected unsupported error, got \(error)")
            }
            XCTAssertTrue(message.contains("passphrase"))
        }
    }

    func testPublicKeyAuthenticationMethodRejectsPublicKeyFile() throws {
        let publicKey = try TestSSHKeyFixtures.ed25519PublicKey()
        XCTAssertThrowsError(
            try SFTPFileSystem.publicKeyAuthenticationMethod(
                username: "test",
                keyData: publicKey,
                passphrase: nil
            )
        ) { error in
            guard case RemoteFileSystemError.unsupported(let message) = error else {
                return XCTFail("Expected unsupported error, got \(error)")
            }
            XCTAssertTrue(message.contains(".pub"))
        }
    }

    func testDecodeExecEnumerationItems() throws {
        let json = """
        [
          {"name":"docs","type":"directory","size":0,"mtime":1700000000,"mode":493,"target":null},
          {"name":"notes.txt","type":"file","size":12,"mtime":1700000001,"mode":420,"target":null},
          {"name":"current","type":"symlink","size":0,"mtime":1700000002,"mode":511,"target":"releases/latest"}
        ]
        """

        let items = try SFTPFileSystem.decodeExecEnumerationItems(
            from: Data(json.utf8),
            parentPath: .root
        )

        XCTAssertEqual(items.map(\.name), ["docs", "notes.txt", "current"])
        XCTAssertEqual(items[0].type, .directory)
        XCTAssertEqual(items[1].type, .file)
        XCTAssertEqual(items[1].size, 12)
        XCTAssertEqual(items[1].permissions, 0o644)

        guard case .symlink(let target) = items[2].type else {
            return XCTFail("Expected symlink item")
        }
        XCTAssertEqual(target, "releases/latest")
    }

    func testMakeExecEnumerationCommandEncodesPath() {
        let command = SFTPFileSystem.makeExecEnumerationCommand(for: "/home/lk/demo")
        XCTAssertTrue(command.contains("python3 -c"))
        XCTAssertTrue(command.contains(Data("/home/lk/demo".utf8).base64EncodedString()))
    }
}

private enum TestSSHKeyFixtures {
    static let encryptedKeyPassphrase = "example"
    private static let comment = "test@example.com"
    private static let cache = NSCache<NSString, NSData>()

    static func ed25519PrivateKey() throws -> Data {
        try keyPair(named: "ed25519", algorithm: "ed25519").privateKey
    }

    static func ed25519PublicKey() throws -> Data {
        try keyPair(named: "ed25519", algorithm: "ed25519").publicKey
    }

    static func ecdsaP256PrivateKey() throws -> Data {
        try keyPair(named: "ecdsa-p256", algorithm: "ecdsa", extraArguments: ["-b", "256"]).privateKey
    }

    static func encryptedECDSAP256PrivateKey() throws -> Data {
        try keyPair(
            named: "ecdsa-p256-encrypted",
            algorithm: "ecdsa",
            passphrase: encryptedKeyPassphrase,
            extraArguments: ["-b", "256"]
        ).privateKey
    }

    private static func keyPair(
        named name: String,
        algorithm: String,
        passphrase: String? = nil,
        extraArguments: [String] = []
    ) throws -> (privateKey: Data, publicKey: Data) {
        let privateCacheKey = "\(name)-private" as NSString
        let publicCacheKey = "\(name)-public" as NSString
        if let privateKey = cache.object(forKey: privateCacheKey) as Data?,
           let publicKey = cache.object(forKey: publicCacheKey) as Data? {
            return (privateKey, publicKey)
        }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mfuse-sftp-test-keys", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let keyURL = directoryURL.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = [
            "-q",
            "-t", algorithm,
            "-f", keyURL.path,
            "-C", comment,
            "-N", passphrase ?? "",
        ] + extraArguments

        let stderr = Pipe()
        process.standardError = stderr
        guard let executableURL = process.executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw XCTSkip("ssh-keygen is unavailable or not executable at \(process.executableURL?.path ?? "unknown path")")
        }
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw XCTSkip("ssh-keygen failed to create test key: \(errorMessage)")
        }

        let privateKey = try Data(contentsOf: keyURL)
        let publicKey = try Data(contentsOf: keyURL.appendingPathExtension("pub"))
        cache.setObject(privateKey as NSData, forKey: privateCacheKey)
        cache.setObject(publicKey as NSData, forKey: publicCacheKey)
        return (privateKey, publicKey)
    }
}
