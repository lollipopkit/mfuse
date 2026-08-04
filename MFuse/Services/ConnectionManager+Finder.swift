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
            guard canRevealMount(for: config.id) else {
                return nil
            }
            // Deliberately not gated on `fileExists`: this app is sandboxed and cannot
            // necessarily stat paths under ~/Library/CloudStorage, but Finder opens them
            // fine. Requiring the check here made "Open in Finder" silently do nothing.
            if let recreatedSymlinkURL = try? await mountProvider.createSymlink(for: config) {
                guard canRevealMount(for: config.id) else {
                    // An unmount that raced this call already ran removeSymlink, so the
                    // link just recreated has to go with it rather than being left
                    // pointing at a domain that is gone. A failure here leaves exactly
                    // that, and nothing else is looking: reveal is not part of the
                    // teardown, so the next pass over this connection is whatever the user
                    // does next.
                    do {
                        try await mountProvider.removeSymlink(for: config)
                    } catch {
                        Self.finderLogger.error(
                            "Left a convenience link behind for \(config.id.uuidString, privacy: .public) after an unmount raced Reveal: \(error.localizedDescription, privacy: .private)"
                        )
                    }
                    // The removal suspends, and a remount landing inside that window owns
                    // this link: stripping a live mount of its shortcut is the other half
                    // of the race, so it is put back the way the manager's own teardown
                    // does it.
                    if canRevealMount(for: config.id) {
                        _ = try? await mountProvider.createSymlink(for: config)
                    }
                    return nil
                }
                if hasReachableLink(at: recreatedSymlinkURL) {
                    return recreatedSymlinkURL
                }
            }
            guard canRevealMount(for: config.id) else {
                return nil
            }
            return mountURL
        }

        // Guarded like the branch above: a link left behind by a teardown whose
        // removeSymlink failed still resolves, so opening it would take the user into a
        // domain that local state has already marked unmounted.
        if canRevealMount(for: config.id), hasReachableLink(at: symlinkURL) {
            return symlinkURL
        }

        // Gated like every branch above: the cached path outlives the mount it was
        // recorded for, so a teardown that has not published `.unmounted` yet would still
        // hand Finder a location it is in the middle of taking away.
        if canRevealMount(for: config.id),
           let path = effectiveMountState(for: config.id).mountPath {
            return URL(fileURLWithPath: path)
        }

        // Callers can only ignore a nil, so record why rather than failing silently.
        Self.finderLogger.error(
            "No Finder location for connection \(config.id.uuidString, privacy: .public): no mount URL, no reachable symlink at \(symlinkURL.path, privacy: .private), no mount path"
        )
        return nil
    }

    /// Whether there is still a mount here to reveal.
    ///
    /// The published state is not enough on its own: a teardown removes the convenience
    /// link long before it publishes `.unmounted`, so a reveal landing in that window
    /// recreates exactly the link the teardown just deleted — and opens a domain that is
    /// on its way out.
    func canRevealMount(for id: UUID) -> Bool {
        effectiveMountState(for: id).isMounted && !isLifecycleTeardownInFlight(for: id)
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
