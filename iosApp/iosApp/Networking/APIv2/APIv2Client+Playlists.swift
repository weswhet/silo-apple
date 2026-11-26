import Foundation

struct PlaylistSummary: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct PlaylistDetail: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let entries: [PlaylistEntry]
}

struct PlaylistEntry: Decodable, Identifiable, Sendable {
    let id: String
    let itemId: String?
    let item: PlaylistItem?
    let available: Bool
}

/// A playlist entry's catalog card has the same fields as a shuffle pick: the
/// grid shows its still and title, and the player announces the next entry
/// on the Up Next screen with it.
typealias PlaylistItem = ShuffleItem

struct PlaylistCapability: Decodable {
    let available: Bool

    static func isUnsupported(_ error: Error) -> Bool {
        switch error {
        case APIv2Error.problem(let problem): return problem.status == 404
        case APIv2Error.httpStatus(404), APIv2Error.serverUpdateRequired: return true
        case HTTPError.http(404, _): return true
        default: return false
        }
    }
}
struct PlaylistList: Decodable { let items: [PlaylistSummary] }
struct PlaylistPlaybackResult: Decodable {
    let entry: PlaylistEntry?

    private enum CodingKeys: String, CodingKey { case entry }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Only an explicit null ends playback. A malformed success response
        // is an error, never a reason to stop silently or play an ordinary pick.
        guard container.contains(.entry) else { throw HTTPError.invalidResponse }
        entry = try container.decodeIfPresent(PlaylistEntry.self, forKey: .entry)
        if let entry {
            guard entry.available, !entry.id.isEmpty,
                  let itemId = entry.itemId, !itemId.isEmpty, entry.item != nil else {
                throw HTTPError.invalidResponse
            }
        }
    }
}

/// Keep the starting profile's authority for the entire queue, not the profile
/// that happens to be active when a later entry ends.
struct PlaylistPlaybackContext: Equatable, Sendable {
    let playlistId: String
    var entryId: String
    let auth: CapturedOrdinaryRequestAuth
}

extension APIv2Client {
    func playlistRead<Value: Decodable>(_ type: Value.Type, id: String? = nil,
                                       suffix: String = "", query: [String: String] = [:],
                                       auth: CapturedOrdinaryRequestAuth) async throws -> Value {
        let path = try id.map { "/api/v2/playlists/\(try catalogPathSegment($0))" } ?? "/api/v2/playlists"
        let raw = try await collectionRequest("GET", path: path + suffix, query: query, status: 200, auth: auth)
        // Artwork paths are server-relative; the decoder resolves them against
        // the answering server, as the other collection reads do.
        return try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(type, from: raw.data)
    }
}
