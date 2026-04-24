import Foundation

public struct OAuthClientConfiguration: Sendable, Equatable {
    public let providerName: String
    public let clientID: String
    public let redirectURI: String
    public let authorizationURL: URL
    public let tokenURL: URL
    public let scopes: [String]
    public let additionalAuthorizationQueryItems: [URLQueryItem]
    public let additionalTokenParameters: [URLQueryItem]

    public init(
        providerName: String,
        clientID: String,
        redirectURI: String,
        authorizationURL: URL,
        tokenURL: URL,
        scopes: [String],
        additionalAuthorizationQueryItems: [URLQueryItem] = [],
        additionalTokenParameters: [URLQueryItem] = []
    ) {
        self.providerName = providerName
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.authorizationURL = authorizationURL
        self.tokenURL = tokenURL
        self.scopes = scopes
        self.additionalAuthorizationQueryItems = additionalAuthorizationQueryItems
        self.additionalTokenParameters = additionalTokenParameters
    }
}

public enum OAuthConfigurationError: LocalizedError {
    case missingValue(providerName: String, key: String)
    case invalidURL(providerName: String, key: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .missingValue(let providerName, let key):
            return MFuseCoreL10n.string(
                "oauth.config.missing",
                fallback: "%1$@ OAuth is not configured. Missing value for %2$@.",
                providerName,
                key
            )
        case .invalidURL(let providerName, let key, let value):
            return MFuseCoreL10n.string(
                "oauth.config.invalidURL",
                fallback: "%1$@ OAuth has an invalid URL for %2$@: %3$@",
                providerName,
                key,
                value
            )
        }
    }
}

public enum OAuthBundleConfigurationLoader {
    public static func requiredString(
        bundle: Bundle,
        key: String,
        providerName: String
    ) throws -> String {
        let rawValue = (bundle.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawValue.isEmpty,
              !rawValue.contains("YOUR_"),
              !rawValue.contains("REPLACE_WITH") else {
            throw OAuthConfigurationError.missingValue(providerName: providerName, key: key)
        }
        return rawValue
    }

    public static func requiredURL(
        bundle: Bundle,
        key: String,
        providerName: String
    ) throws -> URL {
        let value = try requiredString(bundle: bundle, key: key, providerName: providerName)
        guard let url = URL(string: value) else {
            throw OAuthConfigurationError.invalidURL(
                providerName: providerName,
                key: key,
                value: value
            )
        }
        return url
    }
}
