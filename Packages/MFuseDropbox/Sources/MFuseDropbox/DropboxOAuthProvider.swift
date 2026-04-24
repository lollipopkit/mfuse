import Foundation
import MFuseCore

public struct DropboxOAuthAccount: Sendable, Equatable {
    public let credential: Credential
    public let displayName: String
    public let email: String?

    public init(credential: Credential, displayName: String, email: String?) {
        self.credential = credential
        self.displayName = displayName
        self.email = email
    }
}

public final class DropboxOAuthProvider: @unchecked Sendable {
    private enum Constants {
        static let clientIDKey = "MFDropboxClientID"
        static let redirectURIKey = "MFDropboxRedirectURI"
        static let authorizationURL = URL(string: "https://www.dropbox.com/oauth2/authorize")!
        static let tokenURL = URL(string: "https://api.dropboxapi.com/oauth2/token")!
        static let accountURL = URL(string: "https://api.dropboxapi.com/2/users/get_current_account")!
        static let scopes = [
            "files.metadata.read",
            "files.metadata.write",
            "files.content.read",
            "files.content.write",
        ]
    }

    private let configuration: OAuthClientConfiguration
    private let flow: OAuthAuthorizationCodeFlow
    private let session: URLSession

    public init(
        configuration: OAuthClientConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.flow = OAuthAuthorizationCodeFlow(configuration: configuration, session: session)
        self.session = session
    }

    public static func builtIn(
        bundle: Bundle = .main,
        session: URLSession = .shared
    ) throws -> DropboxOAuthProvider {
        let providerName = "Dropbox"
        let clientID = try OAuthBundleConfigurationLoader.requiredString(
            bundle: bundle,
            key: Constants.clientIDKey,
            providerName: providerName
        )
        let redirectURI = try OAuthBundleConfigurationLoader.requiredString(
            bundle: bundle,
            key: Constants.redirectURIKey,
            providerName: providerName
        )
        let configuration = OAuthClientConfiguration(
            providerName: providerName,
            clientID: clientID,
            redirectURI: redirectURI,
            authorizationURL: Constants.authorizationURL,
            tokenURL: Constants.tokenURL,
            scopes: Constants.scopes,
            additionalAuthorizationQueryItems: [
                URLQueryItem(name: "token_access_type", value: "offline"),
            ]
        )
        return DropboxOAuthProvider(configuration: configuration, session: session)
    }

    @MainActor
    public func authorize() async throws -> DropboxOAuthAccount {
        let tokenResponse = try await flow.authorize()
        let identity = try await currentAccount(accessToken: tokenResponse.accessToken)
        return DropboxOAuthAccount(
            credential: credential(from: tokenResponse, fallbackRefreshToken: nil),
            displayName: identity.displayName,
            email: identity.email
        )
    }

    public func refresh(refreshToken: String) async throws -> OAuthTokenResponse {
        try await flow.refresh(refreshToken: refreshToken)
    }

    public func currentAccount(accessToken: String) async throws -> DropboxOAuthAccount {
        let identity = try await currentIdentity(accessToken: accessToken)
        return DropboxOAuthAccount(
            credential: Credential(token: accessToken),
            displayName: identity.displayName,
            email: identity.email
        )
    }

    public func credential(
        from tokenResponse: OAuthTokenResponse,
        fallbackRefreshToken: String?
    ) -> Credential {
        Credential(
            password: tokenResponse.refreshToken ?? fallbackRefreshToken,
            token: tokenResponse.accessToken
        )
    }

    private func currentIdentity(accessToken: String) async throws -> DropboxIdentity {
        var request = URLRequest(url: Constants.accountURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteFileSystemError.operationFailed("Dropbox account lookup failed: invalid HTTP response")
        }
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "<empty response body>"
            throw RemoteFileSystemError.operationFailed(
                "Dropbox account lookup failed with HTTP \(http.statusCode): \(message)"
            )
        }
        return try JSONDecoder().decode(DropboxIdentity.self, from: data)
    }
}

private struct DropboxIdentity: Decodable {
    struct Name: Decodable {
        let displayName: String

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
        }
    }

    let name: Name
    let email: String?

    var displayName: String { name.displayName }
}
