import Foundation
import Testing

@testable import MFuseOneDrive
import MFuseCore
import MFuseTestSupport

@Test func oneDriveFileSystemSmoke() async throws {
    let enumerateSession = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        if url.hasSuffix("/me/drive") {
            if auth == "Bearer expired-token" {
                return .http(status: 401, body: Data("{\"error\":{\"code\":\"InvalidAuthenticationToken\",\"message\":\"Expired\"}}".utf8))
            }
            return .http(status: 200, body: Data("{\"id\":\"drive-1\"}".utf8))
        }
        if url.contains("/oauth2/v2.0/token") {
            return .http(status: 200, body: Data("{\"access_token\":\"fresh-token\",\"refresh_token\":\"refresh-token\"}".utf8))
        }
        if url.hasSuffix("/me/drive/root/children") {
            #expect(auth == "Bearer fresh-token")
            return .http(
                status: 200,
                body: Data("""
                {
                  "value": [
                    {
                      "id": "item-1",
                      "name": "report.txt",
                      "size": 42,
                      "file": {},
                      "createdDateTime": "2024-01-01T00:00:00Z",
                      "lastModifiedDateTime": "2024-01-02T00:00:00Z"
                    }
                  ]
                }
                """.utf8)
            )
        }
        return .http(status: 200, body: Data("{}".utf8))
    }

    let provider = OneDriveOAuthProvider(
        configuration: OAuthClientConfiguration(
            providerName: "Microsoft OneDrive",
            clientID: "client-id",
            redirectURI: "com.example.onedrive:/oauth",
            authorizationURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
            tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
            scopes: ["Files.ReadWrite", "offline_access"]
        ),
        session: enumerateSession
    )

    let config = ConnectionConfig(name: "OneDrive", backendType: .oneDrive, host: "")
    let fileSystem = OneDriveFileSystem(
        config: config,
        credential: Credential(password: "refresh-token", token: "expired-token"),
        oauthProvider: provider,
        session: enumerateSession
    )
    try await fileSystem.connect()
    let items = try await fileSystem.enumerate(at: .root)
    #expect(items.count == 1)
    #expect(items.first?.name == "report.txt")

    let copySession = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        if url.hasSuffix("/me/drive") {
            return .http(status: 200, body: Data("{\"id\":\"drive-1\"}".utf8))
        }
        if url.hasSuffix("/me/drive/root:/Source") {
            return .http(status: 200, body: Data("{\"id\":\"src-1\",\"name\":\"Source\",\"folder\":{}}".utf8))
        }
        if url.hasSuffix("/me/drive/root:/Target") {
            return .http(status: 200, body: Data("{\"id\":\"target-parent\",\"name\":\"Target\",\"folder\":{}}".utf8))
        }
        if url.hasSuffix("/me/drive/root:/Target/Copied") {
            return .http(status: 404, body: Data("{\"error\":{\"code\":\"itemNotFound\",\"message\":\"Not found\"}}".utf8))
        }
        if url.hasSuffix("/me/drive/items/src-1/copy?@microsoft.graph.conflictBehavior=fail") {
            return .http(status: 202, body: Data(), headers: ["Location": "https://graph.microsoft.com/copy-monitor"])
        }
        if url == "https://graph.microsoft.com/copy-monitor" {
            return .http(
                status: 200,
                body: Data("{\"status\":\"failed\",\"error\":{\"code\":\"nameAlreadyExists\",\"message\":\"Name already exists\"}}".utf8)
            )
        }
        throw TestFailure("Unexpected request: \(url)")
    }

    let copyProvider = OneDriveOAuthProvider(
        configuration: OAuthClientConfiguration(
            providerName: "Microsoft OneDrive",
            clientID: "client-id",
            redirectURI: "com.example.onedrive:/oauth",
            authorizationURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
            tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
            scopes: ["Files.ReadWrite", "offline_access"]
        ),
        session: copySession
    )
    let copyFileSystem = OneDriveFileSystem(
        config: config,
        credential: Credential(token: "valid-token"),
        oauthProvider: copyProvider,
        session: copySession
    )
    try await copyFileSystem.connect()
    await #expect(throws: RemoteFileSystemError.self) {
        try await copyFileSystem.copy(from: RemotePath("/Source"), to: RemotePath("/Target/Copied"))
    }
}

