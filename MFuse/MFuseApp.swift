import SwiftUI
import MFuseCore
import MFuseSFTP
import MFuseS3
import MFuseWebDAV
import MFuseSMB
import MFuseFTP
import MFuseNFS
import MFuseGoogleDrive
import AppKit

@main
struct MFuseApp: App {
    private static let cleanupFileProviderStateArgument = "--cleanup-file-provider-state"
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var connectionManager: ConnectionManager
    @StateObject private var appSettings: AppSettingsStore
    @State private var didPerformInitialSetup = false
    private let domainManager: DomainManager
    private let mountProvider: FileProviderMountProvider
    private let storage: SharedStorage
    private let credentialProvider: MirroredCredentialProvider
    private let isCleanupLaunch: Bool

    init() {
        self.isCleanupLaunch = ProcessInfo.processInfo.arguments.contains(Self.cleanupFileProviderStateArgument)
        self.storage = SharedStorage.withLegacyMigration()
        self.credentialProvider = MirroredCredentialProvider(primary: KeychainService())
        self.mountProvider = FileProviderMountProvider()
        let credentialProvider = self.credentialProvider
        let registry = BackendRegistry.shared
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
                    try await credentialProvider.store(updatedCredential, for: config.id)
                }
            }
        )
        let manager = ConnectionManager(
            storage: self.storage,
            credentialProvider: self.credentialProvider,
            registry: registry
        )
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
        _connectionManager = StateObject(wrappedValue: manager)
        _appSettings = StateObject(wrappedValue: AppSettingsStore())
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
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Mount") {
                    NotificationCenter.default.post(name: .newConnection, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Refresh") {
                    NotificationCenter.default.post(name: .refreshConnections, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        // Menu bar extra
        MenuBarExtra("MFuse", systemImage: "externaldrive.connected.to.line.below") {
            MenuBarView()
                .environmentObject(connectionManager)
                .environmentObject(appSettings)
                .environment(\.credentialProvider, credentialProvider)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appSettings)
        }
    }

    @MainActor
    private func performInitialSetupIfNeeded() async {
        guard !didPerformInitialSetup else { return }
        didPerformInitialSetup = true

        guard isCleanupLaunch else {
            await connectionManager.syncCredentialSnapshots()
            do {
                try await domainManager.syncDomains()
            } catch {
                NSLog("MFuse domain sync failed during launch: %@", String(describing: error))
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
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var allowsTermination = false
    static var isTerminationInProgress = false
    static var requestsFullTermination = false
    static var shutdownHandler: (@MainActor () async -> Void)?

    @MainActor
    static func requestFullTermination() {
        requestsFullTermination = true
        NSApp.terminate(nil)
    }

    @MainActor
    static func activateMainInterface() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private static func keepRunningInMenuBar(_ application: NSApplication) {
        application.windows.forEach { window in
            window.orderOut(nil)
        }
        application.setActivationPolicy(.accessory)
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

        guard Self.requestsFullTermination else {
            Self.keepRunningInMenuBar(sender)
            return .terminateCancel
        }

        Self.isTerminationInProgress = true

        Task { @MainActor in
            await Self.shutdownHandler?()
            Self.allowsTermination = true
            Self.requestsFullTermination = false
            Self.isTerminationInProgress = false
            sender.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
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
}
