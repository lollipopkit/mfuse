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
        if linkExists(at: symlinkURL) {
            return symlinkURL
        }

        if let mountProvider,
           let recreatedSymlinkURL = try? await mountProvider.createSymlink(for: config),
           linkExists(at: recreatedSymlinkURL) {
            return recreatedSymlinkURL
        }

        if let mountProvider,
           let mountURL = try? await mountProvider.mountURL(for: config) {
            return mountURL
        }

        if let path = effectiveMountState(for: config.id).mountPath {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    func linkExists(at url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
