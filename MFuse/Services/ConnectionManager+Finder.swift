import Foundation
import MFuseCore

extension ConnectionManager {
    func resolveFinderURL(for config: ConnectionConfig) async -> URL? {
        let symlinkBaseURL = mountProvider?.symlinkBaseURL
            ?? FileProviderMountProvider.defaultSymlinkBaseURL
        let symlinkURL = FileProviderMountProvider.symlinkURL(
            for: config,
            baseDir: symlinkBaseURL
        )

        if let mountProvider,
           let mountURL = try? await mountProvider.mountURL(for: config),
           destinationExists(at: mountURL) {
            if let recreatedSymlinkURL = try? await mountProvider.createSymlink(for: config),
               hasReachableLink(at: recreatedSymlinkURL) {
                return recreatedSymlinkURL
            }
            return mountURL
        }

        if hasReachableLink(at: symlinkURL) {
            return symlinkURL
        }

        if let path = effectiveMountState(for: config.id).mountPath {
            let url = URL(fileURLWithPath: path)
            if destinationExists(at: url) {
                return url
            }
        }

        return nil
    }

    func hasReachableLink(at url: URL) -> Bool {
        guard let destinationPath = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            return false
        }

        let destinationURL = URL(
            fileURLWithPath: destinationPath,
            relativeTo: url.deletingLastPathComponent()
        ).standardizedFileURL
        return destinationExists(at: destinationURL)
    }

    func destinationExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
