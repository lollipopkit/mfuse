import Foundation

/// A type-safe representation of a remote filesystem path.
public struct RemotePath: Hashable, Sendable, CustomStringConvertible, Codable {

    public let components: [String]

    // MARK: - Well-known paths

    public static let root = RemotePath(components: [])

    // MARK: - Computed properties

    public var isRoot: Bool { components.isEmpty }

    public var name: String { components.last ?? "/" }

    public var parent: RemotePath? {
        guard !isRoot else { return nil }
        return RemotePath(components: Array(components.dropLast()))
    }

    public var absoluteString: String {
        "/" + components.joined(separator: "/")
    }

    public var description: String { absoluteString }

    public var pathExtension: String? {
        guard let last = components.last,
              let dotIndex = last.lastIndex(of: "."),
              dotIndex != last.startIndex else { return nil }
        return String(last[last.index(after: dotIndex)...])
    }

    // MARK: - Initializers

    public init(_ string: String) {
        self.components = string
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    public init(components: [String]) {
        self.components = components
    }

    // MARK: - Operations

    public func appending(_ name: String) -> RemotePath {
        RemotePath(components: components + name.split(separator: "/").map(String.init))
    }

    public func isChild(of other: RemotePath) -> Bool {
        components.count == other.components.count + 1
            && components.starts(with: other.components)
    }

    public func isDescendant(of other: RemotePath) -> Bool {
        components.count > other.components.count
            && components.starts(with: other.components)
    }
}

// MARK: - ExpressibleByStringLiteral

extension RemotePath: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}
