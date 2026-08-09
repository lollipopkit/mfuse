import Foundation
import MFuseCore
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

/// A refresh token Google no longer honours has to read as an authentication failure: the
/// File Provider extension maps that one to `notAuthenticated`, which is what asks the user
/// to sign in again. Anything else leaves the mount reporting an unreachable server for a
/// grant that only a new sign-in can replace.
///
/// Both statuses are exercised because Google refuses `invalid_grant` with either one, and
/// the caller cannot tell which it will get.
@Test(arguments: [400, 401])
func googleOAuthProviderReportsRevokedRefreshTokenAsAuthenticationFailure(status: Int) async throws {
    let session = try makeMockSession { request in
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
        return .http(status: status, body: Data("{\"error\":\"invalid_grant\"}".utf8))
    }

    let provider = GoogleOAuthProvider(
        clientID: "client-id",
        redirectURI: "com.example.mfuse:/oauth",
        session: session
    )

    do {
        _ = try await provider.refresh(refreshToken: "revoked-refresh-token")
        Issue.record("Expected RemoteFileSystemError.authenticationFailed")
    } catch RemoteFileSystemError.authenticationFailed {
        // Expected.
    } catch {
        Issue.record("Expected RemoteFileSystemError.authenticationFailed, got \(error)")
    }
}

/// Google failing to answer is not the grant being gone: reporting it as an authentication
/// failure would send the user through a sign-in that changes nothing.
@Test func googleOAuthProviderKeepsServerSideRefreshFailureDistinct() async throws {
    let session = try makeMockSession { _ in
        .http(status: 503, body: Data("{\"error\":\"backend_error\"}".utf8))
    }

    let provider = GoogleOAuthProvider(
        clientID: "client-id",
        redirectURI: "com.example.mfuse:/oauth",
        session: session
    )

    await #expect(throws: GoogleDriveError.self) {
        _ = try await provider.refresh(refreshToken: "refresh-token")
    }
}

/// A refresh stopped on the way out is not a server that could not be reached: an unmount,
/// a quit and an operation timeout all cancel the work holding the token refresh, and every
/// layer above reads cancellation as its own. Calling it `connectionFailed` put "could not
/// reach Google Drive" on a mount the user had just taken down.
@Test func googleDriveKeepsCancellationOutOfTheRefreshFailureMapping() async throws {
    let cancellation = GoogleDriveFileSystem.refreshFailure(CancellationError())
    #expect(cancellation is CancellationError)

    let cancelledRequest = GoogleDriveFileSystem.refreshFailure(URLError(.cancelled))
    #expect((cancelledRequest as? URLError)?.code == .cancelled)

    // Everything else still reads as the token endpoint failing to answer, and a grant
    // Google has stopped honouring still passes through as the authentication failure the
    // provider classified it as.
    let unreachable = GoogleDriveFileSystem.refreshFailure(URLError(.timedOut))
    guard case .connectionFailed = unreachable as? RemoteFileSystemError else {
        Issue.record("Expected RemoteFileSystemError.connectionFailed, got \(unreachable)")
        return
    }

    let revoked = GoogleDriveFileSystem.refreshFailure(RemoteFileSystemError.authenticationFailed)
    guard case .authenticationFailed = revoked as? RemoteFileSystemError else {
        Issue.record("Expected RemoteFileSystemError.authenticationFailed, got \(revoked)")
        return
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
