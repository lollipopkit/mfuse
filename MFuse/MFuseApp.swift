import SwiftUI
import MFuseCore
import MFuseSFTP
import MFuseS3
import MFuseWebDAV
import MFuseSMB
import MFuseFTP
import MFuseNFS
import MFuseGoogleDrive
import MFuseDropbox
import MFuseOneDrive
import AppKit

@main
struct MFuseApp: App {
    private static let cleanupFileProviderStateArgument = "--cleanup-file-provider-state"
    static let mainWindowID = "main"

    @Environment(\.scenePhase) private var scenePhase
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var connectionManager: ConnectionManager
    @StateObject private var appSettings: AppSettingsStore
    @StateObject private var shortcutsFolder: ShortcutsFolderStore
    @State private var didPerformInitialSetup = false
    /// What launch reconciliation left unresolved, for the user to see and retry.
    @State private var startupDomainSyncFailure: String?
    private let domainManager: DomainManager
    private let mountProvider: FileProviderMountProvider
    private let storage: SharedStorage
    private let credentialProvider: MirroredCredentialProvider
    private let iCloudSyncService: ICloudConnectionSyncService
    private let isCleanupLaunch: Bool

    init() {
        self.isCleanupLaunch = ProcessInfo.processInfo.arguments.contains(Self.cleanupFileProviderStateArgument)
        let storage = SharedStorage.withLegacyMigration()
        let credentialProvider = MirroredCredentialProvider(primary: KeychainService())
        let iCloudSyncService = ICloudConnectionSyncService(storage: storage)
        self.storage = storage
        self.credentialProvider = credentialProvider
        self.iCloudSyncService = iCloudSyncService
        let shortcutsFolder = ShortcutsFolderStore()
        let currentShortcutsFolder = shortcutsFolder.current
        self.mountProvider = FileProviderMountProvider(symlinkDirectory: { currentShortcutsFolder.url })
        let registry = BackendRegistry.shared
        BackendRegistryFactory.register(into: registry) { updatedCredential, connectionID in
            try await credentialProvider.store(updatedCredential, for: connectionID)
        }
        let manager = ConnectionManager(
            storage: storage,
            credentialProvider: credentialProvider,
            registry: registry
        )
        manager.onLocalConnectionsDidChange = { _ in
            Task { @MainActor in
                guard SharedAppSettings.iCloudSyncEnabled else {
                    return
                }
                do {
                    let result = try await iCloudSyncService.synchronize()
                    if result.didUpdateLocalSnapshot {
                        await manager.reloadConnectionsFromStorage()
                    }
                } catch {
                    NSLog("MFuse iCloud sync failed after local config change: %@", error.localizedDescription)
                }
            }
        }
        AppDelegate.shutdownHandler = { [manager] in
            await manager.shutdown()
        }
        manager.mountProvider = self.mountProvider
        self.domainManager = DomainManager(
            connectionManager: manager,
            mountProvider: self.mountProvider
        )
        manager.onMountStateChange = { config, state in
            switch state {
            case .mounted:
                NotificationService.shared.postMounted(name: config.name)
            case .unmounted:
                NotificationService.shared.postUnmounted(name: config.name)
            case .error(let msg):
                NotificationService.shared.postMountError(name: config.name, error: msg)
            case .mounting:
                break
            }
        }
        // A new shortcuts folder takes the links with it: MFuse's links leave the old one,
        // and every mounted connection gets its link again in the new one.
        shortcutsFolder.onFolderChange = { [manager] previousFolder in
            if let previousFolder {
                FileProviderMountProvider.removeManagedSymlinks(in: previousFolder)
            }
            for config in manager.connections {
                await manager.repairMountState(for: config.id)
            }
        }
        _shortcutsFolder = StateObject(wrappedValue: shortcutsFolder)
        _connectionManager = StateObject(wrappedValue: manager)
        _appSettings = StateObject(wrappedValue: AppSettingsStore(
            storage: storage,
            credentialProvider: credentialProvider,
            iCloudSyncService: iCloudSyncService
        ))
    }

