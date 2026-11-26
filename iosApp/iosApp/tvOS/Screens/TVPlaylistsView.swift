#if os(tvOS)
import SwiftUI

/// A native focus graph: every playlist and playable entry is one button.
/// Editing belongs to the web app; unavailable entries never show a title.
struct TVPlaylistsView: View {
    /// Four 16:9 cards across the 1920-point screen inside the page padding.
    static let gridColumns = [GridItem(.adaptive(minimum: TVPlaylistEntryCardLabel.width,
                                                 maximum: TVPlaylistEntryCardLabel.width), spacing: 48,
                                       alignment: .top)]

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
                        LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: 56) {
                            ForEach(detail.entries) { entry in
                                if entry.available, let item = entry.item {
                                    Button {
                                        start(entry)
                                    } label: {
                                        TVPlaylistEntryCardLabel(item: item, isStarting: startingEntryId == entry.id)
                                    }
                                    .buttonStyle(TVCardFocusButtonStyle())
                                    .focused($focusedId, equals: entry.id)
                                } else {
                                    TVPlaylistUnavailableCard()
                                }
                            }
                        }
                        .focusSection()
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

/// A playlist entry as an episode card: its still and title, with the series
/// and episode code below. Playlists always show stills; spoiler protection
/// does not apply, since the viewer chose every entry.
private struct TVPlaylistEntryCardLabel: View {
    static let width: CGFloat = 400
    static let stillHeight: CGFloat = width * 9 / 16

    let item: PlaylistItem
    let isStarting: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Color.siloSurfaceElevated
                AsyncImageView(
                    url: stillURL ?? "",
                    thumbhash: stillThumbhash,
                    targetSize: CGSize(width: Self.width, height: Self.stillHeight),
                    contentMode: .fill,
                    placeholderStyle: .artwork,
                    placeholderSymbol: item.isEpisode ? ArtworkPlaceholderSymbol.television
                        : ArtworkPlaceholderSymbol.fallback
                )
                if isStarting {
                    Color.black.opacity(0.45)
                    ProgressView()
                }
            }
            .frame(width: Self.width, height: Self.stillHeight)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(1)
                    .tvCardTitleFocus(isFocused: isFocused)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 18, weight: .medium))
                        .lineLimit(1)
                        .tvCardSubtitleFocus(isFocused: isFocused)
                }
            }
            .frame(width: Self.width, alignment: .leading)
        }
        .frame(width: Self.width, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    /// The server gives an episode its own still as poster and backdrop; a
    /// movie's poster is portrait, so it shows the backdrop.
    private var stillURL: String? {
        (item.isEpisode ? item.posterUrl : nil) ?? item.backdropUrl ?? item.posterUrl
    }

    private var stillThumbhash: String? {
        (item.isEpisode ? item.posterThumbhash : nil) ?? item.backdropThumbhash ?? item.posterThumbhash
    }

    /// "Friends · S1:E9" for an episode; the year for a movie.
    private var subtitle: String? {
        guard item.isEpisode else { return item.releaseDate.map { String($0.prefix(4)) } }
        var parts: [String] = []
        if let series = item.seriesTitle, !series.isEmpty { parts.append(series) }
        if let season = item.seasonNumber, let episode = item.episodeNumber {
            parts.append(EpisodeLabel.text(season: season, episode: episode, style: .colon,
                                           labels: item.episodeLabels, airDate: item.airDate))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// An entry the profile can no longer play keeps its place without a title.
private struct TVPlaylistUnavailableCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.siloSurfaceElevated.opacity(0.5))
                .frame(width: TVPlaylistEntryCardLabel.width, height: TVPlaylistEntryCardLabel.stillHeight)
            Text(.playlistsUnavailable)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: TVPlaylistEntryCardLabel.width, alignment: .topLeading)
    }
}
#endif
