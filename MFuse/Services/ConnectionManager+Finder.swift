import AppKit
import Foundation
import MFuseCore
import os.log

extension ConnectionManager {
    private static let finderLogger = Logger(
        subsystem: "com.lollipopkit.mfuse",
        category: "Finder"
    )

    /// Open a connection's mount in Finder.
    ///
    /// The check that earns the activation happens in the same main-actor step as the
    /// activation itself. Callers used to resolve the location and then hop back to the
    /// main actor to open it, and an unmount landing in that hop had already removed the
    /// convenience link and disconnected the domain — Finder was still sent to the
    /// location it had just taken away.
    func revealInFinder(_ requestedConfig: ConnectionConfig) async {
        guard let targetURL = await resolveFinderURL(for: requestedConfig) else { return }
        // Read as the row is now, the way the resolution reads it: a rename that landed
        // meanwhile makes the caller's copy stale, and that is not a reason to refuse.
        guard let config = connections.first(where: { $0.id == requestedConfig.id }),
              canRevealMount(for: config) else {
            Self.finderLogger.notice(
                "Not revealing \(requestedConfig.id.uuidString, privacy: .public): its mount was taken down while the location was being resolved"
            )
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([targetURL])
    }

    func resolveFinderURL(for requestedConfig: ConnectionConfig) async -> URL? {
        // Acted on as the row is now, not as the caller holds it. Menus and the detail view
        // pass the copy they were built with, and the convenience link's filename carries
        // the connection's name: creating one from a stale copy writes a link under a name
        // no later operation resolves — every one of them, teardown included, works from
        // the current name — so it is left behind for good.
        guard let config = connections.first(where: { $0.id == requestedConfig.id }) else {
            Self.finderLogger.error(
                "No Finder location for connection \(requestedConfig.id.uuidString, privacy: .public): it is no longer saved"
            )
            return nil
        }
        let symlinkBaseURL = mountProvider?.symlinkBaseURL
            ?? FileProviderMountProvider.defaultSymlinkBaseURL
        let symlinkURL = FileProviderMountProvider.symlinkURL(
            for: config,
            baseDir: symlinkBaseURL
        )

        // Told apart from a lookup that failed: the provider answers `nil` when there is no
        // domain registered for this connection any more — removed in System Settings, or
        // behind the app's back — and the fallbacks below would then hand Finder a stale
        // convenience link or a cached path and open storage that is no longer connected.
        // A lookup that *threw* says nothing either way, so it keeps them.
        var resolvedMountURL: URL?
        var didResolveMountURL = false
        if let mountProvider {
            do {
                resolvedMountURL = try await mountProvider.mountURL(for: config)
                didResolveMountURL = true
            } catch {
                Self.finderLogger.warning(
                    "Falling back to the convenience link for \(config.id.uuidString, privacy: .public): the mount URL could not be resolved: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
        if didResolveMountURL, resolvedMountURL == nil {
            Self.finderLogger.error(
                "No Finder location for connection \(config.id.uuidString, privacy: .public): its File Provider domain is no longer registered"
            )
            return nil
        }

        if let mountProvider,
           let mountURL = resolvedMountURL {
            // The provider calls suspend, and disconnect is not tracked or cancelled by
            // this task, so re-check before acting on anything observed before them —
            // otherwise a reveal racing an unmount recreates a link to, and opens, a
            // domain that is already gone.
            guard canRevealMount(for: config) else {
                return nil
            }
            // Deliberately not gated on `fileExists`: this app is sandboxed and cannot
            // necessarily stat paths under ~/Library/CloudStorage, but Finder opens them
            // fine. Requiring the check here made "Open in Finder" silently do nothing.
            if let recreatedSymlinkURL = try? await mountProvider.createSymlink(for: config) {
                guard canRevealMount(for: config) else {
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
                    if canRevealMount(for: config) {
                        _ = try? await mountProvider.createSymlink(for: config)
                    }
                    return nil
                }
                if hasReachableLink(at: recreatedSymlinkURL) {
                    return recreatedSymlinkURL
                }
            }
            guard canRevealMount(for: config) else {
                return nil
            }
            return mountURL
        }

        // Guarded like the branch above: a link left behind by a teardown whose
        // removeSymlink failed still resolves, so opening it would take the user into a
        // domain that local state has already marked unmounted.
        if canRevealMount(for: config), hasReachableLink(at: symlinkURL) {
            return symlinkURL
        }

        // Gated like every branch above: the cached path outlives the mount it was
        // recorded for, so a teardown that has not published `.unmounted` yet would still
        // hand Finder a location it is in the middle of taking away.
        if canRevealMount(for: config),
           let path = effectiveMountState(for: config.id).mountPath {
            return URL(fileURLWithPath: path)
        }

        // Callers can only ignore a nil, so record why rather than failing silently.
        Self.finderLogger.error(
            "No Finder location for connection \(config.id.uuidString, privacy: .public): no mount URL, no reachable symlink at \(symlinkURL.path, privacy: .private), no mount path"
        )
        return nil
    }

    /// Whether there is still a mount here to reveal, and this is still the connection it
    /// belongs to.
    ///
    /// The published state is not enough on its own: a teardown removes the convenience
    /// link long before it publishes `.unmounted`, so a reveal landing in that window
    /// recreates exactly the link the teardown just deleted — and opens a domain that is
    /// on its way out.
    ///
    /// The config is checked whole rather than by id, because the provider calls below
    /// suspend: a rename or a synced edit that reconciles inside one of those windows has
    /// already moved the link, and finishing the reveal against the config from before it
    /// would put the old name back beside the new one.
    func canRevealMount(for config: ConnectionConfig) -> Bool {
        effectiveMountState(for: config.id).isMounted
            && !isLifecycleTeardownInFlight(for: config.id)
            && connections.contains(config)
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
