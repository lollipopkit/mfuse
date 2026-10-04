import Foundation
import MFuseCore
import MFuseE2E
import MFuseFTP
import MFuseS3
import MFuseSFTP
import MFuseSMB
import MFuseWebDAV
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
        try await run(SFTPFileSystem(config: config, credential: Credential(password: env.password)),
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
        try await run(FTPFileSystem(config: config, credential: Credential(password: env.password)),
                      rangeReads: false, copy: false)
    }

    func testWebDAV() async throws {
        let env = try E2EEnvironment()
        let config = ConnectionConfig(
            name: "e2e-webdav", backendType: .webdav, host: env.host, port: 80,
            username: env.user, authMethod: .password,
            remotePath: try env.require("MFUSE_E2E_WEBDAV_PATH"),
            parameters: ["tls": "false"]
        )
        try await run(WebDAVFileSystem(config: config, credential: Credential(password: env.password)),
                      rangeReads: false, copy: true)
    }

    func testSMB() async throws {
        let env = try E2EEnvironment()
        let config = ConnectionConfig(
            name: "e2e-smb", backendType: .smb, host: env.host, port: 445,
            username: env.user, authMethod: .password, remotePath: "/",
            parameters: ["share": try env.require("MFUSE_E2E_SMB_SHARE")]
        )
        try await run(SMBFileSystem(config: config, credential: Credential(password: env.password)),
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
    let password: String

    init() throws {
        let values = ProcessInfo.processInfo.environment
        guard let host = values["MFUSE_E2E_HOST"], !host.isEmpty else {
            throw XCTSkip("MFUSE_E2E_HOST is not set; run `make test-e2e`")
        }
        self.host = host
        self.user = values["MFUSE_E2E_USER"] ?? "mfuse"
        self.password = values["MFUSE_E2E_PASSWORD"] ?? ""
    }

    func require(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw XCTSkip("\(name) is not set")
        }
        return value
    }
}
