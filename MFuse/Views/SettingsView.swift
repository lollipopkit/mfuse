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

            Section("About") {
                LabeledContent("Version", value: appSettings.versionString)
                LabeledContent("Build", value: appSettings.buildString)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 220)
        .padding(20)
        .task {
            appSettings.refreshLaunchAtLoginStatus()
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
