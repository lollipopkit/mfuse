import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appSettings: AppSettingsStore

    var body: some View {
        Form {
            Section("General") {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { appSettings.launchAtLoginEnabled },
                        set: { appSettings.setLaunchAtLoginEnabled($0) }
                    )
                )

                Text(appSettings.launchAtLoginStatusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sync") {
                Toggle(
                    "iCloud Sync",
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

            Section("About") {
                LabeledContent("Version", value: appSettings.versionString)
                LabeledContent("Build", value: appSettings.buildString)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 340)
        .padding(20)
        .task {
            appSettings.refreshLaunchAtLoginStatus()
            await appSettings.refreshICloudSyncStatus()
        }
        .alert("Unable to Update Settings", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) {
                appSettings.errorMessage = nil
            }
        } message: {
            Text(appSettings.errorMessage ?? "An unknown error occurred.")
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
