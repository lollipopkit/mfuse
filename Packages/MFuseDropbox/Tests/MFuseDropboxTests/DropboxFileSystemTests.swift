import Foundation
import Testing

@testable import MFuseDropbox
import MFuseCore

@Test func dropboxFileSystemSmoke() async throws {
    let enumerateSession = try makeMockSession { request in
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let url = try #require(request.url?.absoluteString)
        if url.contains("/users/get_current_account") {
            if auth == "Bearer expired-token" {
                return .http(status: 401, body: Data("{\"error_summary\":\"expired_access_token\"}".utf8))
            }
            return .http(status: 200, body: Data("{\"name\":{\"display_name\":\"Dropbox User\"},\"email\":\"dropbox@example.com\"}".utf8))
        }
        if url.contains("/oauth2/token") {
            return .http(
                status: 200,
                body: Data("{\"access_token\":\"fresh-token\",\"refresh_token\":\"refresh-token\"}".utf8)
            )
        }
        if url.contains("/files/list_folder") {
            #expect(auth == "Bearer fresh-token")
            return .http(
                status: 200,
                body: Data("""
                {
                  "entries": [
                    {
                      ".tag": "file",
                      "name": "notes.txt",
                      "size": 7,
                      "client_modified": "2024-01-01T00:00:00Z",
                      "server_modified": "2024-01-02T00:00:00Z",
                      "is_downloadable": true
                    }
                  ],
                  "cursor": "cursor-1",
                  "has_more": false
                }
                """.utf8)
            )
        }
        return .http(status: 200, body: Data("{}".utf8))
    }

    let provider = DropboxOAuthProvider(
        configuration: OAuthClientConfiguration(
            providerName: "Dropbox",
            clientID: "client-id",
            redirectURI: "com.example.dropbox:/oauth",
            authorizationURL: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
            tokenURL: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
            scopes: ["files.content.read"]
        ),
        session: enumerateSession
    )

    let config = ConnectionConfig(name: "Dropbox", backendType: .dropbox, host: "")
    let fileSystem = DropboxFileSystem(
        config: config,
        credential: Credential(password: "refresh-token", token: "expired-token"),
        oauthProvider: provider,
        session: enumerateSession
    )
    try await fileSystem.connect()
    let items = try await fileSystem.enumerate(at: RemotePath.root)
    #expect(items.count == 1)
    #expect(items.first?.name == "notes.txt")

    let conflictSession = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        if url.contains("/users/get_current_account") {
            return .http(status: 200, body: Data("{\"name\":{\"display_name\":\"Dropbox User\"}}".utf8))
        }
        if url.contains("/files/get_metadata") {
            return .http(status: 409, body: Data("{\"error_summary\":\"path/not_found/..\"}".utf8))
        }
        if url.contains("/files/create_folder_v2") {
            return .http(status: 409, body: Data("{\"error_summary\":\"path/conflict/folder/..\"}".utf8))
        }
        throw TestFailure("Unexpected request: \(url)")
    }

    let conflictProvider = DropboxOAuthProvider(
        configuration: OAuthClientConfiguration(
            providerName: "Dropbox",
            clientID: "client-id",
            redirectURI: "com.example.dropbox:/oauth",
            authorizationURL: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
            tokenURL: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
            scopes: ["files.content.read"]
        ),
        session: conflictSession
    )
    let conflictFileSystem = DropboxFileSystem(
        config: config,
        credential: Credential(token: "valid-token"),
        oauthProvider: conflictProvider,
        session: conflictSession
    )
    try await conflictFileSystem.connect()
    await #expect(throws: RemoteFileSystemError.self) {
        try await conflictFileSystem.createDirectory(at: RemotePath("/Docs"))
    }

    let session = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        if url.contains("/users/get_current_account") {
            return .http(status: 200, body: Data("{\"name\":{\"display_name\":\"Dropbox User\"}}".utf8))
        }
        if url.contains("/files/list_folder") {
            return .http(
                status: 200,
                body: Data("""
                {
                  "entries": [
                    {
                      ".tag": "folder",
                      "name": "Projects"
                    },
                    {
                      ".tag": "file",
                      "name": "readme.txt",
                      "size": 12,
                      "client_modified": "2024-01-01T00:00:00Z",
                      "server_modified": "2024-01-02T00:00:00Z",
                      "is_downloadable": true
                    }
                  ],
                  "cursor": "cursor-1",
                  "has_more": false
                }
                """.utf8)
            )
        }
        if url.contains("/files/get_metadata") {
            return .http(
                status: 200,
                body: Data("""
                {
                  ".tag": "folder",
                  "name": "Projects"
                }
                """.utf8)
            )
        }
        throw TestFailure("Unexpected request: \(url)")
    }

    let folderProvider = DropboxOAuthProvider(
        configuration: OAuthClientConfiguration(
            providerName: "Dropbox",
            clientID: "client-id",
            redirectURI: "com.example.dropbox:/oauth",
            authorizationURL: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
            tokenURL: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
            scopes: ["files.content.read"]
        ),
        session: session
    )

    let folderConfig = ConnectionConfig(name: "Dropbox", backendType: .dropbox, host: "")
    let folderFileSystem = DropboxFileSystem(
        config: folderConfig,
        credential: Credential(token: "valid-token"),
        oauthProvider: folderProvider,
        session: session
    )

    try await folderFileSystem.connect()

    let rootItems = try await folderFileSystem.enumerate(at: RemotePath.root)
    #expect(rootItems.count == 2)
    #expect(rootItems.first(where: { $0.name == "Projects" })?.isDirectory == true)
    #expect(rootItems.first(where: { $0.name == "Projects" })?.size == 0)

    let projectsInfo = try await folderFileSystem.itemInfo(at: RemotePath("/Projects"))
    #expect(projectsInfo.isDirectory)
    #expect(projectsInfo.size == 0)

    await #expect(throws: RemoteFileSystemError.self) {
        try await folderFileSystem.createDirectory(at: RemotePath("/Existing"))
    }

    let missingOAuthSession = try makeMockSession { request in
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let url = try #require(request.url?.absoluteString)
        if url.contains("/users/get_current_account") {
            if auth == "Bearer expired-token" {
                return .http(status: 401, body: Data("{\"error_summary\":\"expired_access_token\"}".utf8))
            }
            return .http(status: 200, body: Data("{\"name\":{\"display_name\":\"Dropbox User\"}}".utf8))
        }
        throw TestFailure("Unexpected request: \(url)")
    }

    let missingOAuthFileSystem = DropboxFileSystem(
        config: folderConfig,
        credential: Credential(password: "refresh-token", token: "expired-token"),
        session: missingOAuthSession
    )

    await #expect(throws: OAuthConfigurationError.self) {
        try await missingOAuthFileSystem.connect()
    }

    let invalidRefreshSession = try makeMockSession { request in
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let url = try #require(request.url?.absoluteString)
        if url.contains("/users/get_current_account") {
            if auth == "Bearer expired-token" || auth == "Bearer invalid-fresh-token" {
                return .http(status: 401, body: Data("{\"error_summary\":\"expired_access_token\"}".utf8))
            }
            throw TestFailure("Unexpected account validation auth: \(auth)")
        }
        if url.contains("/oauth2/token") {
            return .http(
                status: 200,
                body: Data("{\"access_token\":\"invalid-fresh-token\",\"refresh_token\":\"refresh-token\"}".utf8)
            )
        }
        throw TestFailure("Unexpected request: \(url)")
    }

    let invalidRefreshProvider = DropboxOAuthProvider(
        configuration: OAuthClientConfiguration(
            providerName: "Dropbox",
            clientID: "client-id",
            redirectURI: "com.example.dropbox:/oauth",
            authorizationURL: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
            tokenURL: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
            scopes: ["files.content.read"]
        ),
        session: invalidRefreshSession
    )
    let invalidRefreshFileSystem = DropboxFileSystem(
        config: folderConfig,
        credential: Credential(password: "refresh-token", token: "expired-token"),
        oauthProvider: invalidRefreshProvider,
        session: invalidRefreshSession
    )

    await #expect(throws: RemoteFileSystemError.self) {
        try await invalidRefreshFileSystem.connect()
    }
    #expect(await invalidRefreshFileSystem.isConnected == false)
}

