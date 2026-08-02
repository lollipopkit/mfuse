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
                    if config.backendType.usesHostBasedAddressing {
                        LabeledContent(AppL10n.string("detail.field.host", fallback: "Host"), value: config.host)
                        LabeledContent(AppL10n.string("detail.field.port", fallback: "Port"), value: String(config.port))
                        LabeledContent(AppL10n.string("detail.field.username", fallback: "Username"), value: config.username)
                    } else {
                        LabeledContent(AppL10n.string("detail.field.address", fallback: "Address"), value: config.displayAddress)
                        // displayAddress prefers the endpoint, so without this an S3
                        // target with both set would never show its bucket, and two
                        // buckets on one endpoint would look identical here.
                        if config.backendType == .s3,
                           let bucket = config.s3Bucket,
                           bucket != config.displayAddress {
                            LabeledContent(AppL10n.string("editor.field.bucket", fallback: "Bucket"), value: bucket)
                        }
                    }
                    LabeledContent(AppL10n.string("detail.field.remotePath", fallback: "Remote Path"), value: config.remotePath)
                    LabeledContent(AppL10n.string("detail.field.auth", fallback: "Auth"), value: config.authMethod.displayName)
                }

                // Only surfaced on failure: while mounted this just repeated the
                // container path, but it is the one place an error is reported.
                if case .error = mount {
                    Section(AppL10n.string("detail.section.mount", fallback: "Mount")) {
                        LabeledContent(AppL10n.string("detail.field.state", fallback: "State")) {
                            Text(mount.statusText)
                                .foregroundStyle(.red)
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
                Text(verbatim: config.displaySubtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Group {
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
            }
            .animation(AnimationConstants.mountState, value: mount.isMounted)
            mountButton
                .animation(AnimationConstants.mountState, value: mount.isMounted)
            refreshButton
        }
    }

    private var mountButton: some View {
        Group {
            if mount.isMounted {
                Button {
                    Task {
                        await connectionManager.disconnect(config.id)
                    }
                } label: {
                    Image(systemName: "eject.fill")
                }
                .buttonStyle(.bordered)
                // An icon-only control still needs both a pointer tooltip and a label
                // for VoiceOver.
                .help(AppL10n.string("common.action.unmount", fallback: "Unmount"))
                .accessibilityLabel(AppL10n.string("common.action.unmount", fallback: "Unmount"))
            } else if case .mounting = mount {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(AppL10n.string("common.action.mount", fallback: "Mount")) {
                    Task {
                        await connectionManager.connect(config.id)
                    }
                }
                .buttonStyle(.bordered)
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

}
