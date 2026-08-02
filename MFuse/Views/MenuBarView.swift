import AppKit
import SwiftUI
import MFuseCore

/// Menu bar extra window content showing mount status and quick actions.
struct MenuBarView: View {

    /// Beyond this many connections the list scrolls instead of growing the window.
    private static let rowsBeforeScrolling = 7
    private static let scrollingListHeight: CGFloat = 320

    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var isQuitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header

            // Content
            if connectionManager.connections.isEmpty {
                emptyState
            } else {
                connectionList
                batchActions
            }

            Divider()

            // Footer
            footer
        }
        .frame(width: 280)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("MFuse")
                .font(.system(size: 14, weight: .bold))
            Spacer()
            if !connectionManager.connections.isEmpty {
                Text("\(mountedCount)/\(connectionManager.connections.count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(mountedCount > 0 ? .green : .secondary)
                    .contentTransition(.numericText())
                    .animation(AnimationConstants.mountState, value: mountedCount)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .symbolEffect(.pulse, options: .repeating.speed(0.5))
            Text(AppL10n.string("menuBar.emptyState.message", fallback: "No mounts configured.\nOpen MFuse to add one."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Connection List

    /// Rows are shown directly until there are enough of them to be worth scrolling.
    ///
    /// A ScrollView derives its ideal height from the space its parent offers, not from
    /// its content. A menu bar window sizes itself to its content, so the two wait on
    /// each other and the ScrollView collapses to zero height — the rows disappear
    /// entirely. Giving it an explicit height only once it is actually needed avoids
    /// that, and a short list no longer scrolls for no reason.
    @ViewBuilder
    private var connectionList: some View {
        let rows = VStack(spacing: 0) {
            ForEach(connectionManager.connections) { config in
                menuBarRow(config)
            }
        }

        if connectionManager.connections.count > Self.rowsBeforeScrolling {
            ScrollView {
                rows
            }
            .frame(height: Self.scrollingListHeight)
        } else {
            rows
        }
    }

    // MARK: - Batch Actions

    private var batchActions: some View {
        HStack(spacing: 6) {
            Button {
                dismissMenuBarPanel()
                Task {
                    let configsToMount = connectionManager.connections.filter {
                        let state = connectionManager.effectiveMountState(for: $0.id)
                        return !state.isMounted && !state.isMounting
                    }
                    await withTaskGroup(of: Void.self) { group in
                        for config in configsToMount {
                            group.addTask {
                                await connectionManager.connect(config.id)
                            }
                        }
                    }
                }
            } label: {
                Label(AppL10n.string("common.action.mountAll", fallback: "Mount All"), systemImage: "arrow.up.circle")
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .disabled(mountedCount + mountingCount == connectionManager.connections.count)

            Button {
                dismissMenuBarPanel()
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
            } label: {
                Label(AppL10n.string("common.action.unmountAll", fallback: "Unmount All"), systemImage: "arrow.down.circle")
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .disabled(mountedCount == 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            footerButton(
                AppL10n.string("menuBar.action.openMFuse", fallback: "Open MFuse"),
                systemImage: "app"
            ) {
                dismissMenuBarPanel()
                AppDelegate.activateMainInterface()
                openWindow(id: MFuseApp.mainWindowID)
            }
            footerButton(
                AppL10n.string("menuBar.action.settings", fallback: "Settings"),
                systemImage: "gearshape"
            ) {
                dismissMenuBarPanel()
                openSettings()
            }
            footerButton(
                AppL10n.string("menuBar.action.quit", fallback: "Quit"),
                systemImage: "power"
            ) {
                dismissMenuBarPanel()
                isQuitting = true
                AppDelegate.requestFullTermination()
            }
            .disabled(isQuitting)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func footerButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            // Equal-width cells: spacers would distribute the leftover space instead of
            // the cells themselves, spacing the icons unevenly because the labels differ
            // in width.
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    // MARK: - Connection Row

    @ViewBuilder
    private func menuBarRow(_ config: ConnectionConfig) -> some View {
        let mount = connectionManager.effectiveMountState(for: config.id)
        let symlinkBaseURL = connectionManager.mountProvider?.symlinkBaseURL
            ?? FileProviderMountProvider.defaultSymlinkBaseURL

        HStack(spacing: 10) {
            // Backend icon with state ring
            ZStack {
                Circle()
                    .fill(stateColor(mount).opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: config.backendType.iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(stateColor(mount))
                    .animation(AnimationConstants.mountState, value: mount)
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(config.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if mount.isMounted {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                            .transition(.opacity.combined(with: .scale(scale: 0.5)))
                    }
                }
                Text(verbatim: mount.isMounted
                    ? FileProviderMountProvider.symlinkDisplayPath(for: config, baseDir: symlinkBaseURL)
                    : config.displayAddress
                )
                .font(.system(size: 11))
                .foregroundStyle(mount.isMounted ? .green.opacity(0.8) : .secondary)
                .lineLimit(1)
                .animation(AnimationConstants.mountState, value: mount.isMounted)
                if case .error(let msg) = mount {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Actions
            HStack(spacing: 4) {
                if mount.isMounted {
                    Button {
                        dismissMenuBarPanel()
                        revealInFinder(config: config)
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(AppL10n.string("menuBar.help.revealInFinder", fallback: "Reveal in Finder"))
                    .accessibilityLabel(AppL10n.string("menuBar.help.revealInFinder", fallback: "Reveal in Finder"))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                toggleButton(config: config, mountState: mount)
            }
            .animation(AnimationConstants.mountState, value: mount.isMounted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func toggleButton(config: ConnectionConfig, mountState: MountState) -> some View {
        if case .mounting = mountState {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(AppL10n.string("sidebar.action.mounting", fallback: "Mounting…"))
        } else {
            Button {
                dismissMenuBarPanel()
                Task {
                    if mountState.isMounted {
                        await connectionManager.disconnect(config.id)
                    } else {
                        await connectionManager.connect(config.id)
                    }
                }
            } label: {
                Image(systemName: mountState.isMounted ? "eject.circle" : "play.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(mountState.isMounted ? .red : .green)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel(mountState.isMounted
                ? AppL10n.string("common.action.unmount", fallback: "Unmount")
                : AppL10n.string("common.action.mount", fallback: "Mount")
            )
            .contentTransition(.symbolEffect(.replace))
            .animation(AnimationConstants.mountState, value: mountState.isMounted)
        }
    }

    // MARK: - Helpers

    private var mountedCount: Int {
        connectionManager.connections.filter { connectionManager.effectiveMountState(for: $0.id).isMounted }.count
    }

    private var mountingCount: Int {
        connectionManager.connections.filter { connectionManager.effectiveMountState(for: $0.id).isMounting }.count
    }

    private func stateColor(_ state: MountState) -> Color {
        switch state {
        case .unmounted:  return .secondary
        case .mounting:   return .orange
        case .mounted:    return .green
        case .error:      return .red
        }
    }

    private func revealInFinder(config: ConnectionConfig) {
        Task {
            if let targetURL = await connectionManager.resolveFinderURL(for: config) {
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([targetURL])
                }
            }
        }
    }

    @MainActor
    private func dismissMenuBarPanel() {
        NSApp.keyWindow?.orderOut(nil)
    }
}
