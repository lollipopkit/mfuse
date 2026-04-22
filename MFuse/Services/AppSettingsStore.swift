import Foundation
import MFuseCore
import ServiceManagement

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginStatusDescription = ""
    @Published private(set) var iCloudSyncEnabled = SharedAppSettings.iCloudSyncEnabled
    @Published private(set) var iCloudSyncStatusDescription = ""
    @Published private(set) var iCloudSyncAvailabilityDescription = ""
    @Published private(set) var iCloudSyncCanBeEnabled = false
    @Published private(set) var isUpdatingICloudSync = false
    @Published var errorMessage: String?

    private let storage: SharedStorage
    private let credentialProvider: MirroredCredentialProvider
    private let iCloudSyncService: ICloudConnectionSyncService
    private var currentICloudAvailability = ICloudSyncAvailability(
        isDriveAvailable: false,
        isKeychainAvailable: false,
        unavailableReasons: []
    )

    init(
        storage: SharedStorage,
        credentialProvider: MirroredCredentialProvider,
        iCloudSyncService: ICloudConnectionSyncService
    ) {
        self.storage = storage
        self.credentialProvider = credentialProvider
        self.iCloudSyncService = iCloudSyncService
        refreshLaunchAtLoginStatus()
        Task {
            await refreshICloudSyncStatus()
        }
    }

    var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    var buildString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    var iCloudSyncToggleDisabled: Bool {
        isUpdatingICloudSync || (!iCloudSyncCanBeEnabled && !iCloudSyncEnabled)
    }

    func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLoginEnabled = status == .enabled

        switch status {
        case .enabled:
            launchAtLoginStatusDescription = "MFuse will launch automatically after you sign in."
        case .notRegistered:
            launchAtLoginStatusDescription = "Launch at login is off."
        case .requiresApproval:
            launchAtLoginStatusDescription = "Launch at login needs approval in System Settings."
        case .notFound:
            launchAtLoginStatusDescription = "Move MFuse into /Applications before enabling launch at login."
        @unknown default:
            launchAtLoginStatusDescription = "Launch at login status is unavailable."
        }
    }

    func refreshICloudSyncStatus() async {
        currentICloudAvailability = await iCloudSyncService.availability()
        iCloudSyncEnabled = SharedAppSettings.iCloudSyncEnabled
        iCloudSyncCanBeEnabled = currentICloudAvailability.canEnableSync

        if iCloudSyncEnabled {
            iCloudSyncStatusDescription = "Syncs connection configs and credentials across devices with iCloud."
        } else {
            iCloudSyncStatusDescription = "Keep connection configs and credentials in sync across devices with iCloud."
        }

        if currentICloudAvailability.canEnableSync {
            iCloudSyncAvailabilityDescription = "Requires both iCloud Drive and iCloud Keychain."
        } else {
            iCloudSyncAvailabilityDescription = currentICloudAvailability.unavailableReasons.joined(separator: " ")
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            errorMessage = error.localizedDescription
        }
    }

    func setICloudSyncEnabled(_ enabled: Bool) {
        Task {
            await applyICloudSync(enabled)
        }
    }

    func performBackgroundSyncIfNeeded() async -> Bool {
        guard SharedAppSettings.iCloudSyncEnabled else {
            return false
        }

        do {
            let result = try await iCloudSyncService.synchronize()
            return result.didUpdateLocalSnapshot
        } catch {
            NSLog("MFuse iCloud sync failed: %@", error.localizedDescription)
            return false
        }
    }

    private func setPersistedICloudSyncEnabled(_ enabled: Bool) {
        SharedAppSettings.setICloudSyncEnabled(enabled)
        iCloudSyncEnabled = enabled
    }

    private func recoverICloudSyncStateAfterDisableFailure(connectionIDs: [UUID]) async {
        let recoveredEnabled: Bool
        let persistedEnabled = SharedAppSettings.iCloudSyncEnabled

        do {
            let credentialSyncState = try await credentialProvider.credentialSyncState(for: connectionIDs)
            switch credentialSyncState {
            case .synchronizable:
                recoveredEnabled = true
            case .local:
                recoveredEnabled = false
            case .mixed:
                recoveredEnabled = persistedEnabled
            }
        } catch {
            recoveredEnabled = persistedEnabled
        }

        setPersistedICloudSyncEnabled(recoveredEnabled)
    }

    private func recoverICloudSyncStateAfterEnableRollbackFailure(connectionIDs: [UUID]) async {
        let recoveredEnabled: Bool

        do {
            let credentialSyncState = try await credentialProvider.credentialSyncState(for: connectionIDs)
            switch credentialSyncState {
            case .synchronizable:
                recoveredEnabled = true
            case .local, .mixed:
                recoveredEnabled = false
            }
        } catch {
            recoveredEnabled = false
        }

        setPersistedICloudSyncEnabled(recoveredEnabled)
    }

    private func applyICloudSync(_ enabled: Bool) async {
        guard !isUpdatingICloudSync else {
            return
        }
        errorMessage = nil
        isUpdatingICloudSync = true
        defer { isUpdatingICloudSync = false }

        await refreshICloudSyncStatus()
        let connectionIDs: [UUID]
        do {
            connectionIDs = try storage.loadConnections().map(\.id)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        if enabled {
            guard currentICloudAvailability.canEnableSync else {
                iCloudSyncEnabled = false
                errorMessage = currentICloudAvailability.unavailableReasons.joined(separator: " ")
                return
            }

            do {
                try await credentialProvider.setSynchronizableEnabled(true, connectionIDs: connectionIDs)
                setPersistedICloudSyncEnabled(true)
                let result = try await iCloudSyncService.synchronize()
                if result.didUpdateLocalSnapshot {
                    NotificationCenter.default.post(name: .connectionStorageDidRefresh, object: nil)
                }
            } catch {
                let syncErrorDescription = error.localizedDescription

                do {
                    try await credentialProvider.setSynchronizableEnabled(false, connectionIDs: connectionIDs)
                    setPersistedICloudSyncEnabled(false)
                    errorMessage = syncErrorDescription
                } catch {
                    let rollbackErrorDescription = error.localizedDescription
                    let combinedErrorDescription =
                        "Failed to enable iCloud Sync: \(syncErrorDescription) Rollback failed: \(rollbackErrorDescription)"
                    await recoverICloudSyncStateAfterEnableRollbackFailure(connectionIDs: connectionIDs)
                    NSLog("%@", combinedErrorDescription)
                    errorMessage = combinedErrorDescription
                }
            }
        } else {
            do {
                try await credentialProvider.setSynchronizableEnabled(false, connectionIDs: connectionIDs)
                setPersistedICloudSyncEnabled(false)
            } catch {
                await recoverICloudSyncStateAfterDisableFailure(connectionIDs: connectionIDs)
                errorMessage = error.localizedDescription
            }
        }

        await refreshICloudSyncStatus()
    }
}
