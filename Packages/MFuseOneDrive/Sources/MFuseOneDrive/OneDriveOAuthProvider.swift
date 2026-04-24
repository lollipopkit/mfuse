import Foundation
import MFuseCore

public struct OneDriveOAuthAccount: Sendable, Equatable {
    public let credential: Credential
    public let displayName: String
    public let email: String?

    public init(credential: Credential, displayName: String, email: String?) {
        self.credential = credential
        self.displayName = displayName
        self.email = email
    }
}

public final class OneDriveOAuthProvider: @unchecked Sendable {
    private enum Constants {
        static let clientIDKey = "MFOneDriveClientID"
        static let redirectURIKey = "MFOneDriveRedirectURI"
        static let authorityKey = "MFOneDriveAuthority"
        static let graphMeURL = URL(string: "https://graph.microsoft.com/v1.0/me?$select=displayName,mail,userPrincipalName")!
        static let scopes = [
            "Files.ReadWrite",
            "offline_access",
            "User.Read",
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
    ) throws -> OneDriveOAuthProvider {
        let providerName = "Microsoft OneDrive"
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
        let configuredAuthority = (bundle.object(forInfoDictionaryKey: Constants.authorityKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let authority = configuredAuthority.isEmpty ? "common" : configuredAuthority
        let authorizationURLString = "https://login.microsoftonline.com/\(authority)/oauth2/v2.0/authorize"
        let tokenURLString = "https://login.microsoftonline.com/\(authority)/oauth2/v2.0/token"
        guard let authorizationURL = URL(string: authorizationURLString) else {
            throw OAuthConfigurationError.invalidURL(
                providerName: providerName,
                key: Constants.authorityKey,
                value: authorizationURLString
            )
        }
        guard let tokenURL = URL(string: tokenURLString) else {
            throw OAuthConfigurationError.invalidURL(
                providerName: providerName,
                key: Constants.authorityKey,
                value: tokenURLString
            )
        }
        let configuration = OAuthClientConfiguration(
            providerName: providerName,
            clientID: clientID,
            redirectURI: redirectURI,
            authorizationURL: authorizationURL,
            tokenURL: tokenURL,
            scopes: Constants.scopes
        )
        return OneDriveOAuthProvider(configuration: configuration, session: session)
    }

    @MainActor
    public func authorize() async throws -> OneDriveOAuthAccount {
        let tokenResponse = try await flow.authorize()
        let identity = try await currentIdentity(accessToken: tokenResponse.accessToken)
        return OneDriveOAuthAccount(
            credential: credential(from: tokenResponse, fallbackRefreshToken: nil),
            displayName: identity.displayName,
            email: identity.email
        )
    }

    public func refresh(refreshToken: String) async throws -> OAuthTokenResponse {
        try await flow.refresh(refreshToken: refreshToken)
    }

    public func currentAccount(accessToken: String) async throws -> OneDriveOAuthAccount {
        let identity = try await currentIdentity(accessToken: accessToken)
        return OneDriveOAuthAccount(
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

    private func currentIdentity(accessToken: String) async throws -> OneDriveIdentity {
        var request = URLRequest(url: Constants.graphMeURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteFileSystemError.operationFailed("OneDrive account lookup failed: invalid HTTP response")
        }
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "<empty response body>"
            throw RemoteFileSystemError.operationFailed(
                "OneDrive account lookup failed with HTTP \(http.statusCode): \(message)"
            )
        }
        return try JSONDecoder().decode(OneDriveIdentity.self, from: data)
    }
}

private struct OneDriveIdentity: Decodable {
    let displayName: String
    let mail: String?
    let userPrincipalName: String?

    var email: String? { mail ?? userPrincipalName }
}