@Test func oneDriveCopyRejectsUntrustedMonitorURL() async throws {
    let session = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        if url.hasSuffix("/me/drive") {
            return .http(status: 200, body: Data("{\"id\":\"drive-1\"}".utf8))
        }
        if url.hasSuffix("/me/drive/root:/Source") {
            return .http(status: 200, body: Data("{\"id\":\"src-1\",\"name\":\"Source\",\"folder\":{}}".utf8))
        }
        if url.hasSuffix("/me/drive/root:/Target") {
            return .http(status: 200, body: Data("{\"id\":\"target-parent\",\"name\":\"Target\",\"folder\":{}}".utf8))
        }
        if url.hasSuffix("/me/drive/root:/Target/Copied") {
            return .http(status: 404, body: Data("{\"error\":{\"code\":\"itemNotFound\",\"message\":\"Not found\"}}".utf8))
        }
        if url.hasSuffix("/me/drive/items/src-1/copy?@microsoft.graph.conflictBehavior=fail") {
            return .http(status: 202, body: Data(), headers: ["Location": "https://evil.example/copy-monitor"])
        }
        throw TestFailure("Unexpected request for untrusted monitor URL test: \(url)")
    }

    let fileSystem = OneDriveFileSystem(
        config: ConnectionConfig(name: "OneDrive", backendType: .oneDrive, host: ""),
        credential: Credential(token: "valid-token"),
        session: session
    )

    try await fileSystem.connect()
    do {
        try await fileSystem.copy(from: RemotePath("/Source"), to: RemotePath("/Target/Copied"))
        Issue.record("Expected untrusted monitor URL to fail")
    } catch let error as RemoteFileSystemError {
        #expect(error.localizedDescription.contains("untrusted monitor URL"))
    }
}

@Test func oneDriveEnumerationRejectsUntrustedNextLink() async throws {
    let session = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        if url.hasSuffix("/me/drive") {
            return .http(status: 200, body: Data("{\"id\":\"drive-1\"}".utf8))
        }
        if url.hasSuffix("/me/drive/root/children") {
            return .http(
                status: 200,
                body: Data("""
                {
                  "value": [],
                  "@odata.nextLink": "https://evil.example/steal"
                }
                """.utf8)
            )
        }
        throw TestFailure("Unexpected request for untrusted nextLink test: \(url)")
    }

    let fileSystem = OneDriveFileSystem(
        config: ConnectionConfig(name: "OneDrive", backendType: .oneDrive, host: ""),
        credential: Credential(token: "valid-token"),
        session: session
    )

    try await fileSystem.connect()
    do {
        _ = try await fileSystem.enumerate(at: .root)
        Issue.record("Expected untrusted nextLink to be rejected")
    } catch let error as RemoteFileSystemError {
        #expect(error.localizedDescription.contains("Refusing to follow untrusted OneDrive nextLink"))
    }
}

@Test func oneDriveCreateFileUsesFailOnConflictUpload() async throws {
    let session = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        if url.hasSuffix("/me/drive") {
            return .http(status: 200, body: Data("{\"id\":\"drive-1\"}".utf8))
        }
        if url.contains("/me/drive/root:/Existing.txt") && !url.contains(":/content?") {
            throw TestFailure("createFile should not preflight target existence: \(url)")
        }
        if url.contains("/me/drive/root:/Existing.txt:/content?")
            && url.contains("@microsoft.graph.conflictBehavior=fail") {
            return .http(
                status: 409,
                body: Data("{\"error\":{\"code\":\"nameAlreadyExists\",\"message\":\"Name already exists\"}}".utf8)
            )
        }
        throw TestFailure("Unexpected request: \(url)")
    }

    let fileSystem = OneDriveFileSystem(
        config: ConnectionConfig(name: "OneDrive", backendType: .oneDrive, host: ""),
        credential: Credential(token: "valid-token"),
        session: session
    )

    try await fileSystem.connect()
    await #expect(throws: RemoteFileSystemError.self) {
        try await fileSystem.createFile(at: RemotePath("/Existing.txt"), data: Data("new".utf8))
    }
}

@Test func oneDriveCreateDirectoryUsesAtomicConflictHandlingWithoutTargetPreflight() async throws {
    let session = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        if url.hasSuffix("/me/drive") {
            return .http(status: 200, body: Data("{\"id\":\"drive-1\"}".utf8))
        }
        if url.hasSuffix("/me/drive/root:/Parent/Existing") {
            throw TestFailure("createDirectory should not preflight target existence: \(url)")
        }
        if url.hasSuffix("/me/drive/root:/Parent") {
            return .http(status: 200, body: Data("{\"id\":\"parent\",\"name\":\"Parent\",\"folder\":{}}".utf8))
        }
        if url.hasSuffix("/me/drive/root:/Parent:/children") {
            return .http(
                status: 409,
                body: Data("{\"error\":{\"code\":\"nameAlreadyExists\",\"message\":\"Name already exists\"}}".utf8)
            )
        }
        throw TestFailure("Unexpected request: \(url)")
    }

    let fileSystem = OneDriveFileSystem(
        config: ConnectionConfig(name: "OneDrive", backendType: .oneDrive, host: ""),
        credential: Credential(token: "valid-token"),
        session: session
    )

    try await fileSystem.connect()
    await #expect(throws: RemoteFileSystemError.self) {
        try await fileSystem.createDirectory(at: RemotePath("/Parent/Existing"))
    }
}

