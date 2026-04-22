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
    @MainActor private var isAuthorizing = false
    @MainActor private var authSession: ASWebAuthenticationSession?

    private static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenURL = "https://oauth2.googleapis.com/token"

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

    public init(clientID: String, redirectURI: String, scopes: [String] = ["https://www.googleapis.com/auth/drive"]) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
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

        let (data, response) = try await URLSession.shared.data(for: request)
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

        let (data, response) = try await URLSession.shared.data(for: request)
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