@Test func dropboxDisconnectClearsStoredTokenAndBlocksRequests() async throws {
    let session = try makeMockSession { request in
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let url = try #require(request.url?.absoluteString)
        if url.contains("/users/get_current_account") {
            #expect(auth == "Bearer valid-token" || auth == "Bearer fresh-token")
            return .http(status: 200, body: Data("{\"name\":{\"display_name\":\"Dropbox User\"}}".utf8))
        }
        if url.contains("/oauth2/token") {
            return .http(
                status: 200,
                body: Data("{\"access_token\":\"fresh-token\",\"refresh_token\":\"refresh-token\"}".utf8)
            )
        }
        throw TestFailure("Unexpected request after disconnect: \(url)")
    }

    let updates = CredentialUpdateRecorder()
    let fileSystem = DropboxFileSystem(
        config: ConnectionConfig(name: "Dropbox", backendType: .dropbox, host: ""),
        credential: Credential(password: "refresh-token", token: "valid-token"),
        oauthProvider: DropboxOAuthProvider(
            configuration: OAuthClientConfiguration(
                providerName: "Dropbox",
                clientID: "client-id",
                redirectURI: "com.example.dropbox:/oauth",
                authorizationURL: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
                tokenURL: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
                scopes: ["files.content.read"]
            ),
            session: session
        ),
        session: session,
        onCredentialUpdated: { credential in
            await updates.record(credential)
        }
    )

    try await fileSystem.connect()
    try await fileSystem.disconnect()

    let storedCredential = await updates.lastCredential
    #expect(storedCredential?.password == "refresh-token")
    #expect(storedCredential?.token == nil)

    await expectNotConnected {
        _ = try await fileSystem.enumerate(at: RemotePath.root)
    }
    await expectNotConnected {
        try await fileSystem.writeFile(at: RemotePath("/notes.txt"), data: Data("updated".utf8))
    }

    try await fileSystem.connect()
    #expect(await fileSystem.isConnected)
    #expect(await updates.lastCredential?.token == "fresh-token")
}

