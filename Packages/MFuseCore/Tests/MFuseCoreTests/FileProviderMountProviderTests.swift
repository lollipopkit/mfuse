import XCTest
@testable import MFuseCore

final class FileProviderMountProviderTests: XCTestCase {

    private var temporaryDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileProviderMountProviderTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        super.tearDown()
    }

    func testItemTypeReturnsNilForMissingPath() throws {
        let provider = FileProviderMountProvider()
        let missingURL = temporaryDirectoryURL.appendingPathComponent("missing-link")

        let itemType = try provider.itemType(at: missingURL)

        XCTAssertNil(itemType)
    }

    func testItemTypeRecognizesSymbolicLink() throws {
        let provider = FileProviderMountProvider()
        let destinationURL = temporaryDirectoryURL.appendingPathComponent("destination")
        let symlinkURL = temporaryDirectoryURL.appendingPathComponent("link")
        FileManager.default.createFile(atPath: destinationURL.path, contents: Data())
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: destinationURL)

        let itemType = try provider.itemType(at: symlinkURL)

        XCTAssertEqual(itemType, .typeSymbolicLink)
    }
}
