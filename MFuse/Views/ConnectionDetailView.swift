import SwiftUI
import AppKit
import MFuseCore

struct ConnectionDetailView: View {

    @EnvironmentObject var connectionManager: ConnectionManager
    let config: ConnectionConfig

    private var mount: MountState {
        connectionManager.effectiveMountState(for: config.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding()
                .background(.ultraThinMaterial)

            Divider()

            // Details
            Form {
                Section(AppL10n.string("detail.section.server", fallback: "Server")) {
                    LabeledContent(AppL10n.string("detail.field.type", fallback: "Type"), value: config.backendType.displayName)
                    LabeledContent(AppL10n.string("detail.field.host", fallback: "Host"), value: config.host)
                    LabeledContent(AppL10n.string("detail.field.port", fallback: "Port"), value: "\(config.port)")
                    LabeledContent(AppL10n.string("detail.field.username", fallback: "Username"), value: config.username)
                    LabeledContent(AppL10n.string("detail.field.remotePath", fallback: "Remote Path"), value: config.remotePath)
                    LabeledContent(AppL10n.string("detail.field.auth", fallback: "Auth"), value: config.authMethod.displayName)
                }

                Section(AppL10n.string("detail.section.mount", fallback: "Mount")) {
                    LabeledContent(AppL10n.string("detail.field.state", fallback: "State")) {
                        HStack(spacing: 6) {
                            Image(systemName: mount.isMounted ? "folder.fill" : "folder")
                                .foregroundStyle(iconColor)
                                .contentTransition(.symbolEffect(.replace))
                                .animation(AnimationConstants.mountState, value: mount.isMounted)
                            Text(mount.statusText)
                                .foregroundStyle(mountStateColor)
                                .animation(AnimationConstants.mountState, value: mount)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle(config.name)
        .task(id: config.id) {
            await connectionManager.repairMountState(for: config.id)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(config.name)
                    .font(.title2.bold())
                Text("\(config.backendType.displayName) — \(config.host)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if mount.isMounted {
                Button {
                    Task {
                        if let targetURL = await connectionManager.resolveFinderURL(for: config) {
                            await MainActor.run {
                                NSWorkspace.shared.activateFileViewerSelecting([targetURL])
                            }
                        }
                    }
                } label: {
                    Label(AppL10n.string("detail.action.openInFinder", fallback: "Open in Finder"), systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            mountButton
                .animation(AnimationConstants.mountState, value: mount.isMounted)
            refreshButton
        }
    }

    private var mountButton: some View {
        Group {
            if mount.isMounted {
                Button(AppL10n.string("common.action.unmount", fallback: "Unmount")) {
                    Task {
                        await connectionManager.disconnect(config.id)
                    }
                }
                .tint(.red)
            } else if case .mounting = mount {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(AppL10n.string("common.action.mount", fallback: "Mount")) {
                    Task {
                        await connectionManager.connect(config.id)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var refreshButton: some View {
        Group {
            if mount.isMounted {
                Button {
                    Task {
                        try? await connectionManager.mountProvider?.signalEnumerator(for: config)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(AppL10n.string("detail.help.refreshFinderListing", fallback: "Refresh Finder listing"))
                .transition(.opacity)
            }
        }
        .animation(AnimationConstants.mountState, value: mount.isMounted)
    }

    private var iconColor: Color {
        switch mount {
        case .mounted:    return .green
        case .mounting:   return .orange
        case .error:      return .red
        case .unmounted:  return .secondary
        }
    }

    private var mountStateColor: Color {
        switch mount {
        case .unmounted:  return .secondary
        case .mounting:   return .orange
        case .mounted:    return .green
        case .error:      return .red
        }
    }
}