@Test func oneDriveMoveMapsFailedPatchToAlreadyExistsWhenDestinationAppears() async throws {
    let destinationLookupCount = LockedCounter()
    let session = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        if url.hasSuffix("/me/drive") {
            return .http(status: 200, body: Data("{\"id\":\"drive-1\"}".utf8))
        }
        if url.hasSuffix("/me/drive/root:/Target/Existing") {
            if destinationLookupCount.increment() == 1 {
                return .http(status: 404, body: Data("{\"error\":{\"code\":\"itemNotFound\",\"message\":\"Not found\"}}".utf8))
            }
            return .http(status: 200, body: Data("{\"id\":\"existing\",\"name\":\"Existing\",\"file\":{}}".utf8))
        }
        if url.hasSuffix("/me/drive/root:/Source") {
            return .http(status: 200, body: Data("{\"id\":\"src 1\",\"name\":\"Source\",\"file\":{}}".utf8))
        }
        if url.hasSuffix("/me/drive/root:/Target") {
            return .http(status: 200, body: Data("{\"id\":\"target-parent\",\"name\":\"Target\",\"folder\":{}}".utf8))
        }
        if url.hasSuffix("/me/drive/items/src%201") {
            return .http(status: 500, body: Data("{\"error\":{\"code\":\"serverError\",\"message\":\"Move failed\"}}".utf8))
        }
        throw TestFailure("Unexpected request: \(url)")
    }

    let fileSystem = OneDriveFileSystem(
        config: ConnectionConfig(name: "OneDrive", backendType: .oneDrive, host: ""),
        credential: Credential(token: "valid-token"),
        session: session
    )

    try await fileSystem.connect()
    do {
        try await fileSystem.move(from: RemotePath("/Source"), to: RemotePath("/Target/Existing"))
        Issue.record("Expected move failure to map to alreadyExists")
    } catch RemoteFileSystemError.alreadyExists(let path) {
        #expect(path == RemotePath("/Target/Existing"))
    } catch {
        Issue.record("Expected alreadyExists, got \(error)")
    }
}

@Test func oneDriveMoveRethrowsOriginalPatchFailureWhenDestinationStillMissing() async throws {
    let session = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        if url.hasSuffix("/me/drive") {
            return .http(status: 200, body: Data("{\"id\":\"drive-1\"}".utf8))
        }
        if url.hasSuffix("/me/drive/root:/Target/Missing") {
            return .http(status: 404, body: Data("{\"error\":{\"code\":\"itemNotFound\",\"message\":\"Not found\"}}".utf8))
        }
        if url.hasSuffix("/me/drive/root:/Source") {
            return .http(status: 200, body: Data("{\"id\":\"src 1\",\"name\":\"Source\",\"file\":{}}".utf8))
        }
        if url.hasSuffix("/me/drive/root:/Target") {
            return .http(status: 200, body: Data("{\"id\":\"target-parent\",\"name\":\"Target\",\"folder\":{}}".utf8))
        }
        if url.hasSuffix("/me/drive/items/src%201") {
            return .http(status: 500, body: Data("{\"error\":{\"code\":\"serverError\",\"message\":\"Move failed\"}}".utf8))
        }
        throw TestFailure("Unexpected request: \(url)")
    }

    let fileSystem = OneDriveFileSystem(
        config: ConnectionConfig(name: "OneDrive", backendType: .oneDrive, host: ""),
        credential: Credential(token: "valid-token"),
        session: session
    )

    try await fileSystem.connect()
    do {
        try await fileSystem.move(from: RemotePath("/Source"), to: RemotePath("/Target/Missing"))
        Issue.record("Expected original move failure")
    } catch let error as RemoteFileSystemError {
        #expect(error.localizedDescription.contains("Move failed"))
    } catch {
        Issue.record("Expected RemoteFileSystemError, got \(error)")
    }
}

