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
        let privateKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACAi19yxbgtZH0Y26GZGr2vyVErGFskeOY9HwHLxYbmkAwAAAKAPNV8QDzVf
        EAAAAAtzc2gtZWQyNTUxOQAAACAi19yxbgtZH0Y26GZGr2vyVErGFskeOY9HwHLxYbmkAw
        AAAED3UDHB29MB7vQDpb7PGFjEMAYT9FzpnadYWrCPSUma5SLX3LFuC1kfRjboZkava/JU
        SsYWyR45j0fAcvFhuaQDAAAAHGphYXBASmFhcHMtTWFjQm9vay1Qcm8ubG9jYWwB
        -----END OPENSSH PRIVATE KEY-----
        """

        let authMethod = try SFTPFileSystem.publicKeyAuthenticationMethod(
            username: "test",
            keyData: Data(privateKey.utf8),
            passphrase: nil
        )

        XCTAssertNotNil(authMethod)
    }

    func testPublicKeyAuthenticationMethodSupportsOpenSSHECDSAP256() throws {
        let privateKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
        1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQR/G9rJovBSvdkd9XoGNURImI5vQP/2
        w7TQNb/b8hGI5oq844XjI7V4j8XDwjqlcNfeD7gqoHf8ekpmL4EUtzYaAAAAqFZzBpBWcw
        aQAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBH8b2smi8FK92R31
        egY1REiYjm9A//bDtNA1v9vyEYjmirzjheMjtXiPxcPCOqVw194PuCqgd/x6SmYvgRS3Nh
        oAAAAgPV1jW6vy45i2F3WBFirMPgiJU7FgIl4rJy264fkhPU4AAAALeW91QGV4YW1wbGUB
        AgMEBQ==
        -----END OPENSSH PRIVATE KEY-----
        """

        let authMethod = try SFTPFileSystem.publicKeyAuthenticationMethod(
            username: "test",
            keyData: Data(privateKey.utf8),
            passphrase: nil
        )

        XCTAssertNotNil(authMethod)
    }

    func testPublicKeyAuthenticationMethodSupportsEncryptedOpenSSHECDSAP256() throws {
        let privateKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAkrdClHz
        uuxprLhsjBEV/nAAAAGAAAAAEAAABoAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlz
        dHAyNTYAAABBBNYdRdTdZashwwYb64Mk2EGndHXAN9DcbOiolNKdljziz/W7//a76x8WgT
        VvqLMOiI2Hk2+p5ymg4kvdK6+EyYoAAACwZ6guCU7bs6Xl56/c/4YNxYyoXdfboX6GR80A
        TZ1zNDIEe52la3P1MUSagCg9pkIYv9BNJDYgGRUj/alKpIKPJsae9YimGH0JKpcRkhIpap
        E9B80Cz8sR0MHCUjHBMiEQlfqoY4KS0Pxv42ZWAyqAocBvv9zzASb3TBm2rMwMZNy4QzkI
        XfV9hnSUVLj+da1NtI4ysVMnPNVGuhkdsbWC2M+ZOEGtLOcRb2OTfx+QdPs=
        -----END OPENSSH PRIVATE KEY-----
        """

        let authMethod = try SFTPFileSystem.publicKeyAuthenticationMethod(
            username: "test",
            keyData: Data(privateKey.utf8),
            passphrase: "example"
        )

        XCTAssertNotNil(authMethod)
    }

    func testPublicKeyAuthenticationMethodRejectsWrongPassphrase() {
        let privateKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAkrdClHz
        uuxprLhsjBEV/nAAAAGAAAAAEAAABoAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlz
        dHAyNTYAAABBBNYdRdTdZashwwYb64Mk2EGndHXAN9DcbOiolNKdljziz/W7//a76x8WgT
        VvqLMOiI2Hk2+p5ymg4kvdK6+EyYoAAACwZ6guCU7bs6Xl56/c/4YNxYyoXdfboX6GR80A
        TZ1zNDIEe52la3P1MUSagCg9pkIYv9BNJDYgGRUj/alKpIKPJsae9YimGH0JKpcRkhIpap
        E9B80Cz8sR0MHCUjHBMiEQlfqoY4KS0Pxv42ZWAyqAocBvv9zzASb3TBm2rMwMZNy4QzkI
        XfV9hnSUVLj+da1NtI4ysVMnPNVGuhkdsbWC2M+ZOEGtLOcRb2OTfx+QdPs=
        -----END OPENSSH PRIVATE KEY-----
        """

        XCTAssertThrowsError(
            try SFTPFileSystem.publicKeyAuthenticationMethod(
                username: "test",
                keyData: Data(privateKey.utf8),
                passphrase: "wrong-passphrase"
            )
        ) { error in
            guard case RemoteFileSystemError.unsupported(let message) = error else {
                return XCTFail("Expected unsupported error, got \(error)")
            }
            XCTAssertTrue(message.contains("passphrase"))
        }
    }

    func testPublicKeyAuthenticationMethodRejectsPublicKeyFile() {
        let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLXXLFuC1kfRjboZkava/JUSsYWyR45j0fAcvFhuaQD test@example.com"

        XCTAssertThrowsError(
            try SFTPFileSystem.publicKeyAuthenticationMethod(
                username: "test",
                keyData: Data(publicKey.utf8),
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
