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
                Section("Server") {
                    LabeledContent("Type", value: config.backendType.displayName)
                    LabeledContent("Host", value: config.host)
                    LabeledContent("Port", value: "\(config.port)")
                    LabeledContent("Username", value: config.username)
                    LabeledContent("Remote Path", value: config.remotePath)
                    LabeledContent("Auth", value: config.authMethod.rawValue.capitalized)
                }

                Section("Mount") {
                    LabeledContent("State") {
                        HStack(spacing: 6) {
                            Image(systemName: mount.isMounted ? "folder.fill" : "folder")
                                .foregroundStyle(iconColor)
                            Text(mount.statusText)
                                .foregroundStyle(mountStateColor)
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
                    Label("Open in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            mountButton
            refreshButton
        }
    }

    private var mountButton: some View {
        Group {
            if mount.isMounted {
                Button("Unmount") {
                    Task {
                        await connectionManager.disconnect(config.id)
                    }
                }
                .tint(.red)
            } else if case .mounting = mount {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Mount") {
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
                .help("Refresh Finder listing")
            }
        }
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
