import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Library

/// Up Next and history. Tap to play, drag to reorder, swipe or right-click for more.
struct ListenView: View {
    let listen: Listen
    /// Embedded destinations use their parent's navigation stack and omit Done.
    var embedded = false
    /// Hide native chrome while this persistent destination is inactive.
    var isActive: Bool = true
    /// Quiet root chrome for the large-screen workspace; phones keep system chrome.
    var usesWorkspaceChrome: Bool = false
    var onToggleSidebar: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    @State private var workspaceEditMode: PlatformEditMode = .inactive
    private var player: ListenPlayer { listen.player }
    private var store: ListenStore { listen.store }

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack {
                content.toolbar {
                    if !usesWorkspaceChrome {
                        ToolbarItem(placement: .platformLeading) { Button("Done") { dismiss() } }
                    }
                }
            }
        }
    }

    private var content: some View {
        rootContent
            .alert("Couldn't Update Listen", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
    }

    @ViewBuilder private var rootContent: some View {
        if usesWorkspaceChrome {
            libraryList
                .navigationBarVisibility(.hidden)
                .workspaceTopBar {
                    WorkspaceHeader(title: embedded ? "Podcasts" : "Listen", onToggleSidebar: onToggleSidebar) {
                        if !embedded {
                            Button("Done") { dismiss() }
                        }
                        PlatformEditButton()
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("listenWorkspaceHeader")
                }
                // The inset and list must share the same edit-mode binding.
                .platformEditMode($workspaceEditMode)
        } else {
            libraryList
                .navigationBarVisibility(isActive ? .visible : .hidden)
                .toolbar {
                    ToolbarItem(placement: .platformTrailing) { PlatformEditButton() }
                }
        }
    }

    private var libraryList: some View {
        List {
            if let notice = store.notice {
                Section {
                    Label(notice, systemImage: "exclamationmark.triangle.fill").font(.subheadline)
                    Button("OK") { store.dismissNotice() }
                }
            }
            Section {
                if store.upNext.isEmpty {
                    if AppPlatform.isMac {
                        ContentUnavailableView("Nothing Queued", systemImage: "dot.radiowaves.left.and.right",
                                               description: Text("Ask the agent to queue a podcast episode or generated audio."))
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        Text("Ask the agent to queue a podcast episode or generated audio.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(store.upNext) { item in
                    row(item)
                        .contextMenu {
                            upNextActions(item)
                            downloadAction(item)
                        }
                        .swipeActions(edge: .trailing) { upNextActions(item) }
                        .swipeActions(edge: .leading) { downloadAction(item) }
                }
                .onMove { store.moveUpNext(from: $0, to: $1) }
            } header: {
                Text("Up Next")
            } footer: {
                if listen.downloader.totalBytes > 0 {
                    Text("Downloads use \(ByteCountFormatter.string(fromByteCount: listen.downloader.totalBytes, countStyle: .file)).")
                }
            }
            if !store.history.isEmpty {
                Section("History") {
                    ForEach(store.history) { item in
                        row(item)
                            .contextMenu { historyActions(item) }
                            .swipeActions(edge: .trailing) { historyActions(item) }
                    }
                    Button("Clear History", role: .destructive) { listen.clearHistory() }
                }
            }
        }
        .modifier(WorkspaceListWidth(enabled: AppPlatform.isMac))
        .accessibilityIdentifier(embedded ? "podcastsScreen" : "listenScreen")
        .navigationTitle(embedded ? "Podcasts" : "Listen")
    }

    private func row(_ item: ListenItem) -> some View {
        Button {
            Task { await attemptAsync { try await player.play(item.id) } }
        } label: {
            ListenLibraryRow(listen: listen, item: item, isActive: isActive)
        }
        .buttonStyle(.plain)
    }

    // Shared by swipe and context menus so mouse access has identical semantics.
    @ViewBuilder private func upNextActions(_ item: ListenItem) -> some View {
        removeAction(item)
        Button { Task { await attemptAsync { try await listen.finish([item.id], as: .played) } } } label: {
            Label("Played", systemImage: "checkmark.circle")
        }
        .tint(.green)
    }

    @ViewBuilder private func historyActions(_ item: ListenItem) -> some View {
        removeAction(item)
        Button { attempt { try store.setStatus([item.id], .unplayed) } } label: {
            Label("Up Next", systemImage: "text.badge.plus")
        }
        .tint(.blue)
    }

    private func removeAction(_ item: ListenItem) -> some View {
        Button(role: .destructive) { attempt { try listen.remove([item.id]) } } label: {
            Label("Remove", systemImage: "trash")
        }
    }

    @ViewBuilder private func downloadAction(_ item: ListenItem) -> some View {
        switch item.download {
        case .downloaded:
            Button { listen.downloader.deleteFile(item.id) } label: { Label("Delete Download", systemImage: "trash.circle") }
        case .queued, .downloading:
            if listen.downloader.isCachingForPlayback(item.id) {
                Button { listen.downloader.download(item.id) } label: {
                    Label("Download for Offline", systemImage: "arrow.down.circle")
                }
                .tint(.cyan)
            }
            Button { listen.downloader.cancel(item.id) } label: { Label("Cancel", systemImage: "xmark.circle") }
        case .none, .failed:
            Button { listen.downloader.download(item.id) } label: { Label("Download", systemImage: "arrow.down.circle") }
                .tint(.cyan)
        }
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { failure = error.localizedDescription }
    }

    private func attemptAsync(_ action: () async throws -> Void) async {
        do { try await action() } catch { failure = error.localizedDescription }
    }
}