@Test func oneDriveFileSystemSurfacesMissingBuiltInOAuthConfiguration() async throws {
    let session = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        if url.hasSuffix("/me/drive") {
            return .http(
                status: 401,
                body: Data("{\"error\":{\"code\":\"InvalidAuthenticationToken\",\"message\":\"Expired\"}}".utf8)
            )
        }
        throw TestFailure("Unexpected request: \(url)")
    }

    let fileSystem = OneDriveFileSystem(
        config: ConnectionConfig(name: "OneDrive", backendType: .oneDrive, host: ""),
        credential: Credential(password: "refresh-token", token: "expired-token"),
        session: session
    )

    do {
        try await fileSystem.connect()
        Issue.record("Expected connect() to fail when built-in OneDrive OAuth configuration is unavailable")
    } catch let error as RemoteFileSystemError {
        let message = error.localizedDescription
        #expect(message.contains("OneDriveOAuthProvider.builtIn() failed"))
        #expect(message.contains("No valid clientID/redirectURI are available"))
    }
}

@Test func oneDriveRequestsAfterDisconnectFailNotConnectedWithoutCredentialFallback() async throws {
    let session = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        if url.hasSuffix("/me/drive") {
            return .http(status: 200, body: Data("{\"id\":\"drive-1\"}".utf8))
        }
        if url.contains("/oauth2/v2.0/token") {
            return .http(
                status: 200,
                body: Data("{\"access_token\":\"fresh-token\",\"refresh_token\":\"refresh-token\"}".utf8)
            )
        }
        throw TestFailure("Unexpected request after disconnect: \(url)")
    }
    let updates = CredentialUpdateRecorder()
    let provider = OneDriveOAuthProvider(
        configuration: OAuthClientConfiguration(
            providerName: "Microsoft OneDrive",
            clientID: "client-id",
            redirectURI: "com.example.onedrive:/oauth",
            authorizationURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
            tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
            scopes: ["Files.ReadWrite", "offline_access"]
        ),
        session: session
    )

    let fileSystem = OneDriveFileSystem(
        config: ConnectionConfig(name: "OneDrive", backendType: .oneDrive, host: ""),
        credential: Credential(password: "refresh-token", token: "valid-token"),
        oauthProvider: provider,
        session: session,
        onCredentialUpdated: { credential in
            await updates.record(credential)
        }
    )

    try await fileSystem.connect()
    try await fileSystem.disconnect()
    #expect(await fileSystem.isConnected == false)

    let storedCredential = await updates.lastCredential
    #expect(storedCredential?.password == "refresh-token")
    #expect(storedCredential?.token == nil)

    do {
        _ = try await fileSystem.enumerate(at: .root)
        Issue.record("Expected enumerate() after disconnect to fail with notConnected")
    } catch RemoteFileSystemError.notConnected {
        // Expected.
    } catch {
        Issue.record("Expected notConnected after disconnect, got \(error)")
    }

    try await fileSystem.connect()
    #expect(await fileSystem.isConnected)
    #expect(await updates.lastCredential?.token == "fresh-token")
}

@Test func oneDriveLargeUploadRejectsInvalidUploadSessionURL() async throws {
    let session = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        if url.hasSuffix("/me/drive") {
            return .http(status: 200, body: Data("{\"id\":\"drive-1\"}".utf8))
        }
        if url.hasSuffix("/me/drive/root") {
            return .http(status: 200, body: Data("{\"id\":\"root\",\"name\":\"root\",\"folder\":{}}".utf8))
        }
        if url.hasSuffix("/me/drive/root:/Large.bin:/createUploadSession") {
            return .http(status: 200, body: Data("{\"uploadUrl\":\"http://graph.microsoft.com/upload\"}".utf8))
        }
        throw TestFailure("Unexpected request: \(url)")
    }

    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mfuse-onedrive-large-\(UUID().uuidString).bin")
    try Data(count: 8 * 1024 * 1024 + 1).write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let fileSystem = OneDriveFileSystem(
        config: ConnectionConfig(name: "OneDrive", backendType: .oneDrive, host: ""),
        credential: Credential(token: "valid-token"),
        session: session
    )

    try await fileSystem.connect()
    do {
        try await fileSystem.createFile(at: RemotePath("/Large.bin"), from: fileURL)
        Issue.record("Expected invalid upload session URL to fail")
    } catch let error as RemoteFileSystemError {
        #expect(error.localizedDescription.contains("invalid upload session URL"))
    }
}

