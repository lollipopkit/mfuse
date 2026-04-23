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
    let items = try await fileSystem.enumerate(at: .root)
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
}

private func makeMockSession(
    handler: @escaping @Sendable (URLRequest) throws -> MockURLProtocol.Response
) throws -> URLSession {
    MockURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class MockURLProtocol: URLProtocol {
    enum Response {
        case http(status: Int, body: Data, headers: [String: String] = [:])
    }

    static var handler: (@Sendable (URLRequest) throws -> Response)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
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
}

private struct TestFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
