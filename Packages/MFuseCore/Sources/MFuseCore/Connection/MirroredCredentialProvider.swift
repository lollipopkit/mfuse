import Foundation

/// Uses Keychain as the app-facing credential store while mirroring credentials
/// into the shared credential store used by the File Provider extension.
public final class MirroredCredentialProvider: CredentialProvider, @unchecked Sendable {

    private let primary: CredentialProvider
    public let sharedStore: SharedCredentialStore

    public init(
        primary: CredentialProvider,
        sharedStore: SharedCredentialStore = SharedCredentialStore(allowLegacyKeychainMigration: true)
    ) {
        self.primary = primary
        self.sharedStore = sharedStore
    }

    public func credential(for connectionID: UUID) async throws -> Credential? {
        let primaryCredential = try await primary.credential(for: connectionID)
        if let primaryCredential {
            do {
                try sharedStore.store(primaryCredential, for: connectionID)
            } catch {
                // Best-effort mirror repair for the File Provider extension.
            }
            return primaryCredential
        }

        return try sharedStore.credential(for: connectionID)
    }

    public func store(_ credential: Credential, for connectionID: UUID) async throws {
        try await primary.store(credential, for: connectionID)
        try sharedStore.store(credential, for: connectionID)
    }

    public func delete(for connectionID: UUID) async throws {
        try await primary.delete(for: connectionID)
        try sharedStore.delete(for: connectionID)
    }
}
