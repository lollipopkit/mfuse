import SwiftUI
import AppKit
import MFuseCore
import os.log

struct SidebarView: View {

    private let logger = Logger(subsystem: "com.lollipopkit.mfuse", category: "SidebarView")
    @EnvironmentObject var connectionManager: ConnectionManager
    @Binding var selectedConnection: ConnectionConfig?
    var onAdd: () -> Void
    var onEdit: (ConnectionConfig) -> Void

    var body: some View {
        List(selection: $selectedConnection) {
            Section("Connections") {
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
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                Menu {
                    Button("Connect All") {
                        Task {
                            for config in connectionManager.connections where !connectionManager.state(for: config.id).isConnected {
                                await connectionManager.connect(config.id)
                            }
                        }
                    }
                    Button("Disconnect All") {
                        Task {
                            for config in connectionManager.connections where connectionManager.state(for: config.id).isConnected {
                                await connectionManager.disconnect(config.id)
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
        let state = connectionManager.state(for: config.id)
        let mount = connectionManager.mountState(for: config.id)
        HStack(spacing: 8) {
            Image(systemName: config.backendType.iconName)
                .foregroundStyle(state.isConnected ? .green : .secondary)
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
                    Text("~/MFuse/\(FileProviderMountProvider.symlinkFilename(for: config))")
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
                .fill(stateColor(state))
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func contextMenu(for config: ConnectionConfig) -> some View {
        let state = connectionManager.state(for: config.id)
        let mount = connectionManager.mountState(for: config.id)
        if state.isConnected {
            Button("Disconnect") {
                Task { await connectionManager.disconnect(config.id) }
            }
        } else {
            Button("Connect") {
                Task { await connectionManager.connect(config.id) }
            }
        }
        if mount.isMounted {
            Button("Reveal in Finder") {
                Task {
                    let targetURL = await resolveFinderURL(for: config) ?? FileProviderMountProvider.symlinkBaseURL
                    await MainActor.run {
                        NSWorkspace.shared.activateFileViewerSelecting([targetURL])
                    }
                }
            }
        }
        Divider()
        Button("Edit…") { onEdit(config) }
        Button("Remove", role: .destructive) {
            Task {
                do {
                    await connectionManager.disconnect(config.id)
                    try await connectionManager.remove(config)
                    if selectedConnection?.id == config.id {
                        selectedConnection = nil
                    }
                } catch {
                    logger.error(
                        "Failed to remove connection \(config.id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
    }

    private func stateColor(_ state: ConnectionState) -> Color {
        switch state {
        case .disconnected:   return .gray
        case .connecting:     return .orange
        case .connected:      return .green
        case .error:          return .red
        }
    }

    private func resolveFinderURL(for config: ConnectionConfig) async -> URL? {
        let symlinkURL = FileProviderMountProvider.symlinkURL(
            for: config,
            baseDir: FileProviderMountProvider.symlinkBaseURL
        )
        if linkExists(at: symlinkURL) {
            return symlinkURL
        }

        if let mountProvider = connectionManager.mountProvider,
           let recreatedSymlinkURL = try? await mountProvider.createSymlink(for: config),
           linkExists(at: recreatedSymlinkURL) {
            return recreatedSymlinkURL
        }

        if let mountProvider = connectionManager.mountProvider,
           let mountURL = try? await mountProvider.mountURL(for: config) {
            return mountURL
        }

        if let path = connectionManager.mountState(for: config.id).mountPath {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private func linkExists(at url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
