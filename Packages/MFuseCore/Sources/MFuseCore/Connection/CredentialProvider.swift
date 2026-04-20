import Foundation

/// Credentials for a remote connection, stored in the Keychain.
public struct Credential: Sendable {
    public let password: String?
    public let privateKey: Data?
    public let passphrase: String?
    public let accessKeyID: String?     // S3
    public let secretAccessKey: String? // S3
    public let token: String?           // OAuth / session token

    public init(
        password: String? = nil,
        privateKey: Data? = nil,
        passphrase: String? = nil,
        accessKeyID: String? = nil,
        secretAccessKey: String? = nil,
        token: String? = nil
    ) {
        self.password = password
        self.privateKey = privateKey
        self.passphrase = passphrase
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.token = token
    }
}

/// Abstraction over credential storage (Keychain in production, in-memory for tests).
public protocol CredentialProvider: Sendable {
    func credential(for connectionID: UUID) async throws -> Credential?
    func store(_ credential: Credential, for connectionID: UUID) async throws
    func delete(for connectionID: UUID) async throws
}
