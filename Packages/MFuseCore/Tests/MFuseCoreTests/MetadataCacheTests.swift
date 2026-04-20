import XCTest
@testable import MFuseCore

final class MetadataCacheTests: XCTestCase {

    private var cache: MetadataCache!
    private var dbPath: String!

    override func setUp() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MFuseTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        dbPath = tmp.appendingPathComponent("test_cache.sqlite").path
        cache = MetadataCache(path: dbPath, ttl: 60)
        try await cache.open()
    }

    override func tearDown() async throws {
        await cache.close()
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    func testPutAndGet() async {
        let item = RemoteItem(
            path: RemotePath("/home/user/file.txt"),
            type: .file,
            size: 1024,
            modificationDate: Date()
        )
        await cache.put(item: item)
        let retrieved = await cache.get(path: RemotePath("/home/user/file.txt"))
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.path, item.path)
        XCTAssertEqual(retrieved?.size, 1024)
    }

    func testGetNonExistent() async {
        let retrieved = await cache.get(path: RemotePath("/does/not/exist"))
        XCTAssertNil(retrieved)
    }

    func testChildren() async {
        let parent = RemotePath("/home/user")
        let items = [
            RemoteItem(path: parent.appending("a.txt"), type: .file, size: 100),
            RemoteItem(path: parent.appending("b.txt"), type: .file, size: 200),
            RemoteItem(path: parent.appending("subdir"), type: .directory),
        ]
        try await cache.putAll(items: items, parent: parent)

        let childrenResult = await cache.children(of: parent)
        XCTAssertNotNil(childrenResult)
        XCTAssertEqual(childrenResult?.count, 3)
    }

    func testInvalidate() async {
        let item = RemoteItem(
            path: RemotePath("/home/user/file.txt"),
            type: .file,
            size: 512
        )
        await cache.put(item: item)
        let beforeInvalidate = await cache.get(path: item.path)
        XCTAssertNotNil(beforeInvalidate)

        await cache.invalidate(path: item.path)
        let afterInvalidate = await cache.get(path: item.path)
        XCTAssertNil(afterInvalidate)
    }

    func testInvalidateAll() async {
        let items = [
            RemoteItem(path: RemotePath("/a"), type: .file),
            RemoteItem(path: RemotePath("/b"), type: .file),
        ]
        for item in items { await cache.put(item: item) }

        await cache.invalidateAll()
        let a = await cache.get(path: RemotePath("/a"))
        let b = await cache.get(path: RemotePath("/b"))
        XCTAssertNil(a)
        XCTAssertNil(b)
    }

    func testExpiredEntries() async {
        // Create cache with 0 TTL (immediate expiration)
        let expiredCache = MetadataCache(path: dbPath, ttl: 0)
        try? await expiredCache.open()

        let item = RemoteItem(
            path: RemotePath("/expired"),
            type: .file,
            size: 42
        )
        await expiredCache.put(item: item)

        let expired = await expiredCache.get(path: item.path)
        XCTAssertNil(expired)

        await expiredCache.close()

        let reopenedCache = MetadataCache(path: dbPath, ttl: 0)
        try? await reopenedCache.open()
        let expiredAfterReopen = await reopenedCache.get(path: item.path)
        XCTAssertNil(expiredAfterReopen)
        await reopenedCache.close()
    }

    func testPutAllReplacesOldChildren() async {
        let parent = RemotePath("/dir")
        let oldItems = [
            RemoteItem(path: parent.appending("old.txt"), type: .file),
        ]
        try await cache.putAll(items: oldItems, parent: parent)
        let oldChildren = await cache.children(of: parent)
        XCTAssertEqual(oldChildren?.count, 1)

        let newItems = [
            RemoteItem(path: parent.appending("new1.txt"), type: .file),
            RemoteItem(path: parent.appending("new2.txt"), type: .file),
        ]
        try await cache.putAll(items: newItems, parent: parent)
        let newChildren = await cache.children(of: parent)
        XCTAssertEqual(newChildren?.count, 2)
        XCTAssertTrue(newChildren?.allSatisfy { $0.name.hasPrefix("new") } ?? false)
    }
}
