import Foundation
import MFuseCore

/// The Google OAuth client a token is authorized against and renewed with.
///
/// A refresh token only renews against the client that issued it, so a connection keeps
/// using the client it was authorized with.
public struct GoogleOAuthClient: Sendable, Equatable {
    public let clientID: String
    public let redirectURI: String

    public init(clientID: String, redirectURI: String) {
        self.clientID = clientID
        self.redirectURI = redirectURI
    }

    static let clientIDKey = "MFGoogleClientID"
    private static let clientIDSuffix = ".apps.googleusercontent.com"

    /// The client bundled with the app, from the `MFGoogleClientID` Info.plist key.
    ///
    /// The redirect URI is derived rather than configured: an iOS-type Google client
    /// accepts the reversed client ID as its custom scheme, so there is nothing to keep in
    /// sync with the Cloud Console.
    public static func builtIn(bundle: Bundle = .main) throws -> GoogleOAuthClient {
        let clientID = try OAuthBundleConfigurationLoader.requiredString(
            bundle: bundle,
            key: clientIDKey,
            providerName: "Google Drive"
        )
        return GoogleOAuthClient(clientID: clientID, redirectURI: try redirectURI(forClientID: clientID))
    }

    /// `1234-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.1234-abc:/oauth2redirect`.
    static func redirectURI(forClientID clientID: String) throws -> String {
        guard clientID.hasSuffix(clientIDSuffix) else {
            throw GoogleDriveError.oauthFailed("\(clientIDKey) is not a Google OAuth client ID")
        }
        let identifier = clientID.dropLast(clientIDSuffix.count)
        guard !identifier.isEmpty else {
            throw GoogleDriveError.oauthFailed("\(clientIDKey) is not a Google OAuth client ID")
        }
        return "com.googleusercontent.apps.\(identifier):/oauth2redirect"
    }

    /// The user-supplied client that connections created before the bundled client
    /// recorded in their parameters, or `nil` for a connection that uses the bundled one.
    ///
    /// TODO: remove once connections authorized against a user-supplied client are no
    /// longer expected; they switch to the bundled client on their next sign-in.
    public static func legacy(from parameters: [String: String]) -> GoogleOAuthClient? {
        guard let clientID = ConnectionConfig.trimmedParameter(parameters["clientID"]),
              let redirectURI = ConnectionConfig.trimmedParameter(parameters["redirectURI"]) else {
            return nil
        }
        return GoogleOAuthClient(clientID: clientID, redirectURI: redirectURI)
    }
}
