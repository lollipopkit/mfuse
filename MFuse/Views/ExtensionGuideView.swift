import SwiftUI
import AppKit
import MFuseCore

/// Onboarding sheet guiding users to enable the File Provider extension in System Settings.
struct ExtensionGuideView: View {

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var checking = false
    @State private var checkFailed = false
    @State private var verifyTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
                .padding(.top, 32)

            Text("Enable MFuse Extension")
                .font(.title.bold())
                .padding(.top, 16)

            Text("MFuse needs a system extension to mount remote files.\nPlease enable it in System Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .padding(.horizontal, 32)

            // Steps
            VStack(alignment: .leading, spacing: 16) {
                stepRow(number: 1,
                        title: "Open System Settings",
                        subtitle: "General → Login Items & Extensions")
                stepRow(number: 2,
                        title: "File Provider Extensions",
                        subtitle: "Find and enable \"MFuse\"")
                stepRow(number: 3,
                        title: "Return here",
                        subtitle: "Press \"Check Again\" — mounting should work")
            }
            .padding(.top, 24)
            .padding(.horizontal, 40)

            Spacer()

            // Status feedback
            if checkFailed {
                Label("Extension not yet enabled — please check System Settings.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.bottom, 8)
            }

            // Actions
            VStack(spacing: 12) {
                Button {
                    openExtensionSettings()
                } label: {
                    Label("Open System Settings", systemImage: "gear")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                HStack(spacing: 12) {
                    Button {
                        checkFailed = false
                        checking = true
                        verifyTask?.cancel()
                        verifyTask = Task {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            let ok = await verifyExtension()
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                checking = false
                                verifyTask = nil
                                if ok {
                                    dismissGuide()
                                } else {
                                    checkFailed = true
                                }
                            }
                        }
                    } label: {
                        if checking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Check Again")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(checking)

                    Button("Later") {
                        dismissGuide()
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.secondary)
                    .disabled(checking)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 28)
        }
        .frame(width: 440, height: 500)
        .onDisappear {
            verifyTask?.cancel()
            verifyTask = nil
        }
    }

    // MARK: - Subviews

    private func stepRow(number: Int, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(.blue.opacity(0.12))
                    .frame(width: 36, height: 36)
                Text("\(number)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func openExtensionSettings() {
        // macOS 14+: open Login Items & Extensions pane
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.fileprovider-nonui") {
            NSWorkspace.shared.open(url)
        }
    }

    private func dismissGuide() {
        verifyTask?.cancel()
        verifyTask = nil
        dismiss()
    }

    private func verifyExtension() async -> Bool {
        do {
            guard let mountProvider = connectionManager.mountProvider else {
                return false
            }
            _ = try await mountProvider.mountedDomains()
            UserDefaults(suiteName: AppGroupConstants.groupIdentifier)?
                .set(true, forKey: AppGroupConstants.extensionOnboardedKey)
            return true
        } catch {
            return false
        }
    }
}
