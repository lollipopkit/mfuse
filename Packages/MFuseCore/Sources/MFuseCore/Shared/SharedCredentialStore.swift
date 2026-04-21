import Foundation
import os.log

/// Stores provider-readable credential snapshots in the App Group container
/// so the File Provider extension does not need direct Keychain access.
public final class SharedCredentialStore: @unchecked Sendable {

    private static let logger = Logger(
        subsystem: "com.lollipopkit.mfuse",
        category: "SharedCredentialStore"
    )

    public let containerURL: URL

    public init(
        allowFallbackToTemporaryDirectory: Bool = false,
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupConstants.groupIdentifier
        )
    ) {
        if let containerURL {
            self.containerURL = containerURL
        } else if allowFallbackToTemporaryDirectory {
            self.containerURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MFuseSharedCredentials", isDirectory: true)
        } else {
            preconditionFailure(
                "SharedCredentialStore failed to resolve App Group container for \(AppGroupConstants.groupIdentifier). " +
                "Pass allowFallbackToTemporaryDirectory: true only for tests, or inject an explicit containerURL."
            )
        }
    }

    public func credential(for connectionID: UUID) throws -> Credential? {
        let url = credentialFileURL(for: connectionID)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        do {
            return try JSONDecoder().decode(Credential.self, from: data)
        } catch {
            Self.logger.error(
                "Failed to decode shared credential at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    public func store(_ credential: Credential, for connectionID: UUID) throws {
        try ensureDirectoryExists()
        let url = credentialFileURL(for: connectionID)
        let data = try JSONEncoder().encode(credential)
        try data.write(to: url, options: .atomic)
    }

    public func delete(for connectionID: UUID) throws {
        let url = credentialFileURL(for: connectionID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func credentialURL(for connectionID: UUID) throws -> URL {
        credentialFileURL(for: connectionID)
    }

    private var credentialsDirectoryURL: URL {
        containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MFuse", isDirectory: true)
            .appendingPathComponent("Credentials", isDirectory: true)
    }

    private func credentialFileURL(for connectionID: UUID) -> URL {
        credentialsDirectoryURL.appendingPathComponent("\(connectionID.uuidString).json")
    }

    private func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: credentialsDirectoryURL, withIntermediateDirectories: true)
    }
}
