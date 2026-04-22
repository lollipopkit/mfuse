import AppKit
import SwiftUI
import MFuseCore

/// Menu bar extra window content showing mount status and quick actions.
struct MenuBarView: View {

    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var isQuitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("MFuse")
                    .font(.headline)
                Spacer()
                Text("\(mountedCount)/\(connectionManager.connections.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if connectionManager.connections.isEmpty {
                Text(AppL10n.string("menuBar.emptyState.message", fallback: "No mounts configured.\nOpen MFuse to add one."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ForEach(connectionManager.connections) { config in
                    menuBarRow(config)
                }

                Divider()

                HStack(spacing: 12) {
                    Button(AppL10n.string("common.action.mountAll", fallback: "Mount All")) {
                        dismissMenuBarPanel()
                        Task {
                            for config in connectionManager.connections
                            where !connectionManager.effectiveMountState(for: config.id).isMounted {
                                await connectionManager.connect(config.id)
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(mountedCount == connectionManager.connections.count)

                    Button(AppL10n.string("common.action.unmountAll", fallback: "Unmount All")) {
                        dismissMenuBarPanel()
                        Task {
                            for config in connectionManager.connections
                            where connectionManager.effectiveMountState(for: config.id).isMounted {
                                await connectionManager.disconnect(config.id)
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(mountedCount == 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            Divider()

            HStack {
                Button(AppL10n.string("menuBar.action.openMFuse", fallback: "Open MFuse")) {
                    dismissMenuBarPanel()
                    AppDelegate.activateMainInterface()
                    openWindow(id: MFuseApp.mainWindowID)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Spacer()
                Button(AppL10n.string("menuBar.action.settings", fallback: "Settings")) {
                    dismissMenuBarPanel()
                    openSettings()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Spacer()
                Button(AppL10n.string("menuBar.action.quit", fallback: "Quit")) {
                    dismissMenuBarPanel()
                    isQuitting = true
                    AppDelegate.requestFullTermination()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(isQuitting)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 280)
    }

    @ViewBuilder
    private func menuBarRow(_ config: ConnectionConfig) -> some View {
        let mount = connectionManager.effectiveMountState(for: config.id)
        let symlinkBaseURL = connectionManager.mountProvider?.symlinkBaseURL
            ?? FileProviderMountProvider.defaultSymlinkBaseURL
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor(mount))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(config.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if mount.isMounted {
                    Text(FileProviderMountProvider.symlinkDisplayPath(for: config, baseDir: symlinkBaseURL))
                        .font(.caption2)
                        .foregroundStyle(.green.opacity(0.8))
                        .lineLimit(1)
                } else {
                    Text(config.host)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if case .error(let msg) = mount {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            if mount.isMounted {
                Button {
                    dismissMenuBarPanel()
                    revealInFinder(config: config)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(AppL10n.string("menuBar.help.revealInFinder", fallback: "Reveal in Finder"))
            }
            toggleButton(config: config, mountState: mount)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func toggleButton(config: ConnectionConfig, mountState: MountState) -> some View {
        if case .mounting = mountState {
            ProgressView()
                .controlSize(.small)
        } else {
            Button(
                mountState.isMounted
                    ? AppL10n.string("common.action.unmount", fallback: "Unmount")
                    : AppL10n.string("common.action.mount", fallback: "Mount")
            ) {
                dismissMenuBarPanel()
                Task {
                    if mountState.isMounted {
                        await connectionManager.disconnect(config.id)
                    } else {
                        await connectionManager.connect(config.id)
                    }
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
    }

    private var mountedCount: Int {
        connectionManager.connections.filter { connectionManager.effectiveMountState(for: $0.id).isMounted }.count
    }

    private func stateColor(_ state: MountState) -> Color {
        switch state {
        case .unmounted:  return .gray
        case .mounting:   return .orange
        case .mounted:    return .green
        case .error:      return .red
        }
    }

    private func revealInFinder(config: ConnectionConfig) {
        Task {
            if let targetURL = await connectionManager.resolveFinderURL(for: config) {
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([targetURL])
                }
            }
        }
    }

    @MainActor
    private func dismissMenuBarPanel() {
        NSApp.keyWindow?.orderOut(nil)
    }
}
