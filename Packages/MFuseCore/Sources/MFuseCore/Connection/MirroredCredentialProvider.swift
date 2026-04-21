import Foundation

/// Uses Keychain as the app-facing credential store while mirroring a provider-readable
/// snapshot into the shared App Group container for the File Provider extension.
public final class MirroredCredentialProvider: CredentialProvider, @unchecked Sendable {

    private let primary: CredentialProvider
    public let sharedStore: SharedCredentialStore

    public init(
        primary: CredentialProvider,
        sharedStore: SharedCredentialStore = SharedCredentialStore()
    ) {
        self.primary = primary
        self.sharedStore = sharedStore
    }

    public func credential(for connectionID: UUID) async throws -> Credential? {
        let mirroredCredential = try sharedStore.credential(for: connectionID)
        let primaryCredential = try await primary.credential(for: connectionID)

        if let mirroredCredential {
            if primaryCredential != mirroredCredential {
                try? await primary.store(mirroredCredential, for: connectionID)
            }
            return mirroredCredential
        }

        guard let primaryCredential else {
            return nil
        }

        try sharedStore.store(primaryCredential, for: connectionID)
        return primaryCredential
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