@Test func dropboxRequestsRequireConnectedAccessToken() async throws {
    let session = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        throw TestFailure("Unexpected request before connect: \(url)")
    }

    let fileSystem = DropboxFileSystem(
        config: ConnectionConfig(name: "Dropbox", backendType: .dropbox, host: ""),
        credential: Credential(token: "stored-token"),
        oauthProvider: DropboxOAuthProvider(
            configuration: OAuthClientConfiguration(
                providerName: "Dropbox",
                clientID: "client-id",
                redirectURI: "com.example.dropbox:/oauth",
                authorizationURL: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
                tokenURL: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
                scopes: ["files.content.read"]
            ),
            session: session
        ),
        session: session
    )

    #expect(await fileSystem.isConnected == false)
    await expectNotConnected {
        _ = try await fileSystem.enumerate(at: RemotePath.root)
    }
}

@Test func dropboxLargeUploadThrowsWhenFileIsTruncatedAfterSessionStart() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mfuse-dropbox-large-\(UUID().uuidString).bin")
    try Data(count: 8 * 1024 * 1024 + 1).write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let session = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        if url.contains("/users/get_current_account") {
            return .http(status: 200, body: Data("{\"name\":{\"display_name\":\"Dropbox User\"}}".utf8))
        }
        if url.contains("/files/get_metadata") {
            return .http(status: 409, body: Data("{\"error_summary\":\"path/not_found/..\"}".utf8))
        }
        if url.contains("/files/upload_session/start") {
            try Data(count: 8 * 1024 * 1024).write(to: fileURL)
            return .http(status: 200, body: Data("{\"session_id\":\"session-1\"}".utf8))
        }
        if url.contains("/files/upload_session/finish") || url.contains("/files/upload_session/append_v2") {
            throw TestFailure("Unexpected upload continuation after truncated file: \(url)")
        }
        throw TestFailure("Unexpected request: \(url)")
    }

    let fileSystem = DropboxFileSystem(
        config: ConnectionConfig(name: "Dropbox", backendType: .dropbox, host: ""),
        credential: Credential(token: "valid-token"),
        oauthProvider: DropboxOAuthProvider(
            configuration: OAuthClientConfiguration(
                providerName: "Dropbox",
                clientID: "client-id",
                redirectURI: "com.example.dropbox:/oauth",
                authorizationURL: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
                tokenURL: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
                scopes: ["files.content.write"]
            ),
            session: session
        ),
        session: session
    )

    try await fileSystem.connect()
    do {
        try await fileSystem.createFile(at: RemotePath("/Large.bin"), from: fileURL)
        Issue.record("Expected truncated file upload to fail")
    } catch let error as RemoteFileSystemError {
        #expect(error.localizedDescription.contains("unexpected EOF"))
    }
}

