import XCTest
@testable import MFuseCore

final class ContentCacheTests: XCTestCase {

    private var rootURL: URL!
    private var cache: ContentCache!

    override func setUp() async throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MFuseContentCache_\(UUID().uuidString)", isDirectory: true)
        cache = ContentCache(rootURL: rootURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func testStoreAndReadCachedURL() async throws {
        let item = RemoteItem(
            path: "/docs/file.txt",
            type: .file,
            size: 5,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            permissions: 0o644
        )

        let url = try await cache.store(data: Data("hello".utf8), for: item)
        let cachedURL = await cache.cachedFileURL(for: item)

        XCTAssertEqual(cachedURL, url)
        XCTAssertEqual(try String(contentsOf: url), "hello")
    }

    func testStorePrunesOlderVersionsForSamePath() async throws {
        let path: RemotePath = "/docs/file.txt"
        let oldItem = RemoteItem(
            path: path,
            type: .file,
            size: 5,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            permissions: 0o644
        )
        let newItem = RemoteItem(
            path: path,
            type: .file,
            size: 7,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_100),
            permissions: 0o644
        )

        let oldURL = try await cache.store(data: Data("hello".utf8), for: oldItem)
        let newURL = try await cache.store(data: Data("updated".utf8), for: newItem)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
    }

    func testInvalidateRemovesCachedVersionsForPath() async throws {
        let item = RemoteItem(
            path: "/docs/image.jpeg",
            type: .file,
            size: 4,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            permissions: 0o644
        )

        let url = try await cache.store(data: Data([1, 2, 3, 4]), for: item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        await cache.invalidate(path: item.path)
        let cachedURL = await cache.cachedFileURL(for: item)

        XCTAssertNil(cachedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
