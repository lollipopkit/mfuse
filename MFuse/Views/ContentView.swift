import SwiftUI
import MFuseCore

struct ContentView: View {

    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.credentialProvider) private var credentialProvider
    @State private var selectedConnection: ConnectionConfig?
    @State private var editorPresentation: EditorPresentation?
    @State private var showingExtensionGuide = false
    @State private var saveAlert: SaveAlertState?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedConnection: $selectedConnection,
                onAdd: { showNewEditor() },
                onEdit: { config in showEditEditor(config) }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
        } detail: {
            if let config = selectedConnection {
                ConnectionDetailView(config: config)
                    .transition(.opacity)
            } else {
                emptyState
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: selectedConnection?.id)
        .sheet(item: $editorPresentation) { presentation in
            ConnectionEditorSheet(
                config: presentation.config,
                onSave: { config, credential in
                    saveConnection(config, credential: credential)
                }
            )
            .frame(minWidth: 480, minHeight: 400)
        }
        .sheet(
            isPresented: $showingExtensionGuide,
            onDismiss: {
                connectionManager.needsExtensionSetup = false
            },
            content: {
                ExtensionGuideView()
            }
        )
        .alert(item: $saveAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .cancel(Text(AppL10n.string("common.action.ok", fallback: "OK"))) {
                    saveAlert = nil
                }
            )
        }
        .onReceive(connectionManager.$needsExtensionSetup) { needs in
            if needs {
                showingExtensionGuide = true
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: showNewEditor) {
                    Label(AppL10n.string("content.action.addMount", fallback: "Add Mount"), systemImage: "plus")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newConnection)) { _ in
            showNewEditor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshConnections)) { _ in
            if let config = selectedConnection {
                let mountState = connectionManager.effectiveMountState(for: config.id)
                if connectionManager.mountProvider != nil && mountState.isMounted {
                    Task {
                        try? await connectionManager.mountProvider?.signalEnumerator(for: config)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectionStorageDidRefresh)) { _ in
            Task { @MainActor in
                let selectedConnectionID = selectedConnection?.id
                await connectionManager.reloadConnectionsFromStorage()
                if let selectedConnectionID {
                    selectedConnection = connectionManager.connections.first(where: {
                        $0.id == selectedConnectionID
                    })
                } else {
                    selectedConnection = nil
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating.speed(0.5))
            Text(AppL10n.string("content.empty.title", fallback: "No Mount Selected"))
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(AppL10n.string("content.empty.subtitle", fallback: "Select a saved mount from the sidebar or add a new one."))
                .foregroundStyle(.tertiary)
            Button(AppL10n.string("content.action.addMount", fallback: "Add Mount")) { showNewEditor() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func showNewEditor() {
        editorPresentation = EditorPresentation(config: nil)
    }

    private func showEditEditor(_ config: ConnectionConfig) {
        editorPresentation = EditorPresentation(config: config)
    }

    private func saveConnection(_ config: ConnectionConfig, credential: Credential) {
        Task {
            do {
                let previousConfig = connectionManager.connections.first(where: { $0.id == config.id })
                let previousCredential = try await credentialProvider.credential(for: config.id)
                try await credentialProvider.store(credential, for: config.id)
                do {
                    if previousConfig != nil {
                        try connectionManager.update(config)
                    } else {
                        try connectionManager.add(config)
                    }
                } catch {
                    if let previousCredential {
                        try? await credentialProvider.store(previousCredential, for: config.id)
                    } else {
                        try? await credentialProvider.delete(for: config.id)
                    }
                    throw error
                }
                await MainActor.run {
                    selectedConnection = config
                    editorPresentation = nil
                }
                do {
                    try await connectionManager.syncSavedConnectionRegistration(
                        config,
                        previousConfig: previousConfig
                    )
                } catch {
                    await MainActor.run {
                        saveAlert = SaveAlertState(
                            title: AppL10n.string(
                                "content.warning.domainSyncIssue",
                                fallback: "Domain Sync Issue"
                            ),
                            message: AppL10n.string(
                                "content.error.savedButDomainSyncFailed",
                                fallback: "The connection was saved, but File Provider domain sync failed: %@. MFuse will retry reconciliation on the next launch.",
                                error.localizedDescription
                            )
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    saveAlert = SaveAlertState(
                        title: AppL10n.string(
                            "content.error.unableToSaveMount",
                            fallback: "Unable to Save Mount"
                        ),
                        message: error.localizedDescription
                    )
                }
            }
        }
    }
}

private struct EditorPresentation: Identifiable {
    let id = UUID()
    let config: ConnectionConfig?
}

private struct SaveAlertState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
