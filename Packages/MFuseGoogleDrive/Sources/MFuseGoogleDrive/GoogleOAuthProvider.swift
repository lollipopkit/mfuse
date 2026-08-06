import Foundation
import AuthenticationServices
import CryptoKit
import OSLog
import Security
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Handles Google OAuth 2.0 authentication using ASWebAuthenticationSession.
///
/// Requires a Google Cloud project with Drive API enabled and an OAuth 2.0 client ID
/// configured for macOS/iOS (custom URI scheme redirect).
public final class GoogleOAuthProvider: NSObject, @unchecked Sendable {
    private static let logger = Logger(subsystem: "MFuseGoogleDrive", category: "GoogleOAuthProvider")

    private let clientID: String
    private let redirectURI: String
    private let scopes: [String]
    private let session: URLSession
    @MainActor private var isAuthorizing = false
    @MainActor private var authSession: ASWebAuthenticationSession?

    private static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let aboutURL = "https://www.googleapis.com/drive/v3/about?fields=user(displayName,emailAddress)"

    /// The Google account an access token was issued for.
    public struct Account: Sendable {
        public let displayName: String
        public let email: String?

        public init(displayName: String, email: String?) {
            self.displayName = displayName
            self.email = email
        }
    }

    public struct TokenResponse: Codable, Sendable {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresIn: Int
        public let tokenType: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
        }
    }

    public init(
        clientID: String,
        redirectURI: String,
        scopes: [String] = ["https://www.googleapis.com/auth/drive"],
        session: URLSession = .shared
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.session = session
    }

    /// Perform the OAuth authorization code flow.
    @MainActor
    public func authorize() async throws -> TokenResponse {
        guard !isAuthorizing else {
            throw GoogleDriveError.oauthFailed("Authorization is already in progress")
        }
        isAuthorizing = true
        defer {
            isAuthorizing = false
            authSession = nil
        }

        let codeVerifier = try generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let state = generateState()

        guard var components = URLComponents(string: Self.authURL) else {
            throw GoogleDriveError.oauthFailed("Invalid Google OAuth authorization URL")
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state)
        ]

        guard let authURL = components.url else {
            throw GoogleDriveError.oauthFailed("Failed to construct Google OAuth authorization URL")
        }
        let callbackScheme = URL(string: redirectURI)?.scheme ?? "com.lollipopkit.mfuse"

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { url, error in
                self.authSession = nil
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let url = url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: GoogleDriveError.oauthFailed("No callback URL"))
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            authSession = session
            guard session.start() else {
                authSession = nil
                continuation.resume(
                    throwing: GoogleDriveError.oauthFailed("Failed to start ASWebAuthenticationSession")
                )
                return
            }
        }

        let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let callbackState = callbackComponents?.queryItems?.first(where: { $0.name == "state" })?.value
        guard callbackState == state else {
            throw GoogleDriveError.oauthFailed("Invalid OAuth state in callback")
        }

        guard let code = callbackComponents?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw GoogleDriveError.oauthFailed("No authorization code in callback")
        }

        return try await exchangeCode(code, codeVerifier: codeVerifier)
    }

    /// The account an access token belongs to.
    ///
    /// Google returns no profile with the token, so nothing in a token response says
    /// *whose* it is — and the same client can authorize a different account on a later
    /// sign-in. A refresh token is issued per account, so a caller that keeps one across
    /// sign-ins has to be told which account the new token names before it may carry the
    /// old one over. Answered by the Drive API under the scope already granted, so this
    /// asks for no additional consent.
    public func currentAccount(accessToken: String) async throws -> Account {
        guard let url = URL(string: Self.aboutURL) else {
            throw GoogleDriveError.oauthFailed("Invalid Google Drive account lookup URL")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleDriveError.oauthFailed("Google Drive account lookup failed: invalid HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyDescription = body?.isEmpty == false ? body! : "<empty response body>"
            throw GoogleDriveError.oauthFailed(
                "Google Drive account lookup failed with HTTP \(http.statusCode): \(bodyDescription)"
            )
        }
        let about = try JSONDecoder().decode(AboutResponse.self, from: data)
        return Account(
            displayName: about.user?.displayName ?? "",
            email: about.user?.emailAddress
        )
    }

    /// Refresh an access token using a refresh token.
    public func refresh(refreshToken: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        request.httpBody = formEncodedBody([
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleDriveError.oauthFailed("Token refresh failed: invalid HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyDescription = body?.isEmpty == false ? body! : "<empty response body>"
            throw GoogleDriveError.oauthFailed(
                "Token refresh failed with HTTP \(http.statusCode): \(bodyDescription)"
            )
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: - Private

    private func exchangeCode(_ code: String, codeVerifier: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        request.httpBody = formEncodedBody([
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI)
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GoogleDriveError.oauthFailed("Token exchange failed")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func formEncodedBody(_ items: [URLQueryItem]) -> Data? {
        var components = URLComponents()
        components.queryItems = items
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    private func generateCodeVerifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw GoogleDriveError.oauthFailed("Failed to generate secure random code verifier: \(status)")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateState() -> String {
        UUID().uuidString
    }
}

/// `drive.about` reduced to the account fields the lookup asks for.
private struct AboutResponse: Decodable {
    struct User: Decodable {
        let displayName: String?
        let emailAddress: String?
    }

    let user: User?
}

extension GoogleOAuthProvider: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(AppKit)
        if let window = NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first(where: { $0.isVisible }) {
            return window
        }
        #endif
        #if canImport(UIKit)
        let connectedSceneWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { lhs, rhs in
                lhs.activationState == .foregroundActive && rhs.activationState != .foregroundActive
            }
            .lazy
            .compactMap { scene in
                scene.windows.first(where: \.isKeyWindow)
                    ?? scene.windows.first(where: { !$0.isHidden })
                    ?? scene.windows.first
            }
            .first
        if let window = connectedSceneWindow
            ?? UIApplication.shared.windows.first(where: \.isKeyWindow)
            ?? UIApplication.shared.windows.first(where: { !$0.isHidden })
            ?? UIApplication.shared.windows.first {
            return window
        }
        #endif
        Self.logger.error("Unable to locate a presentation anchor for ASWebAuthenticationSession")
        preconditionFailure("No valid presentation anchor available for ASWebAuthenticationSession")
    }
}