@Test func oneDriveRefreshFailureClearsConnectionState() async throws {
    let session = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        if url.hasSuffix("/me/drive") {
            return .http(status: 200, body: Data("{\"id\":\"drive-1\"}".utf8))
        }
        if url.hasSuffix("/me/drive/root/children") {
            return .http(
                status: 401,
                body: Data("{\"error\":{\"code\":\"InvalidAuthenticationToken\",\"message\":\"Expired\"}}".utf8)
            )
        }
        if url.contains("/oauth2/v2.0/token") {
            return .http(
                status: 400,
                body: Data("{\"error\":\"invalid_grant\",\"error_description\":\"Refresh failed\"}".utf8)
            )
        }
        throw TestFailure("Unexpected request: \(url)")
    }

    let provider = OneDriveOAuthProvider(
        configuration: OAuthClientConfiguration(
            providerName: "Microsoft OneDrive",
            clientID: "client-id",
            redirectURI: "com.example.onedrive:/oauth",
            authorizationURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
            tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
            scopes: ["Files.ReadWrite", "offline_access"]
        ),
        session: session
    )
    let fileSystem = OneDriveFileSystem(
        config: ConnectionConfig(name: "OneDrive", backendType: .oneDrive, host: ""),
        credential: Credential(password: "refresh-token", token: "valid-token"),
        oauthProvider: provider,
        session: session
    )

    try await fileSystem.connect()
    #expect(await fileSystem.isConnected)

    await #expect(throws: RemoteFileSystemError.self) {
        _ = try await fileSystem.enumerate(at: .root)
    }
    #expect(await fileSystem.isConnected == false)
}

@Test func oneDriveRetriedUnauthorizedResponseClearsConnectionState() async throws {
    let session = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        if url.hasSuffix("/me/drive") {
            return .http(status: 200, body: Data("{\"id\":\"drive-1\"}".utf8))
        }
        if url.hasSuffix("/me/drive/root/children") {
            return .http(
                status: 401,
                body: Data("{\"error\":{\"code\":\"InvalidAuthenticationToken\",\"message\":\"Unauthorized for \(auth)\"}}".utf8)
            )
        }
        if url.contains("/oauth2/v2.0/token") {
            return .http(
                status: 200,
                body: Data("{\"access_token\":\"fresh-token\",\"refresh_token\":\"refresh-token\"}".utf8)
            )
        }
        throw TestFailure("Unexpected request: \(url)")
    }

    let provider = OneDriveOAuthProvider(
        configuration: OAuthClientConfiguration(
            providerName: "Microsoft OneDrive",
            clientID: "client-id",
            redirectURI: "com.example.onedrive:/oauth",
            authorizationURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
            tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
            scopes: ["Files.ReadWrite", "offline_access"]
        ),
        session: session
    )
    let fileSystem = OneDriveFileSystem(
        config: ConnectionConfig(name: "OneDrive", backendType: .oneDrive, host: ""),
        credential: Credential(password: "refresh-token", token: "valid-token"),
        oauthProvider: provider,
        session: session
    )

    try await fileSystem.connect()
    #expect(await fileSystem.isConnected)

    do {
        _ = try await fileSystem.enumerate(at: .root)
        Issue.record("Expected retried 401 response to fail")
    } catch RemoteFileSystemError.authenticationFailed {
        // Expected.
    } catch {
        Issue.record("Expected authenticationFailed, got \(error)")
    }
    #expect(await fileSystem.isConnected == false)
}

@Test func oneDriveBuiltInOAuthTrimsAuthorityBeforeBuildingURLs() throws {
    let bundle = try makeOneDriveOAuthBundle(authority: " common ")
    let provider = try OneDriveOAuthProvider.builtIn(
        bundle: bundle,
        session: URLSession(configuration: .ephemeral)
    )
    #expect(provider.authorizationURL.absoluteString == "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")
    #expect(provider.tokenURL.absoluteString == "https://login.microsoftonline.com/common/oauth2/v2.0/token")
}

private func makeMockSession(
    handler: @escaping @Sendable (URLRequest) throws -> MockURLProtocol.Response
) throws -> URLSession {
    let token = UUID().uuidString
    MockURLProtocol.register(handler: handler, for: token)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    configuration.httpAdditionalHeaders = [MockURLProtocol.sessionHeader: token]
    return URLSession(
        configuration: configuration,
        delegate: MockSessionHandlerCleaner(token: token),
        delegateQueue: nil
    )
}

private func makeOneDriveOAuthBundle(authority: String) throws -> Bundle {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mfuse-onedrive-oauth-\(UUID().uuidString).bundle", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": "dev.mfuse.tests.onedrive.\(UUID().uuidString)",
        "MFOneDriveClientID": "client-id",
        "MFOneDriveRedirectURI": "com.example.onedrive:/oauth",
        "MFOneDriveAuthority": authority
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: bundleURL.appendingPathComponent("Info.plist"))
    return try #require(Bundle(path: bundleURL.path))
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
