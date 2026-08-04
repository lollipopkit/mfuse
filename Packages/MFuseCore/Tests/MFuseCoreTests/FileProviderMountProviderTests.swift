import XCTest
@testable import MFuseCore

/// Records what a seam was called with, from closures the provider may run on any
/// executor.
private final class InvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var invocations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(value)
    }
}

final class FileProviderMountProviderTests: XCTestCase {

    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileProviderMountProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        super.tearDown()
    }

    func testItemTypeReturnsNilForMissingPath() throws {
        let provider = FileProviderMountProvider(symlinkBaseURL: temporaryDirectoryURL)
        let missingURL = temporaryDirectoryURL.appendingPathComponent("missing-link")

        let itemType = try provider.itemType(at: missingURL)

        XCTAssertNil(itemType)
    }

    func testItemTypeRecognizesSymbolicLink() throws {
        let provider = FileProviderMountProvider(symlinkBaseURL: temporaryDirectoryURL)
        let destinationURL = temporaryDirectoryURL.appendingPathComponent("destination")
        let symlinkURL = temporaryDirectoryURL.appendingPathComponent("link")
        FileManager.default.createFile(atPath: destinationURL.path, contents: Data())
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: destinationURL)

        let itemType = try provider.itemType(at: symlinkURL)

        XCTAssertEqual(itemType, .typeSymbolicLink)
    }

    /// Cleanup deletes files in a user-visible directory, so ownership is decided by two
    /// things at once: the `<name>-<uuid>` filename MFuse writes, and a destination inside
    /// CloudStorage. Anything else in that directory belongs to the user.
    func testShouldRemoveManagedSymlinkRequiresManagedNameAndMountDestination() throws {
        let fileManager = FileManager.default
        let mountDestinationURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("CloudStorage", isDirectory: true)
            .appendingPathComponent("MFuse-\(UUID().uuidString)", isDirectory: true)

        let managedURL = temporaryDirectoryURL.appendingPathComponent("Backup-\(UUID().uuidString)")
        try fileManager.createSymbolicLink(at: managedURL, withDestinationURL: mountDestinationURL)
        XCTAssertTrue(
            FileProviderMountProvider.shouldRemoveManagedSymlink(at: managedURL, fileManager: fileManager)
        )

        let unmanagedNameURL = temporaryDirectoryURL.appendingPathComponent("notes")
        try fileManager.createSymbolicLink(at: unmanagedNameURL, withDestinationURL: mountDestinationURL)
        XCTAssertFalse(
            FileProviderMountProvider.shouldRemoveManagedSymlink(at: unmanagedNameURL, fileManager: fileManager)
        )

        let foreignDestinationURL = temporaryDirectoryURL
            .appendingPathComponent("Backup-\(UUID().uuidString)")
        try fileManager.createSymbolicLink(
            at: foreignDestinationURL,
            withDestinationURL: fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents", isDirectory: true)
        )
        XCTAssertFalse(
            FileProviderMountProvider.shouldRemoveManagedSymlink(
                at: foreignDestinationURL,
                fileManager: fileManager
            )
        )

        let regularFileURL = temporaryDirectoryURL.appendingPathComponent("Backup-\(UUID().uuidString)")
        fileManager.createFile(atPath: regularFileURL.path, contents: Data())
        XCTAssertFalse(
            FileProviderMountProvider.shouldRemoveManagedSymlink(at: regularFileURL, fileManager: fileManager)
        )
    }

    func testManagedSymlinkFilenameNeedsANameAndAUUID() {
        let uuid = UUID().uuidString
        XCTAssertTrue(FileProviderMountProvider.matchesManagedSymlinkFilename("Backup-\(uuid)"))
        XCTAssertFalse(FileProviderMountProvider.matchesManagedSymlinkFilename(uuid))
        XCTAssertFalse(FileProviderMountProvider.matchesManagedSymlinkFilename("-\(uuid)"))
        XCTAssertFalse(FileProviderMountProvider.matchesManagedSymlinkFilename("Backup-not-a-uuid"))
        // Long enough to reach the UUID parse rather than stopping at the length check.
        XCTAssertFalse(
            FileProviderMountProvider.matchesManagedSymlinkFilename(
                "Backup-" + String(repeating: "x", count: uuid.count)
            )
        )
    }

    /// The bootstrap file is the extension's last config source: before macOS 15 there is
    /// no `domain.userInfo`, and an external reload reaches `unregister` after the
    /// connection is already gone from `SharedStorage`. A domain removal that fails must
    /// therefore leave that file in place, so the still-registered domain keeps working and
    /// the removal can be retried.
    func testUnregisterKeepsTheBootstrapConfigWhenDomainRemovalFails() async throws {
        let provider = FileProviderMountProvider(symlinkBaseURL: temporaryDirectoryURL)
        let config = ConnectionConfig(
            name: "FailedUnregister",
            backendType: .sftp,
            host: "example.com"
        )
        provider.removeRegisteredDomainOverride = { _ in
            throw MountError.unmountFailed("domain removal failed")
        }
        let bootstrapRemovals = InvocationRecorder()
        provider.removeBootstrapConfigOverride = { config in
            bootstrapRemovals.record(config.domainIdentifier)
        }

        do {
            try await provider.unregister(config: config)
            XCTFail("Expected the failed domain removal to surface")
        } catch {
            guard case MountError.unmountFailed = error else {
                return XCTFail("Expected the domain removal failure, got \(error)")
            }
        }

        XCTAssertTrue(
            bootstrapRemovals.invocations.isEmpty,
            "the bootstrap config was removed even though its domain is still registered"
        )
    }

    /// Once the domain is gone the removal has to be reported as done: a failure to clear
    /// the bookkeeping behind it would have the caller keep a connection whose domain no
    /// longer exists.
    func testUnregisterSucceedsWhenOnlyTheBootstrapRemovalFails() async throws {
        let provider = FileProviderMountProvider(symlinkBaseURL: temporaryDirectoryURL)
        let config = ConnectionConfig(
            name: "BootstrapRemovalFailed",
            backendType: .sftp,
            host: "example.com"
        )
        let domainRemovals = InvocationRecorder()
        provider.removeRegisteredDomainOverride = { config in
            domainRemovals.record(config.domainIdentifier)
        }
        provider.removeBootstrapConfigOverride = { _ in
            throw MountError.unmountFailed("bootstrap removal failed")
        }

        try await provider.unregister(config: config)

        XCTAssertEqual(domainRemovals.invocations, [config.domainIdentifier])
    }

    func testLegacySymlinkBaseURLUsesSharedContainerLayout() throws {
        let containerURL = temporaryDirectoryURL.appendingPathComponent("group-container", isDirectory: true)
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)

        let legacyURL = try XCTUnwrap(
            FileProviderMountProvider.legacySymlinkBaseURL(containerURL: containerURL)
        )

        XCTAssertEqual(
            legacyURL,
            containerURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("MFuse", isDirectory: true)
                .appendingPathComponent("Shortcuts", isDirectory: true)
        )
    }
}
