import Foundation
import MFuseCore

/// The operations Finder drives through the File Provider extension, run against one
/// backend connected to a real server.
///
/// Everything happens inside a fresh directory under the connection's root, removed again
/// at the end, so runs do not depend on or disturb what the server already holds.
public struct RemoteFileSystemConformance {
    /// What the backend is expected to support beyond the operations every backend has.
    public struct Capabilities: Sendable {
        public var rangeReads: Bool
        public var copy: Bool

        public init(rangeReads: Bool, copy: Bool) {
            self.rangeReads = rangeReads
            self.copy = copy
        }
    }

    /// A step that did not do what it should, with the step's name for the report.
    public struct Failure: Error, CustomStringConvertible {
        public let step: String
        public let detail: String
        public var description: String { "\(step): \(detail)" }
    }

    private let fileSystem: any RemoteFileSystem
    private let capabilities: Capabilities
    private let root: RemotePath

    public init(fileSystem: any RemoteFileSystem, capabilities: Capabilities) {
        self.fileSystem = fileSystem
        self.capabilities = capabilities
        self.root = RemotePath.root.appending("mfuse-e2e-\(UUID().uuidString.prefix(8))")
    }

    public func run() async throws {
        try await step("connect") {
            try await fileSystem.connect()
            try expect(await fileSystem.isConnected, "not connected after connect()")
        }
        do {
            try await exerciseFiles()
        } catch {
            try? await fileSystem.delete(at: root)
            try? await fileSystem.disconnect()
            throw error
        }
        try await step("disconnect") { try await fileSystem.disconnect() }
    }

    private func exerciseFiles() async throws {
        try await step("create directory") {
            try await fileSystem.createDirectory(at: root)
            let info = try await fileSystem.itemInfo(at: root)
            try expect(info.isDirectory, "itemInfo does not report a directory")
        }

        let small = root.appending("small.txt")
        let smallData = Data("hello from MFuse e2e\n".utf8)
        try await step("create and read a small file") {
            try await fileSystem.createFile(at: small, data: smallData)
            try expectEqual(try await fileSystem.readFile(at: small), smallData, "contents")
            try expectEqual(try await fileSystem.itemInfo(at: small).size, UInt64(smallData.count), "size")
        }

        let large = root.appending("large.bin")
        let largeData = Self.randomData(count: 300 * 1024)
        try await step("overwrite with a larger file") {
            try await fileSystem.createFile(at: large, data: Data("x".utf8))
            try await fileSystem.writeFile(at: large, data: largeData)
            try expectEqual(try await fileSystem.readFile(at: large), largeData, "contents after overwrite")
        }

        if capabilities.rangeReads {
            try await step("range read") {
                let slice = try await fileSystem.readFile(at: large, offset: 100_000, length: 50_000)
                try expectEqual(slice, largeData.subdata(in: 100_000..<150_000), "range")
                let tail = try await fileSystem.readFile(at: large, offset: UInt64(largeData.count - 10), length: 100)
                try expectEqual(tail, largeData.suffix(10), "range past the end")
            }
        }

        let streamed = root.appending("streamed.bin")
        let streamedData = Self.randomData(count: 2 * 1024 * 1024)
        try await step("create from a local file") {
            let localURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("mfuse-e2e-\(UUID().uuidString)")
            try streamedData.write(to: localURL)
            defer { try? FileManager.default.removeItem(at: localURL) }
            do {
                try await fileSystem.createFile(at: streamed, from: localURL)
            } catch RemoteFileSystemError.unsupported {
                // The extension falls back to an in-memory create, as here.
                try await fileSystem.createFile(at: streamed, data: streamedData)
            }
            try expectEqual(try await fileSystem.readFile(at: streamed), streamedData, "contents")
        }

        let unicode = root.appending("测试 文件 ✓.txt")
        try await step("unicode file name") {
            try await fileSystem.createFile(at: unicode, data: smallData)
            try expectEqual(try await fileSystem.readFile(at: unicode), smallData, "contents")
        }

        try await step("enumerate") {
            let names = Set(try await fileSystem.enumerate(at: root).map(\.name))
            for expected in [small.name, large.name, streamed.name, unicode.name] {
                try expect(names.contains(expected), "\(expected) missing from \(names.sorted())")
            }
        }

        let nested = root.appending("nested")
        let moved = nested.appending("moved.txt")
        try await step("move a file into a subdirectory") {
            try await fileSystem.createDirectory(at: nested)
            try await fileSystem.move(from: small, to: moved)
            try expectEqual(try await fileSystem.readFile(at: moved), smallData, "contents at destination")
            try await expectNotFound(small)
        }

        let renamedDirectory = root.appending("renamed")
        try await step("rename a directory") {
            try await fileSystem.move(from: nested, to: renamedDirectory)
            let names = try await fileSystem.enumerate(at: renamedDirectory).map(\.name)
            try expectEqual(names, ["moved.txt"], "contents of the renamed directory")
            try await expectNotFound(nested)
        }

        if capabilities.copy {
            try await step("copy") {
                let copied = root.appending("copied.bin")
                try await fileSystem.copy(from: large, to: copied)
                try expectEqual(try await fileSystem.readFile(at: copied), largeData, "copied contents")
            }
        }

        try await step("delete a file") {
            try await fileSystem.delete(at: unicode)
            try await expectNotFound(unicode)
        }

        try await step("missing file is notFound") {
            try await expectNotFound(root.appending("does-not-exist"))
        }

        try await step("delete a non-empty directory") {
            try await fileSystem.delete(at: root)
            try await expectNotFound(root)
        }
    }

    // MARK: - Helpers

    private func step(_ name: String, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let failure as Failure {
            throw Failure(step: name, detail: failure.detail)
        } catch {
            throw Failure(step: name, detail: String(describing: error))
        }
    }

    private func expectNotFound(_ path: RemotePath) async throws {
        do {
            _ = try await fileSystem.itemInfo(at: path)
            throw Failure(step: "notFound", detail: "\(path) still exists")
        } catch RemoteFileSystemError.notFound {
            return
        }
    }

    private func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(step: "check", detail: message) }
    }

    private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ what: String) throws {
        guard actual == expected else {
            let shown: (T) -> String = { value in
                if let data = value as? Data { return "\(data.count) bytes" }
                return String(describing: value)
            }
            throw Failure(step: "check", detail: "\(what): got \(shown(actual)), expected \(shown(expected))")
        }
    }

    private static func randomData(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
