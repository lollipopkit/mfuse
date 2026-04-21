import BLAKE3
import Foundation

/// Provider-local file content cache keyed by remote path and item version.
public actor ContentCache {

    private let rootURL: URL
    private let fileManager = FileManager.default

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public func cachedFileURL(for item: RemoteItem) -> URL? {
        let url = fileURL(for: item)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    public func store(data: Data, for item: RemoteItem) throws -> URL {
        let pathDirectory = pathDirectoryURL(for: item.path)
        try fileManager.createDirectory(at: pathDirectory, withIntermediateDirectories: true)

        let destinationURL = fileURL(for: item)
        if fileManager.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }

        let temporaryURL = pathDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try data.write(to: temporaryURL, options: .atomic)
        do {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            let nsError = error as NSError
            guard nsError.domain == NSCocoaErrorDomain,
                  nsError.code == NSFileWriteFileExistsError else {
                throw error
            }

            do {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                throw error
            }
        }
        pruneVersions(in: pathDirectory, keeping: destinationURL.lastPathComponent)
        return destinationURL
    }

    @discardableResult
    public func store(fileAt sourceURL: URL, for item: RemoteItem) throws -> URL {
        let pathDirectory = pathDirectoryURL(for: item.path)
        try fileManager.createDirectory(at: pathDirectory, withIntermediateDirectories: true)

        let destinationURL = fileURL(for: item)
        if fileManager.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }

        let temporaryURL = pathDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try? fileManager.removeItem(at: temporaryURL)
        }
        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        do {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            let nsError = error as NSError
            guard nsError.domain == NSCocoaErrorDomain,
                  nsError.code == NSFileWriteFileExistsError else {
                try? fileManager.removeItem(at: temporaryURL)
                throw error
            }

            do {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                throw error
            }
        }
        pruneVersions(in: pathDirectory, keeping: destinationURL.lastPathComponent)
        return destinationURL
    }

    public func invalidate(path: RemotePath) {
        let directoryURL = pathDirectoryURL(for: path)
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        try? fileManager.removeItem(at: directoryURL)
    }

    public func invalidateAll() {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        try? fileManager.removeItem(at: rootURL)
    }

    public func close() {
        // ContentCache does not keep open handles, but exposing a close hook
        // keeps cleanup paths consistent with other provider-local stores.
    }

    private func fileURL(for item: RemoteItem) -> URL {
        pathDirectoryURL(for: item.path).appendingPathComponent(versionFilename(for: item), isDirectory: false)
    }

    private func pathDirectoryURL(for path: RemotePath) -> URL {
        rootURL.appendingPathComponent(Self.hexDigest(path.absoluteString), isDirectory: true)
    }

    private func versionFilename(for item: RemoteItem) -> String {
        let versionSeed = "\(item.modificationDate.timeIntervalSince1970)|\(item.size)|\(item.permissions ?? 0)"
        let version = Self.hexDigest(versionSeed)
        if let ext = item.path.pathExtension, !ext.isEmpty {
            return "\(version).\(ext)"
        }
        return version
    }

    private func pruneVersions(in directoryURL: URL, keeping filename: String) {
        guard let contents = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return
        }

        for url in contents where url.lastPathComponent != filename {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func hexDigest(_ value: String) -> String {
        let hasher = BLAKE3()
        hasher.update(data: Data(value.utf8))
        let digest = hasher.finalizeData()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
