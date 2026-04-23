import SwiftUI
import AppKit
import MFuseCore
import os.log

struct SidebarView: View {

    private let logger = Logger(subsystem: "com.lollipopkit.mfuse", category: "SidebarView")
    private let mountStateAnimation: Animation = .easeInOut(duration: 0.35)
    @EnvironmentObject var connectionManager: ConnectionManager
    @Binding var selectedConnection: ConnectionConfig?
    @State private var removalErrorMessage: String?
    var onAdd: () -> Void
    var onEdit: (ConnectionConfig) -> Void

    var body: some View {
        List(selection: $selectedConnection) {
            Section(AppL10n.string("sidebar.section.mounts", fallback: "Mounts")) {
                ForEach(connectionManager.connections) { config in
                    connectionRow(config)
                        .tag(config)
                        .contextMenu {
                            contextMenu(for: config)
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(AppL10n.string("sidebar.title", fallback: "MFuse"))
        .alert(AppL10n.string("sidebar.error.unableToRemoveMount", fallback: "Unable to Remove Mount"), isPresented: removalErrorIsPresented) {
            Button(AppL10n.string("common.action.ok", fallback: "OK"), role: .cancel) {
                removalErrorMessage = nil
            }
        } message: {
            Text(removalErrorMessage ?? AppL10n.string("common.error.unknown", fallback: "An unknown error occurred."))
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                Menu {
                    Button(AppL10n.string("common.action.mountAll", fallback: "Mount All")) {
                        Task {
                            let configsToMount = connectionManager.connections.filter {
                                !connectionManager.effectiveMountState(for: $0.id).isMounted
                            }
                            await withTaskGroup(of: Void.self) { group in
                                for config in configsToMount {
                                    group.addTask {
                                        await connectionManager.connect(config.id)
                                    }
                                }
                            }
                        }
                    }
                    Button(AppL10n.string("common.action.unmountAll", fallback: "Unmount All")) {
                        Task {
                            let configsToUnmount = connectionManager.connections.filter {
                                connectionManager.effectiveMountState(for: $0.id).isMounted
                            }
                            await withTaskGroup(of: Void.self) { group in
                                for config in configsToUnmount {
                                    group.addTask {
                                        await connectionManager.disconnect(config.id)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(.borderless)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func connectionRow(_ config: ConnectionConfig) -> some View {
        let mount = connectionManager.effectiveMountState(for: config.id)
        let symlinkBaseURL = connectionManager.mountProvider?.symlinkBaseURL
            ?? FileProviderMountProvider.defaultSymlinkBaseURL
        HStack(spacing: 8) {
            Image(systemName: config.backendType.iconName)
                .foregroundStyle(mount.isMounted ? .green : .secondary)
                .animation(mountStateAnimation, value: mount.isMounted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("\(config.host):\(config.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(mount.isMounted
                    ? FileProviderMountProvider.symlinkDisplayPath(for: config, baseDir: symlinkBaseURL)
                    : ""
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .opacity(mount.isMounted ? 1 : 0)
                .animation(mountStateAnimation, value: mount.isMounted)
            }
            Spacer()
            Image(systemName: "folder.fill")
                .font(.caption2)
                .foregroundStyle(.green.opacity(0.7))
                .opacity(mount.isMounted ? 1 : 0)
                .animation(mountStateAnimation, value: mount.isMounted)
            Circle()
                .fill(stateColor(mount))
                .animation(mountStateAnimation, value: mount)
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func contextMenu(for config: ConnectionConfig) -> some View {
        let mount = connectionManager.effectiveMountState(for: config.id)
        if case .mounting = mount {
            Button(AppL10n.string("sidebar.action.mounting", fallback: "Mounting…")) {}
                .disabled(true)
        } else if mount.isMounted {
            Button(AppL10n.string("common.action.unmount", fallback: "Unmount")) {
                Task { await connectionManager.disconnect(config.id) }
            }
        } else {
            Button(AppL10n.string("common.action.mount", fallback: "Mount")) {
                Task { await connectionManager.connect(config.id) }
            }
        }
        if mount.isMounted {
            Button(AppL10n.string("common.action.revealInFinder", fallback: "Reveal in Finder")) {
                Task {
                    if let targetURL = await connectionManager.resolveFinderURL(for: config) {
                        await MainActor.run {
                            NSWorkspace.shared.activateFileViewerSelecting([targetURL])
                        }
                    }
                }
            }
        }
        Divider()
        Button(AppL10n.string("common.action.editEllipsis", fallback: "Edit…")) { onEdit(config) }
        Button(AppL10n.string("sidebar.action.removeMount", fallback: "Remove Mount"), role: .destructive) {
            Task {
                do {
                    await connectionManager.disconnect(config.id)
                    try await connectionManager.remove(config)
                    await MainActor.run {
                        if selectedConnection?.id == config.id {
                            selectedConnection = nil
                        }
                    }
                } catch {
                    let message = AppL10n.string(
                        "sidebar.error.removeMount",
                        fallback: "Failed to remove mount %@: %@",
                        config.id.uuidString,
                        String(describing: error)
                    )
                    logger.error(
                        "Failed to remove mount for connection \(config.id.uuidString, privacy: .private): \(String(describing: error), privacy: .private)"
                    )
                    await MainActor.run {
                        removalErrorMessage = message
                    }
                }
            }
        }
    }

    private var removalErrorIsPresented: Binding<Bool> {
        Binding(
            get: { removalErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    removalErrorMessage = nil
                }
            }
        )
    }

    private func stateColor(_ state: MountState) -> Color {
        switch state {
        case .unmounted:  return .gray
        case .mounting:   return .orange
        case .mounted:    return .green
        case .error:      return .red
        }
    }
}
