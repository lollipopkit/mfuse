import SwiftUI
import MFuseCore

/// Menu bar extra window content showing connection status and quick actions.
struct MenuBarView: View {

    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var isQuitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("MFuse")
                    .font(.headline)
                Spacer()
                Text("\(connectedCount)/\(connectionManager.connections.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if connectionManager.connections.isEmpty {
                Text("No connections configured.\nOpen MFuse to add one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                // Connection list
                ForEach(connectionManager.connections) { config in
                    menuBarRow(config)
                }

                Divider()

                // Batch actions
                HStack(spacing: 12) {
                    Button("Connect All") {
                        Task {
                            for config in connectionManager.connections where !connectionManager.state(for: config.id).isConnected {
                                await connectionManager.connect(config.id)
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(connectedCount == connectionManager.connections.count)

                    Button("Disconnect All") {
                        Task {
                            for config in connectionManager.connections where connectionManager.state(for: config.id).isConnected {
                                await connectionManager.disconnect(config.id)
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(connectedCount == 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            Divider()

            // Footer actions
            HStack {
                Button("Open MFuse") {
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first(where: { $0.title.contains("MFuse") || $0.isKeyWindow }) {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Spacer()
                Button("Quit") {
                    isQuitting = true
                    Task {
                        await connectionManager.shutdown()
                        await MainActor.run {
                            AppDelegate.allowsTermination = true
                            NSApplication.shared.terminate(nil)
                        }
                    }
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
        let state = connectionManager.state(for: config.id)
        let mount = connectionManager.mountState(for: config.id)
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor(state))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(config.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if mount.isMounted {
                    Text("~/MFuse/\(FileProviderMountProvider.symlinkFilename(for: config))")
                        .font(.caption2)
                        .foregroundStyle(.green.opacity(0.8))
                        .lineLimit(1)
                } else {
                    Text(config.host)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if case .error(let msg) = state {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            if mount.isMounted {
                Button {
                    revealInFinder(config: config)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Reveal in Finder")
            }
            toggleButton(config: config, state: state)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func toggleButton(config: ConnectionConfig, state: ConnectionState) -> some View {
        if case .connecting = state {
            ProgressView()
                .controlSize(.small)
        } else {
            Button(state.isConnected ? "Disconnect" : "Connect") {
                Task {
                    if state.isConnected {
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

    private var connectedCount: Int {
        connectionManager.connections.filter { connectionManager.state(for: $0.id).isConnected }.count
    }

    private func stateColor(_ state: ConnectionState) -> Color {
        switch state {
        case .disconnected:   return .gray
        case .connecting:     return .orange
        case .connected:      return .green
        case .error:          return .red
        }
    }

    private func revealInFinder(config: ConnectionConfig) {
        Task {
            let targetURL = await resolveFinderURL(for: config) ?? FileProviderMountProvider.defaultSymlinkBaseURL
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([targetURL])
            }
        }
    }

    private func resolveFinderURL(for config: ConnectionConfig) async -> URL? {
        let symlinkURL = FileProviderMountProvider.symlinkURL(
            for: config,
            baseDir: FileProviderMountProvider.defaultSymlinkBaseURL
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
