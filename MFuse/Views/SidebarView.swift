import SwiftUI
import AppKit
import MFuseCore
import os.log

struct SidebarView: View {

    private let logger = Logger(subsystem: "com.lollipopkit.mfuse", category: "SidebarView")
    @EnvironmentObject var connectionManager: ConnectionManager
    @Binding var selectedConnection: ConnectionConfig?
    @State private var removalErrorMessage: String?
    var onAdd: () -> Void
    var onEdit: (ConnectionConfig) -> Void

    var body: some View {
        List(selection: $selectedConnection) {
            Section("Mounts") {
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
        .navigationTitle("MFuse")
        .alert("Unable to Remove Mount", isPresented: removalErrorIsPresented) {
            Button("OK", role: .cancel) {
                removalErrorMessage = nil
            }
        } message: {
            Text(removalErrorMessage ?? "An unknown error occurred.")
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                Menu {
                    Button("Mount All") {
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
                    Button("Unmount All") {
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
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("\(config.host):\(config.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if mount.isMounted {
                    Text(FileProviderMountProvider.symlinkDisplayPath(for: config, baseDir: symlinkBaseURL))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if mount.isMounted {
                Image(systemName: "folder.fill")
                    .font(.caption2)
                    .foregroundStyle(.green.opacity(0.7))
            }
            Circle()
                .fill(stateColor(mount))
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func contextMenu(for config: ConnectionConfig) -> some View {
        let mount = connectionManager.effectiveMountState(for: config.id)
        if case .mounting = mount {
            Button("Mounting…") {}
                .disabled(true)
        } else if mount.isMounted {
            Button("Unmount") {
                Task { await connectionManager.disconnect(config.id) }
            }
        } else {
            Button("Mount") {
                Task { await connectionManager.connect(config.id) }
            }
        }
        if mount.isMounted {
            Button("Reveal in Finder") {
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
        Button("Edit…") { onEdit(config) }
        Button("Remove Mount", role: .destructive) {
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
                    let message = "Failed to remove mount \(config.id.uuidString): \(String(describing: error))"
                    logger.error(
                        "\(message, privacy: .public)"
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
