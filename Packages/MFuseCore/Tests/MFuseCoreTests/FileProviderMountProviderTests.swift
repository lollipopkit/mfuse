import XCTest
@testable import MFuseCore

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
