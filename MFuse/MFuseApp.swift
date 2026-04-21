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

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var connectionManager: ConnectionManager
    private let mountProvider: FileProviderMountProvider
    private let storage: SharedStorage
    private let keychain: KeychainService

    init() {
        self.storage = SharedStorage.withLegacyMigration()
        self.keychain = KeychainService()
        self.mountProvider = FileProviderMountProvider()
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
                    try await self.keychain.store(updatedCredential, for: config.id)
                }
            }
        )
        let manager = ConnectionManager(
            storage: self.storage,
            credentialProvider: self.keychain,
            registry: registry
        )
        manager.mountProvider = self.mountProvider
        manager.onStateChange = { config, state in
            switch state {
            case .connected:
                NotificationService.shared.postConnected(name: config.name)
            case .disconnected:
                NotificationService.shared.postDisconnected(name: config.name)
            case .error(let msg):
                NotificationService.shared.postError(name: config.name, error: msg)
            default:
                break
            }
        }
        _connectionManager = StateObject(wrappedValue: manager)
    }

    var body: some Scene {
        // Main window
        WindowGroup {
            ContentView()
                .environmentObject(connectionManager)
                .environment(\.keychainService, keychain)
                .frame(minWidth: 700, minHeight: 450)
                .task {
                    await connectionManager.syncMounts()
                    // First-launch: check if extension is available
                    let sharedDefaults = UserDefaults(suiteName: AppGroupConstants.groupIdentifier)
                    if !(sharedDefaults?.bool(forKey: AppGroupConstants.extensionOnboardedKey) ?? false) {
                        do {
                            _ = try await connectionManager.mountProvider?.mountedDomains()
                            sharedDefaults?.set(true, forKey: AppGroupConstants.extensionOnboardedKey)
                        } catch {
                            connectionManager.needsExtensionSetup = true
                        }
                    }
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Connection") {
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
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var allowsTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.allowsTermination else {
            sender.windows.forEach { window in
                window.orderOut(nil)
            }
            sender.setActivationPolicy(.accessory)
            sender.hide(nil)
            return .terminateCancel
        }

        sender.windows.forEach { window in
            window.orderOut(nil)
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.setActivationPolicy(.regular)
        if !flag {
            sender.windows.forEach { window in
                window.makeKeyAndOrderFront(nil)
            }
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }
}

// MARK: - Environment Keys

private struct KeychainServiceKey: EnvironmentKey {
    static let defaultValue: KeychainService = KeychainService()
}

extension EnvironmentValues {
    var keychainService: KeychainService {
        get { self[KeychainServiceKey.self] }
        set { self[KeychainServiceKey.self] = newValue }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let newConnection = Notification.Name("com.lollipopkit.mfuse.newConnection")
    static let refreshConnections = Notification.Name("com.lollipopkit.mfuse.refreshConnections")
}
