import SwiftUI
import MFuseCore

struct ContentView: View {

    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var selectedConnection: ConnectionConfig?
    @State private var editorPresentation: EditorPresentation?
    @State private var showingExtensionGuide = false
    @State private var saveErrorMessage: String?

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
            } else {
                emptyState
            }
        }
        .sheet(item: $editorPresentation) { presentation in
            ConnectionEditorSheet(
                config: presentation.config,
                onSave: { config, credential in
                    saveConnection(config, credential: credential)
                }
            )
            .frame(minWidth: 480, minHeight: 400)
        }
        .sheet(isPresented: $showingExtensionGuide, onDismiss: {
            connectionManager.needsExtensionSetup = false
        }) {
            ExtensionGuideView()
        }
        .alert("Unable to Save Connection", isPresented: saveErrorIsPresented) {
            Button("OK", role: .cancel) {
                saveErrorMessage = nil
            }
        } message: {
            Text(saveErrorMessage ?? "An unknown error occurred.")
        }
        .onReceive(connectionManager.$needsExtensionSetup) { needs in
            if needs {
                showingExtensionGuide = true
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: showNewEditor) {
                    Label("Add Connection", systemImage: "plus")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newConnection)) { _ in
            showNewEditor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshConnections)) { _ in
            // Trigger re-enumerate for selected connection
            if let config = selectedConnection, connectionManager.state(for: config.id).isConnected {
                Task {
                    try? await connectionManager.mountProvider?.signalEnumerator(for: config)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Connection Selected")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Select a connection from the sidebar or add a new one.")
                .foregroundStyle(.tertiary)
            Button("Add Connection") { showNewEditor() }
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
                let keychain = KeychainService()
                let previousCredential = try await keychain.credential(for: config.id)
                try await keychain.store(credential, for: config.id)
                do {
                    if connectionManager.connections.contains(where: { $0.id == config.id }) {
                        try connectionManager.update(config)
                    } else {
                        try connectionManager.add(config)
                    }
                } catch {
                    if let previousCredential {
                        try? await keychain.store(previousCredential, for: config.id)
                    } else {
                        try? await keychain.delete(for: config.id)
                    }
                    throw error
                }
                await MainActor.run {
                    selectedConnection = config
                    editorPresentation = nil
                }
            } catch {
                await MainActor.run {
                    saveErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private var saveErrorIsPresented: Binding<Bool> {
        Binding(
            get: { saveErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    saveErrorMessage = nil
                }
            }
        )
    }
}

private struct EditorPresentation: Identifiable {
    let id = UUID()
    let config: ConnectionConfig?
}
