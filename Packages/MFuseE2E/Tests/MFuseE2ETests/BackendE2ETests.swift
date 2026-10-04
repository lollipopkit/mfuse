import Foundation
import MFuseCore
import MFuseE2E
@testable import MFuseFTP
import MFuseNFS
import MFuseS3
import MFuseSFTP
import MFuseSMB
import MFuseWebDAV
import NIOSSL
import XCTest

/// Each backend against the e2e servers. Configured from `MFUSE_E2E_*` environment
/// variables — `make test-e2e` loads them from `~/.config/mfuse/e2e.env` — and skipped
/// when they are absent.
final class BackendE2ETests: XCTestCase {

    func testSFTPWithPassword() async throws {
        let env = try E2EEnvironment()
        let config = ConnectionConfig(
            name: "e2e-sftp", backendType: .sftp, host: env.host, port: 22,
            username: env.user, authMethod: .password, remotePath: "/home/\(env.user)/files"
        )
        try await run(SFTPFileSystem(config: config, credential: Credential(password: try env.password())),
                      rangeReads: true, copy: true)
    }

    func testSFTPWithKey() async throws {
        let env = try E2EEnvironment()
        let key = try Data(contentsOf: URL(fileURLWithPath: try env.require("MFUSE_E2E_SSH_KEY")))
        let config = ConnectionConfig(
            name: "e2e-sftp-key", backendType: .sftp, host: env.host, port: 22,
            username: env.user, authMethod: .publicKey, remotePath: "/home/\(env.user)/files"
        )
        try await run(SFTPFileSystem(config: config, credential: Credential(privateKey: key)),
                      rangeReads: true, copy: true)
    }

    func testFTP() async throws {
        let env = try E2EEnvironment()
        let config = ConnectionConfig(
            name: "e2e-ftp", backendType: .ftp, host: env.host, port: 21,
            username: env.user, authMethod: .password, remotePath: "/files"
        )
        try await run(FTPFileSystem(config: config, credential: Credential(password: try env.password())),
                      rangeReads: false, copy: false)
    }

    /// `AUTH TLS` on the plain port. Certificates come from the VM's own CA, trusted only here.
    func testFTPSExplicit() async throws {
        try await runFTPS(port: 21)
    }

    /// TLS from the first byte on port 990.
    func testFTPSImplicit() async throws {
        try await runFTPS(port: 990)
    }

    private func runFTPS(port: UInt16) async throws {
        let env = try E2EEnvironment()
        let ca = try NIOSSLCertificate.fromPEMFile(try env.require("MFUSE_E2E_CA"))
        let config = ConnectionConfig(
            name: "e2e-ftps-\(port)", backendType: .ftp, host: env.host, port: port,
            username: env.user, authMethod: .password, remotePath: "/files",
            parameters: ["tls": "true"]
        )
        let fileSystem = FTPFileSystem(
            config: config, credential: Credential(password: try env.password()), additionalTrustRoots: ca
        )
        try await run(fileSystem, rangeReads: false, copy: false)
    }

    func testNFS() async throws {
        let env = try E2EEnvironment()
        try await run(NFSFileSystem(config: try nfsConfig(env, export: "/srv/nfs"), credential: Credential()),
                      rangeReads: true, copy: true)
    }

    /// NFS's RENAME replaces an existing file; MFuse must refuse instead, naming the
    /// destination, and leave both files as they were.
    func testNFSMoveRefusesExistingDestination() async throws {
        let env = try E2EEnvironment()
        let fileSystem = NFSFileSystem(config: try nfsConfig(env, export: "/srv/nfs"), credential: Credential())
        let root = RemotePath.root.appending("mfuse-e2e-move-\(UUID().uuidString.prefix(8))")
        let source = root.appending("a.txt")
        let destination = root.appending("b.txt")
        try await fileSystem.connect()
        // Cleanup runs whatever happens below, and disconnects even when deleting fails.
        var failure: Error?
        do {
            try await fileSystem.createDirectory(at: root)
            try await fileSystem.createFile(at: source, data: Data("a".utf8))
            try await fileSystem.createFile(at: destination, data: Data("b".utf8))
            do {
                try await fileSystem.move(from: source, to: destination)
                XCTFail("move replaced an existing destination")
            } catch RemoteFileSystemError.alreadyExists(let path) {
                XCTAssertEqual(path, destination)
            }
            let destinationData = try await fileSystem.readFile(at: destination)
            let sourceData = try await fileSystem.readFile(at: source)
            XCTAssertEqual(destinationData, Data("b".utf8))
            XCTAssertEqual(sourceData, Data("a".utf8))
        } catch {
            failure = error
        }
        do {
            try await fileSystem.delete(at: root)
        } catch {
            failure = failure ?? error
        }
        try? await fileSystem.disconnect()
        if let failure { throw failure }
    }

