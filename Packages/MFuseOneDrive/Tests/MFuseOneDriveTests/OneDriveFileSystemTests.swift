import Foundation
import Testing

@testable import MFuseOneDrive
import MFuseCore

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
            return .http(status: 202, body: Data(), headers: ["Location": "https://monitor.example/copy"])
        }
        if url == "https://monitor.example/copy" {
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
