import SwiftUI
import AppKit
import MFuseCore

struct ConnectionDetailView: View {

    @EnvironmentObject var connectionManager: ConnectionManager
    let config: ConnectionConfig

    private var state: ConnectionState {
        connectionManager.state(for: config.id)
    }

    private var mount: MountState {
        connectionManager.mountState(for: config.id)
    }

    private var symlinkBaseURL: URL {
        connectionManager.mountProvider?.symlinkBaseURL
            ?? FileProviderMountProvider.defaultSymlinkBaseURL
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
                Section("Server") {
                    LabeledContent("Type", value: config.backendType.displayName)
                    LabeledContent("Host", value: config.host)
                    LabeledContent("Port", value: "\(config.port)")
                    LabeledContent("Username", value: config.username)
                    LabeledContent("Remote Path", value: config.remotePath)
                    LabeledContent("Auth", value: config.authMethod.rawValue.capitalized)
                }

                Section("Status") {
                    LabeledContent("State") {
                        HStack(spacing: 6) {
                            Image(systemName: state.iconName)
                                .foregroundStyle(stateColor)
                            Text(state.statusText)
                        }
                    }
                }

                Section("Mount") {
                    LabeledContent("Mount State") {
                        HStack(spacing: 6) {
                            Image(systemName: mount.isMounted ? "folder.fill" : "folder")
                                .foregroundStyle(mount.isMounted ? .green : .secondary)
                            Text(mount.statusText)
                                .foregroundStyle(mountStateColor)
                        }
                    }
                    if mount.isMounted {
                        LabeledContent("Symlink") {
                            Text(
                                FileProviderMountProvider.symlinkDisplayPath(
                                    for: config,
                                    baseDir: symlinkBaseURL
                                )
                            )
                                .textSelection(.enabled)
                        }
                        if let path = mount.mountPath {
                            LabeledContent("Mount Path") {
                                Text(path)
                                    .textSelection(.enabled)
                                    .font(.caption)
                            }
                        }
                    }
                }

                if !config.parameters.isEmpty {
                    Section("Parameters") {
                        ForEach(config.parameters.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            LabeledContent(key, value: value)
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
                        let targetURL = await resolveFinderURL()
                            ?? connectionManager.mountProvider?.symlinkBaseURL
                            ?? FileProviderMountProvider.defaultSymlinkBaseURL
                        await MainActor.run {
                            NSWorkspace.shared.activateFileViewerSelecting([targetURL])
                        }
                    }
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            connectionButton
            refreshButton
        }
    }

    private var connectionButton: some View {
        Group {
            if state.isConnected {
                Button("Disconnect") {
                    Task {
                        await connectionManager.disconnect(config.id)
                    }
                }
                .tint(.red)
            } else if case .connecting = state {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Connect") {
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
            if state.isConnected {
                Button {
                    Task {
                        try? await connectionManager.mountProvider?.signalEnumerator(for: config)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh Finder listing")
            }
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

    private var stateColor: Color {
        switch state {
        case .disconnected:   return .gray
        case .connecting:     return .orange
        case .connected:      return .green
        case .error:          return .red
        }
    }

    private func resolveFinderURL() async -> URL? {
        let symlinkURL = FileProviderMountProvider.symlinkURL(
            for: config,
            baseDir: symlinkBaseURL
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

        if let path = mount.mountPath {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private func linkExists(at url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