@Test func dropboxDataRefreshFailureClearsConnectionState() async throws {
    let session = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        if url.contains("/users/get_current_account") {
            return .http(status: 200, body: Data("{\"name\":{\"display_name\":\"Dropbox User\"}}".utf8))
        }
        if url.contains("/files/list_folder") {
            return .http(status: 401, body: Data("{\"error_summary\":\"expired_access_token\"}".utf8))
        }
        if url.contains("/oauth2/token") {
            return .http(
                status: 400,
                body: Data("{\"error\":\"invalid_grant\",\"error_description\":\"Refresh failed\"}".utf8)
            )
        }
        throw TestFailure("Unexpected request: \(url)")
    }

    let fileSystem = DropboxFileSystem(
        config: ConnectionConfig(name: "Dropbox", backendType: .dropbox, host: ""),
        credential: Credential(password: "refresh-token", token: "valid-token"),
        oauthProvider: makeDropboxOAuthProvider(session: session),
        session: session
    )

    try await fileSystem.connect()
    #expect(await fileSystem.isConnected)

    await #expect(throws: RemoteFileSystemError.self) {
        _ = try await fileSystem.enumerate(at: .root)
    }
    #expect(await fileSystem.isConnected == false)
}

@Test func dropboxUploadRetriedUnauthorizedResponseClearsConnectionState() async throws {
    let session = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        if url.contains("/users/get_current_account") {
            return .http(status: 200, body: Data("{\"name\":{\"display_name\":\"Dropbox User\"}}".utf8))
        }
        if url.contains("/files/get_metadata") {
            return .http(status: 409, body: Data("{\"error_summary\":\"path/not_found/..\"}".utf8))
        }
        if url.contains("/files/upload") {
            return .http(status: 401, body: Data("{\"error_summary\":\"expired_access_token\"}".utf8))
        }
        if url.contains("/oauth2/token") {
            return .http(
                status: 200,
                body: Data("{\"access_token\":\"fresh-token\",\"refresh_token\":\"refresh-token\"}".utf8)
            )
        }
        throw TestFailure("Unexpected request: \(url)")
    }

    let fileSystem = DropboxFileSystem(
        config: ConnectionConfig(name: "Dropbox", backendType: .dropbox, host: ""),
        credential: Credential(password: "refresh-token", token: "valid-token"),
        oauthProvider: makeDropboxOAuthProvider(session: session),
        session: session
    )

    try await fileSystem.connect()
    #expect(await fileSystem.isConnected)

    do {
        try await fileSystem.createFile(at: RemotePath("/Retry401.txt"), data: Data("content".utf8))
        Issue.record("Expected retried upload 401 response to fail")
    } catch RemoteFileSystemError.authenticationFailed {
        // Expected.
    } catch {
        Issue.record("Expected authenticationFailed, got \(error)")
    }
    #expect(await fileSystem.isConnected == false)
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

private func makeDropboxOAuthProvider(session: URLSession) -> DropboxOAuthProvider {
    DropboxOAuthProvider(
        configuration: OAuthClientConfiguration(
            providerName: "Dropbox",
            clientID: "client-id",
            redirectURI: "com.example.dropbox:/oauth",
            authorizationURL: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
            tokenURL: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
            scopes: ["files.content.read", "files.content.write"]
        ),
        session: session
    )
}

private final class MockURLProtocol: URLProtocol {
    enum Response {
        case http(status: Int, body: Data, headers: [String: String] = [:])
    }

    typealias Handler = @Sendable (URLRequest) throws -> Response

    static let sessionHeader = "X-MFuse-Mock-Session"

    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    static func register(handler: @escaping Handler, for token: String) {
        lock.lock()
        handlers[token] = handler
        lock.unlock()
    }

    static func unregister(token: String) {
        lock.lock()
        handlers[token] = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: sessionHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let token = request.value(forHTTPHeaderField: Self.sessionHeader),
              let handler = Self.handler(for: token) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            switch try handler(request) {
            case .http(let status, let body, let headers):
                let response = HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: headers
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func handler(for token: String) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[token]
    }
}

private final class MockSessionHandlerCleaner: NSObject, URLSessionDelegate {
    private let token: String

    init(token: String) {
        self.token = token
    }

    deinit {
        MockURLProtocol.unregister(token: token)
    }
}

private actor CredentialUpdateRecorder {
    private(set) var lastCredential: Credential?

    func record(_ credential: Credential) {
        lastCredential = credential
    }
}

private func expectNotConnected(
    _ operation: () async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        try await operation()
        Issue.record("Expected RemoteFileSystemError.notConnected", sourceLocation: sourceLocation)
    } catch RemoteFileSystemError.notConnected {
        return
    } catch {
        Issue.record("Expected RemoteFileSystemError.notConnected, got \(error)", sourceLocation: sourceLocation)
    }
}

private struct TestFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
