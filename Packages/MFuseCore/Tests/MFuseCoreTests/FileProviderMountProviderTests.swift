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

/// Holds the first mount-URL resolution so a second one can overtake it.
private actor ResolutionGate {
    private var resolutions = 0
    private var isOpen = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    var resolutionCount: Int { resolutions }

    func isFirstResolution() -> Bool {
        resolutions += 1
        return resolutions == 1
    }

    func wait() async {
        entered = true
        let pendingEntryWaiters = entryWaiters
        entryWaiters = []
        for continuation in pendingEntryWaiters {
            continuation.resume()
        }
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let pendingWaiters = waiters
        waiters = []
        for continuation in pendingWaiters {
            continuation.resume()
        }
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
        let bootstrapRemovals = InvocationRecorder()
        provider.removeBootstrapConfigOverride = { config in
            bootstrapRemovals.record(config.domainIdentifier)
            throw MountError.unmountFailed("bootstrap removal failed")
        }

        try await provider.unregister(config: config)

        XCTAssertEqual(domainRemovals.invocations, [config.domainIdentifier])
        // Attempted, not skipped: the point is that its failure is tolerated, not that the
        // step was never reached.
        XCTAssertEqual(bootstrapRemovals.invocations, [config.domainIdentifier])
    }

    /// A rename moves the domain's CloudStorage path. Resolving that path and writing the
    /// link have to be one operation, or a pass holding the older destination finishes
    /// after a later pass wrote the newer one and puts the stale link back.
    func testOverlappingCreateSymlinkKeepsTheNewestDestination() async throws {
        let provider = FileProviderMountProvider(symlinkBaseURL: temporaryDirectoryURL)
        let config = ConnectionConfig(
            name: "Renamed",
            backendType: .sftp,
            host: "example.com"
        )
        let olderDestinationURL = temporaryDirectoryURL.appendingPathComponent("older-mount")
        let newerDestinationURL = temporaryDirectoryURL.appendingPathComponent("newer-mount")
        for destination in [olderDestinationURL, newerDestinationURL] {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }

        // The first resolution answers with the pre-rename path and is held there; every
        // one after it answers with the path the rename moved the domain to.
        let gate = ResolutionGate()
        provider.resolveMountURLOverride = { _ in
            if await gate.isFirstResolution() {
                await gate.wait()
                return olderDestinationURL
            }
            return newerDestinationURL
        }

        let stale = Task { try await provider.createSymlink(for: config) }
        await gate.waitUntilEntered()
        let current = Task { try await provider.createSymlink(for: config) }

        // Handshake, not a fixed number of yields: this resumes once the second call is
        // actually parked behind the first, which is the only state in which the assertion
        // below means anything. Bounded, so a regression fails the test instead of hanging
        // the suite on a queue that will never fill.
        var queuedOperations = 0
        for _ in 0..<1000 {
            queuedOperations = await provider.queuedOperationCount(for: config)
            if queuedOperations > 0 { break }
            await Task.yield()
        }
        XCTAssertEqual(
            queuedOperations,
            1,
            "the second createSymlink never queued behind the first"
        )
        let resolutionsDuringTheHeldOperation = await gate.resolutionCount
        XCTAssertEqual(
            resolutionsDuringTheHeldOperation,
            1,
            "a second createSymlink resolved a destination while the first was mid-operation"
        )

        await gate.open()
        _ = try await stale.value
        _ = try await current.value

        // The queued pass ran once the first released, and resolved for itself — so the
        // destination it would write is never older than the pass before it.
        let totalResolutions = await gate.resolutionCount
        XCTAssertEqual(totalResolutions, 2)

        // The link still points at the first pass's destination, and deliberately so:
        // these temporary paths are not under `~/Library/CloudStorage`, so the ownership
        // test refuses to replace the existing link and the queued pass leaves it alone.
        // Asserting it keeps the outcome of this scenario written down — what the
        // serialization above buys is that the second pass resolves *after* the first has
        // finished, not that it overwrites what a real mount would have let it replace.
        let symlinkURL = FileProviderMountProvider.symlinkURL(
            for: config,
            baseDir: temporaryDirectoryURL
        )
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path)
        XCTAssertEqual(destination, olderDestinationURL.path)
    }

    /// A link whose destination is gone resolves as absent to `fileExists`, so the
    /// occupied-path check used to wave it through and the creation behind it failed with
    /// EEXIST — surfacing as a mount error for a path the ownership test had just decided
    /// to leave alone.
    func testCreateSymlinkLeavesADanglingForeignLinkAlone() async throws {
        let provider = FileProviderMountProvider(symlinkBaseURL: temporaryDirectoryURL)
        let config = ConnectionConfig(
            name: "OccupiedByADanglingLink",
            backendType: .sftp,
            host: "example.com"
        )
        let mountURL = temporaryDirectoryURL.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        provider.resolveMountURLOverride = { _ in mountURL }

        let symlinkURL = FileProviderMountProvider.symlinkURL(
            for: config,
            baseDir: temporaryDirectoryURL
        )
        let missingDestinationURL = temporaryDirectoryURL.appendingPathComponent("gone")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: missingDestinationURL
        )

        let createdURL = try await provider.createSymlink(for: config)

        XCTAssertNil(createdURL)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path),
            missingDestinationURL.path,
            "a dangling link that is not ours was replaced"
        )
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
