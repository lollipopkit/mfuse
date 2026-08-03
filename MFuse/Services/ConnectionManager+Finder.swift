import Foundation
import MFuseCore
import os.log

extension ConnectionManager {
    private static let finderLogger = Logger(
        subsystem: "com.lollipopkit.mfuse",
        category: "Finder"
    )

    func resolveFinderURL(for config: ConnectionConfig) async -> URL? {
        let symlinkBaseURL = mountProvider?.symlinkBaseURL
            ?? FileProviderMountProvider.defaultSymlinkBaseURL
        let symlinkURL = FileProviderMountProvider.symlinkURL(
            for: config,
            baseDir: symlinkBaseURL
        )

        if let mountProvider,
           let mountURL = try? await mountProvider.mountURL(for: config) {
            // The provider calls suspend, and disconnect is not tracked or cancelled by
            // this task, so re-check before acting on anything observed before them —
            // otherwise a reveal racing an unmount recreates a link to, and opens, a
            // domain that is already gone.
            guard effectiveMountState(for: config.id).isMounted else {
                return nil
            }
            // Deliberately not gated on `fileExists`: this app is sandboxed and cannot
            // necessarily stat paths under ~/Library/CloudStorage, but Finder opens them
            // fine. Requiring the check here made "Open in Finder" silently do nothing.
            if let recreatedSymlinkURL = try? await mountProvider.createSymlink(for: config) {
                guard effectiveMountState(for: config.id).isMounted else {
                    // An unmount that raced this call already ran removeSymlink, so the
                    // link just recreated has to go with it rather than being left
                    // pointing at a domain that is gone.
                    try? await mountProvider.removeSymlink(for: config)
                    return nil
                }
                if hasReachableLink(at: recreatedSymlinkURL) {
                    return recreatedSymlinkURL
                }
            }
            guard effectiveMountState(for: config.id).isMounted else {
                return nil
            }
            return mountURL
        }

        // Guarded like the branch above: a link left behind by a teardown whose
        // removeSymlink failed still resolves, so opening it would take the user into a
        // domain that local state has already marked unmounted.
        if effectiveMountState(for: config.id).isMounted, hasReachableLink(at: symlinkURL) {
            return symlinkURL
        }

        if let path = effectiveMountState(for: config.id).mountPath {
            return URL(fileURLWithPath: path)
        }

        // Callers can only ignore a nil, so record why rather than failing silently.
        Self.finderLogger.error(
            "No Finder location for connection \(config.id.uuidString, privacy: .public): no mount URL, no reachable symlink at \(symlinkURL.path, privacy: .private), no mount path"
        )
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
