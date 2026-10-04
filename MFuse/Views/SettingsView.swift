import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appSettings: AppSettingsStore
    @EnvironmentObject var shortcutsFolder: ShortcutsFolderStore

    var body: some View {
        Form {
            Section(AppL10n.string("settings.section.general", fallback: "General")) {
                Toggle(
                    AppL10n.string("settings.toggle.launchAtLogin", fallback: "Launch at Login"),
                    isOn: Binding(
                        get: { appSettings.launchAtLoginEnabled },
                        set: { appSettings.setLaunchAtLoginEnabled($0) }
                    )
                )

                Text(appSettings.launchAtLoginStatusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(AppL10n.string("settings.section.sync", fallback: "Sync")) {
                Toggle(
                    AppL10n.string("settings.toggle.iCloudSync", fallback: "iCloud Sync"),
                    isOn: Binding(
                        get: { appSettings.iCloudSyncEnabled },
                        set: { appSettings.setICloudSyncEnabled($0) }
                    )
                )
                .disabled(appSettings.iCloudSyncToggleDisabled)

                Text(appSettings.iCloudSyncStatusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(appSettings.iCloudSyncAvailabilityDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appSettings.isUpdatingICloudSync {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Section(AppL10n.string("settings.section.shortcuts", fallback: "Finder Shortcuts")) {
                LabeledContent(
                    AppL10n.string("settings.shortcuts.folder", fallback: "Folder"),
                    value: shortcutsFolder.folderURL.map { ($0.path as NSString).abbreviatingWithTildeInPath }
                        ?? AppL10n.string("settings.shortcuts.none", fallback: "None")
                )

                if ShortcutsFolderStore.isUserSelectable {
                    HStack {
                        Button(AppL10n.string("settings.shortcuts.choose", fallback: "Choose Folder…")) {
                            Task { await shortcutsFolder.chooseFolder() }
                        }
                        if shortcutsFolder.folderURL != nil {
                            Button(AppL10n.string("settings.shortcuts.clear", fallback: "Stop Using Folder")) {
                                Task { await shortcutsFolder.clearFolder() }
                            }
                        }
                    }
                }

                Text(
                    shortcutsFolder.folderURL == nil
                        ? AppL10n.string(
                            "settings.shortcuts.noneDescription",
                            fallback: "Without a folder, mounts are still in the Finder sidebar under Locations."
                        )
                        : AppL10n.string(
                            "settings.shortcuts.description",
                            fallback: "MFuse keeps a link to each mounted connection in this folder."
                        )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(AppL10n.string("settings.section.about", fallback: "About")) {
                LabeledContent(AppL10n.string("settings.field.version", fallback: "Version"), value: appSettings.versionString)
                LabeledContent(AppL10n.string("settings.field.build", fallback: "Build"), value: appSettings.buildString)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 460)
        .padding(20)
        .task {
            appSettings.refreshLaunchAtLoginStatus()
            await appSettings.refreshICloudSyncStatus()
        }
        .alert(AppL10n.string("settings.error.unableToUpdate", fallback: "Unable to Update Settings"), isPresented: errorIsPresented) {
            Button(AppL10n.string("common.action.ok", fallback: "OK"), role: .cancel) {
                appSettings.errorMessage = nil
            }
        } message: {
            Text(appSettings.errorMessage ?? AppL10n.string("common.error.unknown", fallback: "An unknown error occurred."))
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { appSettings.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    appSettings.errorMessage = nil
                }
            }
        )
    }
}
