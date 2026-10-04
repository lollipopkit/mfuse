import AppKit
import Foundation
import MFuseCore
import os.log

/// Where MFuse keeps its convenience links to mounts, per distribution channel.
///
/// Developer ID builds are entitled to `~/MFuse` (`MFuse-DeveloperID.entitlements`), so the
/// folder is fixed. App Store builds cannot reach outside the sandbox on their own: the user
/// picks a folder, and a security-scoped bookmark keeps access to it across launches. With
/// no folder picked there are no links, and Finder opens the mount itself.
@MainActor
final class ShortcutsFolderStore: ObservableObject {
    private static let logger = Logger(subsystem: "com.lollipopkit.mfuse", category: "ShortcutsFolder")
    private static let bookmarkDefaultsKey = "shortcutsFolderBookmark"

    @Published private(set) var folderURL: URL?

    /// The folder as the mount provider reads it, from whichever thread it runs on.
    nonisolated let current = CurrentFolder()

    /// Moves the links once the folder changed: called with the folder they were in.
    var onFolderChange: (@MainActor (_ previousFolder: URL?) async -> Void)?

    static var isUserSelectable: Bool {
        #if MFUSE_APPSTORE
        true
        #else
        false
        #endif
    }

    /// The folder in security scope, so access can be given back when it is replaced.
    private var accessedURL: URL?

    init() {
        #if MFUSE_APPSTORE
        restoreBookmarkedFolder()
        #else
        publish(FileProviderMountProvider.homeShortcutsDirectoryURL)
        #endif
    }

    /// Lets the user pick the folder. App Store builds only.
    func chooseFolder() async {
        guard Self.isUserSelectable else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL ?? FileProviderMountProvider.realHomeDirectoryURL
        panel.prompt = AppL10n.string("settings.shortcuts.choosePrompt", fallback: "Use Folder")
        panel.message = AppL10n.string(
            "settings.shortcuts.panelMessage",
            fallback: "Choose a folder for MFuse to keep links to your mounts in."
        )
        guard await panel.begin() == .OK, let url = panel.url else { return }

        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkDefaultsKey)
        } catch {
            Self.logger.error("Could not bookmark the shortcuts folder: \(error.localizedDescription, privacy: .private)")
            return
        }
        await replaceFolder(with: url)
    }

    /// Stops using the picked folder; its links are removed. App Store builds only.
    func clearFolder() async {
        guard Self.isUserSelectable else { return }
        UserDefaults.standard.removeObject(forKey: Self.bookmarkDefaultsKey)
        await replaceFolder(with: nil)
    }

    private func replaceFolder(with url: URL?) async {
        let previous = folderURL
        // Access to the old folder is kept until the links in it have been removed: the
        // change handler clears them, and without its scope the sandbox refuses.
        let previousAccess = accessedURL
        accessedURL = nil
        if let url {
            beginAccess(url)
        }
        publish(url)
        await onFolderChange?(previous)
        previousAccess?.stopAccessingSecurityScopedResource()
    }

    private func restoreBookmarkedFolder() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkDefaultsKey) else { return }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            beginAccess(url)
            if isStale, let renewed = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(renewed, forKey: Self.bookmarkDefaultsKey)
            }
            publish(url)
        } catch {
            // The folder was deleted or moved somewhere the bookmark cannot follow: links
            // stay off until the user picks a folder again.
            Self.logger.error("Could not resolve the shortcuts folder bookmark: \(error.localizedDescription, privacy: .private)")
            UserDefaults.standard.removeObject(forKey: Self.bookmarkDefaultsKey)
        }
    }

    /// Held for the app's lifetime: links are created and removed whenever a mount changes.
    private func beginAccess(_ url: URL) {
        if url.startAccessingSecurityScopedResource() {
            accessedURL = url
        }
    }

    private func publish(_ url: URL?) {
        folderURL = url
        current.url = url
    }

    /// A lock-protected copy of the folder for callers outside the main actor.
    final class CurrentFolder: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URL?

        var url: URL? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
}
