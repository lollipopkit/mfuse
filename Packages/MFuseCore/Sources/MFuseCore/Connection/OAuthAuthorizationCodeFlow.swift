import AuthenticationServices
import CryptoKit
import Foundation
import OSLog
import Security
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

public struct OAuthTokenResponse: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int?
    public let tokenType: String?
    public let scope: String?
    public let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
        case idToken = "id_token"
    }
}

public final class OAuthAuthorizationCodeFlow: NSObject, @unchecked Sendable {
    private static let logger = Logger(subsystem: "MFuseCore", category: "OAuthAuthorizationCodeFlow")

    private let configuration: OAuthClientConfiguration
    private let session: URLSession
    @MainActor private var temporaryPresentationAnchor: ASPresentationAnchor?
    @MainActor private var isAuthorizing = false
    @MainActor private var authSession: ASWebAuthenticationSession?

    public init(
        configuration: OAuthClientConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    @MainActor
    public func authorize() async throws -> OAuthTokenResponse {
        guard !isAuthorizing else {
            throw RemoteFileSystemError.operationFailed(
                "\(configuration.providerName) authorization is already in progress"
            )
        }
        isAuthorizing = true
        defer {
            isAuthorizing = false
            authSession = nil
            temporaryPresentationAnchor = nil
        }

        let codeVerifier = try Self.generateCodeVerifier()
        let codeChallenge = Self.generateCodeChallenge(from: codeVerifier)
        let state = UUID().uuidString

        var components = URLComponents(url: configuration.authorizationURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ] + configuration.additionalAuthorizationQueryItems

        guard let authorizationURL = components?.url else {
            throw RemoteFileSystemError.operationFailed(
                "Failed to construct \(configuration.providerName) authorization URL"
            )
        }

        let callbackScheme = URL(string: configuration.redirectURI)?.scheme
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let webAuthenticationSession = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: callbackScheme
            ) { url, error in
                self.authSession = nil
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: RemoteFileSystemError.operationFailed("Missing OAuth callback URL"))
                }
            }

            webAuthenticationSession.prefersEphemeralWebBrowserSession = false
            webAuthenticationSession.presentationContextProvider = self
            authSession = webAuthenticationSession

            guard webAuthenticationSession.start() else {
                self.authSession = nil
                continuation.resume(
                    throwing: RemoteFileSystemError.operationFailed(
                        "Failed to start \(self.configuration.providerName) authorization session"
                    )
                )
                return
            }
        }

        let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let callbackState = callbackComponents?.queryItems?.first(where: { $0.name == "state" })?.value
        guard callbackState == state else {
            throw RemoteFileSystemError.operationFailed("Invalid OAuth state")
        }

        guard let code = callbackComponents?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw RemoteFileSystemError.operationFailed("Missing authorization code")
        }

        return try await exchangeAuthorizationCode(code, codeVerifier: codeVerifier)
    }

    public func refresh(refreshToken: String) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncodedBody([
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ] + configuration.additionalTokenParameters)
        return try await executeTokenRequest(request, action: "token refresh")
    }

    private func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String
    ) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncodedBody([
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
        ] + configuration.additionalTokenParameters)
        return try await executeTokenRequest(request, action: "token exchange")
    }

    private func executeTokenRequest(
        _ request: URLRequest,
        action: String
    ) async throws -> OAuthTokenResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteFileSystemError.operationFailed(
                "\(configuration.providerName) \(action) failed: invalid HTTP response"
            )
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = body?.isEmpty == false ? body! : "<empty response body>"
            throw RemoteFileSystemError.operationFailed(
                "\(configuration.providerName) \(action) failed with HTTP \(http.statusCode): \(message)"
            )
        }
        return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
    }

    private static func formEncodedBody(_ items: [URLQueryItem]) -> Data? {
        var components = URLComponents()
        components.queryItems = items
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    private static func generateCodeVerifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw RemoteFileSystemError.operationFailed("Failed to generate OAuth code verifier: \(status)")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension OAuthAuthorizationCodeFlow: ASWebAuthenticationPresentationContextProviding {
    @MainActor
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
        if let temporaryPresentationAnchor {
            return temporaryPresentationAnchor
        }

        Self.logger.error(
            "Unable to locate a presentation anchor for ASWebAuthenticationSession; creating a temporary anchor"
        )
        let temporaryPresentationAnchor = makeTemporaryPresentationAnchor()
        self.temporaryPresentationAnchor = temporaryPresentationAnchor
        return temporaryPresentationAnchor
    }

    @MainActor
    private func makeTemporaryPresentationAnchor() -> ASPresentationAnchor {
        #if canImport(AppKit)
        let window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.alphaValue = 0
        window.orderOut(nil)
        return window
        #elseif canImport(UIKit)
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundInactive })
            ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first

        let window: UIWindow
        if let windowScene {
            window = UIWindow(windowScene: windowScene)
        } else {
            window = UIWindow(frame: CGRect(x: -10_000, y: -10_000, width: 1, height: 1))
        }
        window.frame = CGRect(x: -10_000, y: -10_000, width: 1, height: 1)
        window.rootViewController = UIViewController()
        window.isHidden = true
        return window
        #else
        fatalError("ASPresentationAnchor is unsupported on this platform")
        #endif
    }
}
