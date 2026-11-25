#if os(tvOS)
import SwiftUI

/// A native focus graph: every playlist and playable entry is one button.
/// Editing belongs to the web app; unavailable entries never show a title.
struct TVPlaylistsView: View {
    let focusRequest: Int
    let isTopMenuFocused: Bool
    let onMoveUp: () -> Void

    @Environment(AppRouter.self) private var router
    @State private var playlists: [PlaylistSummary] = []
    @State private var selectedId: String?
    @State private var detail: PlaylistDetail?
    @State private var isLoading = true
    @State private var failure: String?
    @State private var startingEntryId: String?
    @State private var startTask: Task<Void, Never>?
    @FocusState private var focusedId: String?

    private var firstId: String? {
        if failure != nil { return "retry" }
        if let detail { return detail.entries.first(where: \.available)?.id }
        return playlists.first?.id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(detail?.name ?? AppLanguage.string(.playlistsTitle))
                    .font(.largeTitle.bold())
                if isLoading {
                    placeholder(AppLanguage.string(.playlistsTitle))
                } else if let failure {
                    Text(failure)
                    Button(.commonRetry) { Task { await load() } }
                        .focused($focusedId, equals: "retry")
                } else if let detail {
                    if detail.entries.isEmpty {
                        placeholder(AppLanguage.string(.playlistsEmpty))
                    } else {
                        ForEach(detail.entries) { entry in
                            if entry.available, let item = entry.item {
                                Button {
                                    start(entry)
                                } label: {
                                    HStack {
                                        Text(item.title)
                                        Spacer()
                                        if startingEntryId == entry.id { ProgressView() }
                                        Image(systemName: "play.fill")
                                    }
                                }
                                .focused($focusedId, equals: entry.id)
                            } else {
                                Text(.playlistsUnavailable)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if firstId == nil {
                            placeholder(AppLanguage.string(.playlistsUnavailable))
                        }
                    }
                } else if playlists.isEmpty {
                    placeholder(AppLanguage.string(.playlistsEmpty))
                } else {
                    ForEach(playlists) { playlist in
                        Button {
                            selectedId = playlist.id
                        } label: {
                            HStack {
                                Text(playlist.name)
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                        }
                        .focused($focusedId, equals: playlist.id)
                    }
                }
            }
            .padding(.horizontal, SiloTheme.safePadding)
            .padding(.top, SiloTheme.Skyline.libraryContentTopInset)
            .padding(.bottom, SiloTheme.largePadding)
            .focusSection()
        }
        .task(id: selectedId) { await load() }
        .task(id: focusRequest) { await claimFocus() }
        .onChange(of: isLoading) { _, loading in
            if !loading { Task { await claimFocus() } }
        }
        .onMoveCommand { direction in
            if direction == .up, focusedId == firstId { onMoveUp() }
        }
        .onExitCommand {
            if selectedId != nil {
                startTask?.cancel()
                selectedId = nil
            } else {
                onMoveUp()
            }
        }
        .onDisappear { startTask?.cancel() }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
            .tvPageFocusOwner(focusRequest: focusRequest, isTopMenuFocused: isTopMenuFocused,
                accessibilityLabel: text, onMoveUp: onMoveUp)
    }

    @MainActor private func claimFocus() async {
        await Task.yield()
        guard !Task.isCancelled, !isTopMenuFocused else { return }
        focusedId = firstId
    }

    @MainActor private func load() async {
        isLoading = true
        failure = nil
        detail = nil
        do {
            if let selectedId {
                let result = try await SiloAPI.shared.playlist(id: selectedId)
                guard !Task.isCancelled else { return }
                detail = result
            } else {
                let result = try await SiloAPI.shared.playlists()
                guard !Task.isCancelled else { return }
                playlists = result
            }
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
        isLoading = false
    }

    private func start(_ entry: PlaylistEntry) {
        guard let selectedId, startingEntryId == nil else { return }
        startingEntryId = entry.id
        startTask = Task { @MainActor in
            defer { startingEntryId = nil }
            do {
                let result = try await SiloAPI.shared.startPlaylist(id: selectedId, entryId: entry.id)
                guard !Task.isCancelled else { return }
                guard let (resolved, context) = result else {
                    await load()
                    return
                }
                router.presentPlaylist(entry: resolved, context: context)
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
        }
    }
}
#endif
