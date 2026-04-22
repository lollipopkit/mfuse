import XCTest
@testable import MFuseCore

final class RemotePathTests: XCTestCase {

    func testRootPath() {
        let root = RemotePath.root
        XCTAssertTrue(root.isRoot)
        XCTAssertEqual(root.absoluteString, "/")
        XCTAssertEqual(root.name, "/")
        XCTAssertNil(root.parent)
        XCTAssertTrue(root.components.isEmpty)
    }

    func testSimplePath() {
        let path = RemotePath("/home/user/file.txt")
        XCTAssertFalse(path.isRoot)
        XCTAssertEqual(path.components, ["home", "user", "file.txt"])
        XCTAssertEqual(path.absoluteString, "/home/user/file.txt")
        XCTAssertEqual(path.name, "file.txt")
        XCTAssertEqual(path.pathExtension, "txt")
    }

    func testParent() {
        let path = RemotePath("/home/user/file.txt")
        let parent = path.parent
        XCTAssertNotNil(parent)
        XCTAssertEqual(parent?.absoluteString, "/home/user")
        XCTAssertEqual(parent?.parent?.absoluteString, "/home")
        XCTAssertEqual(parent?.parent?.parent?.absoluteString, "/")
        XCTAssertTrue(parent?.parent?.parent?.isRoot == true)
    }

    func testAppending() {
        let root = RemotePath.root
        let child = root.appending("home")
        XCTAssertEqual(child.absoluteString, "/home")

        let grandchild = child.appending("user")
        XCTAssertEqual(grandchild.absoluteString, "/home/user")
    }

    func testAppendingNestedPath() {
        let base = RemotePath("/home")
        let nested = base.appending("user/docs/file.txt")
        XCTAssertEqual(nested.absoluteString, "/home/user/docs/file.txt")
    }

    func testIsChild() {
        let parent = RemotePath("/home/user")
        let child = RemotePath("/home/user/file.txt")
        let grandchild = RemotePath("/home/user/docs/file.txt")
        let unrelated = RemotePath("/var/log")

        XCTAssertTrue(child.isChild(of: parent))
        XCTAssertFalse(grandchild.isChild(of: parent))
        XCTAssertFalse(unrelated.isChild(of: parent))
        XCTAssertFalse(parent.isChild(of: parent))
    }

    func testIsDescendant() {
        let parent = RemotePath("/home/user")
        let child = RemotePath("/home/user/file.txt")
        let grandchild = RemotePath("/home/user/docs/file.txt")

        XCTAssertTrue(child.isDescendant(of: parent))
        XCTAssertTrue(grandchild.isDescendant(of: parent))
        XCTAssertFalse(parent.isDescendant(of: parent))
    }

    func testStringLiteral() {
        let path: RemotePath = "/home/user"
        XCTAssertEqual(path.absoluteString, "/home/user")
    }

    func testEquality() {
        let a = RemotePath("/home/user")
        let b = RemotePath("/home/user")
        let c = RemotePath("/home/other")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testCodable() throws {
        let path = RemotePath("/home/user/file.txt")
        let data = try JSONEncoder().encode(path)
        let decoded = try JSONDecoder().decode(RemotePath.self, from: data)
        XCTAssertEqual(path, decoded)
    }

    func testPathExtension() {
        XCTAssertEqual(RemotePath("/file.txt").pathExtension, "txt")
        XCTAssertEqual(RemotePath("/archive.tar.gz").pathExtension, "gz")
        XCTAssertNil(RemotePath("/noext").pathExtension)
        XCTAssertNil(RemotePath("/.hidden").pathExtension)
    }

    func testTrailingSlashHandled() {
        let path = RemotePath("/home/user/")
        XCTAssertEqual(path.components, ["home", "user"])
        XCTAssertEqual(path.absoluteString, "/home/user")
    }

    func testDoubleSlashHandled() {
        let path = RemotePath("/home//user///file.txt")
        XCTAssertEqual(path.components, ["home", "user", "file.txt"])
    }
}