    var body: some Scene {
        // Main window
        WindowGroup(id: Self.mainWindowID) {
            ContentView()
                .environmentObject(connectionManager)
                .environmentObject(appSettings)
                .environment(\.credentialProvider, credentialProvider)
                .frame(minWidth: 700, minHeight: 450)
                .task {
                    await performInitialSetupIfNeeded()
                }
                // Reported, not only logged: reconciliation is what registers the domains
                // and clears the stale ones, so a failure leaves the window showing mounts
                // the system does not have — or missing ones it does — and nothing else
                // retries before the next launch.
                .alert(
                    AppL10n.string("app.warning.startupDomainSyncIssue", fallback: "Domain Sync Issue"),
                    isPresented: startupDomainSyncFailureIsPresented
                ) {
                    Button(AppL10n.string("common.action.retry", fallback: "Retry")) {
                        Task { await retryDomainSync() }
                    }
                    Button(AppL10n.string("common.action.ok", fallback: "OK"), role: .cancel) {
                        startupDomainSyncFailure = nil
                    }
                } message: {
                    Text(startupDomainSyncFailure ?? "")
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    Task {
                        await appSettings.refreshICloudSyncStatus()
                        if await appSettings.performBackgroundSyncIfNeeded() {
                            await connectionManager.reloadConnectionsFromStorage()
                        }
                    }
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(after: .newItem) {
                Button(AppL10n.string("app.command.newMount", fallback: "New Mount")) {
                    NotificationCenter.default.post(name: .newConnection, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button(AppL10n.string("common.action.refresh", fallback: "Refresh")) {
                    NotificationCenter.default.post(name: .refreshConnections, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        // Menu bar extra. A filled silhouette of the app icon's drive and cloud, rendered as a
        // template image so it follows the menu bar's appearance; filled because an outline
        // reads lighter than the icons next to it.
        MenuBarExtra("MFuse", image: "MenuBarIcon") {
            // The same failure the window alerts on, repeated here because the window is
            // not always there: closing it leaves MFuse in the menu bar, and a retry that
            // failed after that had nowhere left to report and nowhere to be retried from
            // until a window was opened again.
            MenuBarView(
                domainSyncFailure: startupDomainSyncFailure,
                onRetryDomainSync: { await retryDomainSync() },
                onDismissDomainSyncFailure: { startupDomainSyncFailure = nil }
            )
                .environmentObject(connectionManager)
                .environmentObject(appSettings)
                .environment(\.credentialProvider, credentialProvider)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appSettings)
                .environmentObject(shortcutsFolder)
        }
    }

    @MainActor
    private func performInitialSetupIfNeeded() async {
        guard !didPerformInitialSetup else { return }
        didPerformInitialSetup = true

        guard isCleanupLaunch else {
            await appSettings.refreshICloudSyncStatus()
            if await appSettings.performBackgroundSyncIfNeeded() {
                await connectionManager.reloadConnectionsFromStorage()
            }
            await connectionManager.syncCredentialSnapshots()
            do {
                try await domainManager.syncDomains()
            } catch {
                NSLog("MFuse domain sync failed during launch: %@", String(describing: error))
                startupDomainSyncFailure = Self.startupDomainSyncFailureMessage(error)
            }
            await connectionManager.syncMounts()
            await connectionManager.autoMountConfiguredConnections()
            NotificationService.shared.isEnabled = true
            return
        }

        do {
            try await domainManager.cleanupResidualDomains()
        } catch {
            NSLog("MFuse cleanup launch failed: %@", String(describing: error))
        }

        AppDelegate.allowsTermination = true
        NSApp.terminate(nil)
    }

    private static func startupDomainSyncFailureMessage(_ error: Error) -> String {
        AppL10n.string(
            "app.error.startupDomainSyncFailed",
            fallback: "MFuse could not reconcile its File Provider domains at launch: %@. Mounts may be missing or show the wrong state until this succeeds.",
            error.localizedDescription
        )
    }

    private var startupDomainSyncFailureIsPresented: Binding<Bool> {
        Binding(
            get: { startupDomainSyncFailure != nil },
            set: { isPresented in
                if !isPresented {
                    startupDomainSyncFailure = nil
                }
            }
        )
    }

    /// Run reconciliation again, and put the mount sync that depends on it back in line.
    ///
    /// `syncMounts` reads the domains reconciliation registers, so a retry that stopped at
    /// the registration would leave the rows reporting the state the failed pass produced.
    @MainActor
    private func retryDomainSync() async {
        do {
            try await domainManager.syncDomains()
            startupDomainSyncFailure = nil
            await connectionManager.syncMounts()
        } catch {
            NSLog("MFuse domain sync retry failed: %@", String(describing: error))
            startupDomainSyncFailure = Self.startupDomainSyncFailureMessage(error)
        }
    }
}

/// Builds the app's backend registry, with where refreshed OAuth credentials go left to
/// the caller.
///
/// The OAuth backends persist a token they refreshed, so *which store* they write to is
/// what separates the app's connections from a throwaway connection test — a test that
/// wrote through the app's store would leave a real secret under an id no connection has.
/// Both callers come through here so the two registries cannot drift apart.
enum BackendRegistryFactory {

    static func register(
        into registry: BackendRegistry,
        persistRefreshedCredential: @escaping @Sendable (Credential, UUID) async throws -> Void
    ) {
        registry.registerAllBuiltIns(
            sftpFactory: { config, credential in
                SFTPFileSystem(config: config, credential: credential)
            },
            s3Factory: { config, credential in
                S3FileSystem(config: config, credential: credential)
            },
            webdavFactory: { config, credential in
                WebDAVFileSystem(config: config, credential: credential)
            },
            smbFactory: { config, credential in
                SMBFileSystem(config: config, credential: credential)
            },
            ftpFactory: { config, credential in
                FTPFileSystem(config: config, credential: credential)
            },
            nfsFactory: { config, credential in
                NFSFileSystem(config: config, credential: credential)
            },
            googleDriveFactory: { config, credential in
                GoogleDriveFileSystem(
                    config: config,
                    credential: credential
                ) { updatedCredential in
                    try await persistRefreshedCredential(updatedCredential, config.id)
                }
            },
            dropboxFactory: { config, credential in
                DropboxFileSystem(
                    config: config,
                    credential: credential
                ) { updatedCredential in
                    try await persistRefreshedCredential(updatedCredential, config.id)
                }
            },
            oneDriveFactory: { config, credential in
                OneDriveFileSystem(
                    config: config,
                    credential: credential
                ) { updatedCredential in
                    try await persistRefreshedCredential(updatedCredential, config.id)
                }
            }
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var allowsTermination = false
    static var isTerminationInProgress = false
    static var shutdownHandler: (@MainActor () async -> Void)?

    /// Quits from the menu bar's Quit item, which is an explicit request to quit.
    ///
    /// AppKit refuses to terminate while any window has a sheet attached ("App termination
    /// blocked by modal sheet") and aborts without consulting `applicationShouldTerminate`.
    /// From the menu bar that sheet is usually out of sight — an editor or alert left open
    /// on a window behind others — so Quit did nothing at all. The sheets are ended first;
    /// a draft in the connection editor is discarded, as quitting implies.
    @MainActor
    static func requestFullTermination() {
        for window in NSApp.windows where window.sheetParent == nil {
            endSheets(of: window)
        }
        NSApp.terminate(nil)
    }

    @MainActor
    private static func endSheets(of window: NSWindow) {
        while let sheet = window.attachedSheet {
            endSheets(of: sheet)
            window.endSheet(sheet)
        }
    }

    @MainActor
    static func activateMainInterface() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.allowsTermination else {
            sender.windows.forEach { window in
                window.orderOut(nil)
            }
            return .terminateNow
        }

        guard !Self.isTerminationInProgress else {
            return .terminateLater
        }

        // Every request to quit is answered by quitting. Cancelling the ones that did not
        // come from the menu bar's own Quit item meant Command-Q, the application menu and
        // the Dock did nothing at all — and, worse, that a logout or a restart was refused
        // by this app, with the mounts never torn down. Staying in the menu bar is what
        // *closing the window* does, below.
        Self.isTerminationInProgress = true

        Task { @MainActor in
            await Self.shutdownHandler?()
            Self.allowsTermination = true
            Self.isTerminationInProgress = false
            sender.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    /// Closing the last window leaves MFuse running in the menu bar, which is where its
    /// mounts are managed from — and drops the Dock icon, so it stops looking like an app
    /// with nothing open. "Open MFuse" in the menu brings both back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                Self.keepRunningInMenuBarIfLastWindowCloses(notification.object as? NSWindow)
            }
        }
    }

    @MainActor
    private static func keepRunningInMenuBarIfLastWindowCloses(_ closingWindow: NSWindow?) {
        guard NSApp.activationPolicy() == .regular else { return }
        // Only real windows count: the menu bar's own popover is one too, and it is never
        // what the user closed.
        let remaining = NSApp.windows.filter { window in
            window !== closingWindow && window.isVisible && window.canBecomeMain
        }
        guard remaining.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.activateMainInterface()
        if !flag {
            sender.windows.forEach { window in
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}

// MARK: - Environment Keys

private struct CredentialProviderKey: EnvironmentKey {
    private static let fallbackCredentialProvider = MirroredCredentialProvider(primary: KeychainService())

    static var defaultValue: any CredentialProvider {
        fallbackCredentialProvider
    }
}

extension EnvironmentValues {
    var credentialProvider: any CredentialProvider {
        get { self[CredentialProviderKey.self] }
        set { self[CredentialProviderKey.self] = newValue }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let newConnection = Notification.Name("com.lollipopkit.mfuse.newConnection")
    static let refreshConnections = Notification.Name("com.lollipopkit.mfuse.refreshConnections")
    static let connectionStorageDidRefresh = Notification.Name("com.lollipopkit.mfuse.connectionStorageDidRefresh")
}
