import Foundation
import Testing
import MFuseCore

@testable import MFuseSMB

@Test func writeFileFromURLThrowsNotConnectedInsteadOfUnsupported() async throws {
    let fs = makeFileSystem()
    let localFileURL = try makeTemporaryFileURL(contents: Data("hello".utf8))
    defer { try? FileManager.default.removeItem(at: localFileURL) }

    do {
        try await fs.writeFile(at: RemotePath("/test.txt"), from: localFileURL)
        Issue.record("Expected notConnected error")
    } catch let error as RemoteFileSystemError {
        guard case .notConnected = error else {
            Issue.record("Expected notConnected error, got \(error)")
            return
        }
    }
}

@Test func createFileFromURLThrowsNotConnectedInsteadOfUnsupported() async throws {
    let fs = makeFileSystem()
    let localFileURL = try makeTemporaryFileURL(contents: Data("hello".utf8))
    defer { try? FileManager.default.removeItem(at: localFileURL) }

    do {
        try await fs.createFile(at: RemotePath("/test.txt"), from: localFileURL)
        Issue.record("Expected notConnected error")
    } catch let error as RemoteFileSystemError {
        guard case .notConnected = error else {
            Issue.record("Expected notConnected error, got \(error)")
            return
        }
    }
}

@Test func placeholder() async throws {
    // Integration tests require a real SMB server.
}

private func makeFileSystem() -> SMBFileSystem {
    SMBFileSystem(
        config: ConnectionConfig(
            name: "Test SMB",
            backendType: .smb,
            host: "example.com",
            username: "user",
            authMethod: .password,
            parameters: ["share": "share"]
        ),
        credential: Credential(password: "pass")
    )
}

private func makeTemporaryFileURL(contents: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try contents.write(to: url)
    return url
}
