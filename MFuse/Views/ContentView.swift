import SwiftUI
import MFuseCore

struct ContentView: View {

    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.credentialProvider) private var credentialProvider
    @State private var selectedConnection: ConnectionConfig?
    @State private var editorPresentation: EditorPresentation?
    @State private var showingExtensionGuide = false
    @State private var saveAlert: SaveAlertState?
    /// The save in flight for each connection, so a later one queues behind it instead
    /// of racing it or being dropped.
    @State private var saveTasks: [UUID: Task<Void, Never>] = [:]

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
                    saveConnection(
                        config,
                        credential: credential,
                        presentationID: presentation.id
                    )
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
            // Only the id is carried across: the manager reads the connection, checks it
            // is still the current attempt, and tracks the work so an edit, a removal or
            // a teardown can cancel and wait for it.
            if let id = selectedConnection?.id {
                Task { @MainActor in
                    await connectionManager.refreshMountedConnection(for: id)
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

    private func saveConnection(
        _ config: ConnectionConfig,
        credential: Credential,
        presentationID: UUID
    ) {
        // Queued behind whatever is already saving this connection, not dropped. A save
        // suspends repeatedly while its editor is still on screen and its button still
        // enabled, and the user can cancel it, reopen the same mount, re-authorize an
        // account and save again — discarding that second save would leave the older
        // credential and config as the ones that stand, silently. Serializing instead
        // keeps their credential writes from interleaving, keeps an older pass's rollback
        // from restoring the secret a newer one just stored, and stops two passes over a
        // new mount from both seeing no previous config and appending the same UUID twice.
        let precedingSave = saveTasks[config.id]
        let save = Task { @MainActor in
            await precedingSave?.value
            await performSave(config, credential: credential, presentationID: presentationID)
        }
        saveTasks[config.id] = save
        Task { @MainActor in
            await save.value
            guard saveTasks[config.id] == save else { return }
            saveTasks.removeValue(forKey: config.id)
        }
    }

    @MainActor
    private func performSave(
        _ config: ConnectionConfig,
        credential: Credential,
        presentationID: UUID
    ) async {
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
                // The new credential is already stored, so a rollback that fails leaves
                // the old config paired with it — or a credential behind for a mount
                // that was never created. Reported alongside the primary failure rather
                // than swallowed: only the user can put that right.
                let rollbackFailure = await restoreCredential(
                    previousCredential,
                    for: config.id
                )
                throw SaveFailure(primary: error, rollbackFailure: rollbackFailure)
            }
            await MainActor.run {
                // Tied to the sheet that started this save: the user can cancel it and
                // open another one meanwhile, and dismissing *that* one — and selecting
                // a mount they navigated away from — is not what this save is for.
                guard editorPresentation?.id == presentationID else { return }
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

    /// Put back the credential a failed save replaced, reporting what went wrong instead
    /// of leaving the mount paired with a secret that was never meant to stick.
    ///
    /// What belongs in the store is decided by whether the connection is still there: a
    /// removal can finish while a save is in flight — that is one of the ways this save
    /// fails — and putting the old secret back then would leave an orphan for a connection
    /// nobody can see, keyed by an id that never appears again.
    ///
    /// Checked on both sides of the write, because the write suspends and the removal is
    /// not serialized with it. `remove` drops the row before it deletes the credential, so
    /// a removal that finished inside that window has already deleted the secret it knew
    /// about and left this one behind — seeing the row gone afterwards is what catches it.
    private func restoreCredential(_ credential: Credential?, for id: UUID) async -> String? {
        do {
            guard let credential, connectionExists(id) else {
                try await credentialProvider.delete(for: id)
                return nil
            }
            try await credentialProvider.store(credential, for: id)
            guard connectionExists(id) else {
                try await credentialProvider.delete(for: id)
                return nil
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func connectionExists(_ id: UUID) -> Bool {
        connectionManager.connections.contains { $0.id == id }
    }
}

/// A save failure plus, when the credential could not be put back, what that left behind.
private struct SaveFailure: LocalizedError {
    let primary: Error
    let rollbackFailure: String?

    var errorDescription: String? {
        guard let rollbackFailure else { return primary.localizedDescription }
        return AppL10n.string(
            "content.error.saveFailedWithCredentialRollbackFailure",
            fallback: "%1$@ The stored credential could not be put back either: %2$@. Save the mount again to repair it.",
            primary.localizedDescription,
            rollbackFailure
        )
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
