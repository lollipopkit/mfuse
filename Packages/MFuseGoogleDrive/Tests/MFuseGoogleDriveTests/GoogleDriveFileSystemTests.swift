import Foundation
import Testing

@testable import MFuseGoogleDrive
import MFuseTestSupport

@Test func placeholder() async throws {
    // Integration tests require Google OAuth credentials
}

/// The account lookup is what tells a caller whose token it just received, so it has to
/// name the account and to fail loudly rather than answer for an unknown one.
@Test func googleOAuthProviderReadsAccountForAccessToken() async throws {
    let session = try makeMockSession { request in
        let url = try #require(request.url?.absoluteString)
        #expect(url.hasPrefix("https://www.googleapis.com/drive/v3/about"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        return .http(
            status: 200,
            body: Data("""
            {"user":{"displayName":"Drive User","emailAddress":"drive@example.com"}}
            """.utf8)
        )
    }

    let provider = GoogleOAuthProvider(
        clientID: "client-id",
        redirectURI: "com.example.mfuse:/oauth",
        session: session
    )
    let account = try await provider.currentAccount(accessToken: "access-token")

    #expect(account.displayName == "Drive User")
    #expect(account.email == "drive@example.com")
}

@Test func googleOAuthProviderReportsFailedAccountLookup() async throws {
    let session = try makeMockSession { _ in
        .http(status: 401, body: Data("{\"error\":\"invalid_token\"}".utf8))
    }

    let provider = GoogleOAuthProvider(
        clientID: "client-id",
        redirectURI: "com.example.mfuse:/oauth",
        session: session
    )

    await #expect(throws: GoogleDriveError.self) {
        _ = try await provider.currentAccount(accessToken: "expired-token")
    }
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
