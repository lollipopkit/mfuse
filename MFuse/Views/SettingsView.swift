import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appSettings: AppSettingsStore

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

            Section(AppL10n.string("settings.section.about", fallback: "About")) {
                LabeledContent(AppL10n.string("settings.field.version", fallback: "Version"), value: appSettings.versionString)
                LabeledContent(AppL10n.string("settings.field.build", fallback: "Build"), value: appSettings.buildString)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 340)
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
