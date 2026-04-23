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
    @State private var didAppear = false
    private let stepAnimation: Animation = .easeOut(duration: 0.4)

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
                .symbolEffect(.pulse, options: .repeating.speed(0.4))
                .padding(.top, 32)

            Text(AppL10n.string("extensionGuide.title", fallback: "Enable MFuse Extension"))
                .font(.title.bold())
                .padding(.top, 16)

            Text(AppL10n.string("extensionGuide.message", fallback: "MFuse needs a system extension to mount remote files.\nPlease enable it in System Settings."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .padding(.horizontal, 32)

            // Steps
            VStack(alignment: .leading, spacing: 16) {
                stepRow(number: 1,
                        title: AppL10n.string("extensionGuide.step.openSystemSettings.title", fallback: "Open System Settings"),
                        subtitle: AppL10n.string("extensionGuide.step.openSystemSettings.subtitle", fallback: "General → Login Items & Extensions"))
                stepRow(number: 2,
                        title: AppL10n.string("extensionGuide.step.fileProviderExtensions.title", fallback: "File Provider Extensions"),
                        subtitle: AppL10n.string("extensionGuide.step.fileProviderExtensions.subtitle", fallback: "Find and enable \"MFuse\""))
                stepRow(number: 3,
                        title: AppL10n.string("extensionGuide.step.returnHere.title", fallback: "Return here"),
                        subtitle: AppL10n.string("extensionGuide.step.returnHere.subtitle", fallback: "Press \"Check Again\" — mounting should work"))
            }
            .padding(.top, 24)
            .padding(.horizontal, 40)
            .opacity(didAppear ? 1 : 0)
            .offset(y: didAppear ? 0 : 12)
            .animation(stepAnimation, value: didAppear)

            Spacer()

            // Status feedback
            if checkFailed {
                Label(AppL10n.string("extensionGuide.status.notEnabled", fallback: "Extension not yet enabled — please check System Settings."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Actions
            VStack(spacing: 12) {
                Button {
                    openExtensionSettings()
                } label: {
                    Label(AppL10n.string("extensionGuide.action.openSystemSettings", fallback: "Open System Settings"), systemImage: "gear")
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
                            Text(AppL10n.string("extensionGuide.action.checkAgain", fallback: "Check Again"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(checking)

                    Button(AppL10n.string("common.action.later", fallback: "Later")) {
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
        .task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            didAppear = true
        }
        .animation(.easeInOut(duration: 0.3), value: checkFailed)
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