    /// Without `insecure` the server refuses MFuse's unprivileged port; the error has to
    /// say what to change.
    func testNFSSecureExportExplainsInsecure() async throws {
        let env = try E2EEnvironment()
        let fileSystem = NFSFileSystem(config: try nfsConfig(env, export: "/srv/nfs-secure"), credential: Credential())
        do {
            try await fileSystem.connect()
            try await fileSystem.disconnect()
            XCTFail("mounting an export without `insecure` succeeded")
        } catch RemoteFileSystemError.connectionFailed(let message) {
            XCTAssertTrue(message.contains("insecure"), message)
        }
    }

    private func nfsConfig(_ env: E2EEnvironment, export: String) throws -> ConnectionConfig {
        ConnectionConfig(
            name: "e2e-nfs", backendType: .nfs, host: env.host, port: 2049,
            authMethod: .anonymous, remotePath: export,
            parameters: [
                "uid": try env.require("MFUSE_E2E_NFS_UID"),
                "gid": try env.require("MFUSE_E2E_NFS_GID")
            ]
        )
    }

    func testWebDAV() async throws {
        let env = try E2EEnvironment()
        let config = ConnectionConfig(
            name: "e2e-webdav", backendType: .webdav, host: env.host, port: 80,
            username: env.user, authMethod: .password,
            remotePath: try env.require("MFUSE_E2E_WEBDAV_PATH"),
            parameters: ["tls": "false"]
        )
        try await run(WebDAVFileSystem(config: config, credential: Credential(password: try env.password())),
                      rangeReads: false, copy: true)
    }

    func testSMB() async throws {
        let env = try E2EEnvironment()
        let config = ConnectionConfig(
            name: "e2e-smb", backendType: .smb, host: env.host, port: 445,
            username: env.user, authMethod: .password, remotePath: "/",
            parameters: ["share": try env.require("MFUSE_E2E_SMB_SHARE")]
        )
        try await run(SMBFileSystem(config: config, credential: Credential(password: try env.password())),
                      rangeReads: false, copy: false)
    }

    func testS3() async throws {
        let env = try E2EEnvironment()
        let config = ConnectionConfig(
            name: "e2e-s3", backendType: .s3, host: "", authMethod: .accessKey, remotePath: "/",
            parameters: [
                "endpoint": "http://\(env.host):\(try env.require("MFUSE_E2E_S3_PORT"))",
                "bucket": try env.require("MFUSE_E2E_S3_BUCKET"),
                "region": "us-east-1",
                "pathStyle": "true"
            ]
        )
        let credential = Credential(
            accessKeyID: try env.require("MFUSE_E2E_S3_ACCESS_KEY"),
            secretAccessKey: try env.require("MFUSE_E2E_S3_SECRET_KEY")
        )
        try await run(S3FileSystem(config: config, credential: credential), rangeReads: true, copy: true)
    }

    private func run(_ fileSystem: any RemoteFileSystem, rangeReads: Bool, copy: Bool) async throws {
        let suite = RemoteFileSystemConformance(
            fileSystem: fileSystem,
            capabilities: .init(rangeReads: rangeReads, copy: copy)
        )
        do {
            try await suite.run()
        } catch let failure as RemoteFileSystemConformance.Failure {
            XCTFail(failure.description)
        }
    }
}

/// The e2e server settings, from the environment.
private struct E2EEnvironment {
    let host: String
    let user: String

    init() throws {
        let values = ProcessInfo.processInfo.environment
        guard let host = values["MFUSE_E2E_HOST"], !host.isEmpty else {
            throw XCTSkip("MFUSE_E2E_HOST is not set; run `make test-e2e`")
        }
        self.host = host
        self.user = values["MFUSE_E2E_USER"] ?? "mfuse"
    }

    /// Only the password-based tests need it, so it is read, and its absence skipped, there.
    func password() throws -> String {
        try require("MFUSE_E2E_PASSWORD")
    }

    func require(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw XCTSkip("\(name) is not set")
        }
        return value
    }
}
