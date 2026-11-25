import Foundation
import XCTest
@testable import Silo

final class PlaylistV2Tests: XCTestCase {
    private let stub = APIv2TestStub()

    private func client() async throws -> (APIv2Client, TokenStore, CapturedOrdinaryRequestAuth) {
        let name = "PlaylistV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://playlist.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        let auth = await tokens.captureOrdinaryRequestAuth()
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokens, try XCTUnwrap(auth))
    }

    func testDetailKeepsDuplicateEntryIdentityAndRedactedUnavailableEntries() async throws {
        stub.reply(200, #"{"id":"p1","name":"Mixed","revision":2,"entries":[{"id":"e1","item_id":"movie","available":true,"item":{"content_id":"movie","title":"Movie","type":"movie"}},{"id":"e2","available":false},{"id":"e3","item_id":"movie","available":true,"item":{"content_id":"movie","title":"Movie","type":"movie"}}]}"#)
        let (api, _, auth) = try await client()
        let detail = try await api.playlistRead(PlaylistDetail.self, id: "p1", auth: auth)
        XCTAssertEqual(detail.entries.map(\.id), ["e1", "e2", "e3"])
        XCTAssertEqual(detail.entries[0].itemId, detail.entries[2].itemId)
        XCTAssertNil(detail.entries[1].item)
        XCTAssertNil(detail.entries[1].itemId)
        XCTAssertEqual(stub.requests.last?.header("x-profile-id"), "profile-one")
    }

    func testAdvanceUsesEntryCursorAndNullMeansEnd() async throws {
        stub.reply(200, #"{"entry":null}"#)
        let (api, _, auth) = try await client()
        let result = try await api.playlistRead(PlaylistPlaybackResult.self, id: "p1", suffix: "/playback",
            query: ["entry_id": "e3", "after": "true"], auth: auth)
        XCTAssertNil(result.entry)
        XCTAssertEqual(stub.requests.last?.path, "/api/v2/playlists/p1/playback")
        XCTAssertEqual(stub.requests.last?.query["entry_id"], "e3")
        XCTAssertEqual(stub.requests.last?.query["after"], "true")
    }

    func testStartUsesSelectedEntryRatherThanTitleIdentity() async throws {
        stub.reply(200, #"{"entry":{"id":"duplicate-two","item_id":"movie","available":true,"item":{"content_id":"movie","title":"Movie","type":"movie"}}}"#)
        let (api, _, auth) = try await client()
        let result = try await api.playlistRead(PlaylistPlaybackResult.self, id: "p1", suffix: "/playback",
            query: ["entry_id": "duplicate-two", "after": "false"], auth: auth)
        XCTAssertEqual(result.entry?.id, "duplicate-two")
        XCTAssertEqual(result.entry?.itemId, "movie")
        XCTAssertEqual(stub.requests.last?.query["after"], "false")
    }

    func testAdvanceCannotFollowAProfileSwitch() async throws {
        let (api, tokens, auth) = try await client()
        await tokens.setProfileId("profile-two")
        do {
            _ = try await api.playlistRead(PlaylistPlaybackResult.self, id: "p1", suffix: "/playback", auth: auth)
            XCTFail("The previous profile's queue must not dispatch")
        } catch is APIv2OwnerChangedBeforeDispatch {
            XCTAssertTrue(stub.requests.isEmpty)
        }
    }

    func testMalformedResolvedEntryIsNotTheEndOfThePlaylist() throws {
        let malformed = Data(#"{"entry":{"id":"e1","available":true}}"#.utf8)
        XCTAssertThrowsError(try HTTPClient.makeJSONDecoder().decode(PlaylistPlaybackResult.self, from: malformed))
        let end = Data(#"{"entry":null}"#.utf8)
        XCTAssertNil(try HTTPClient.makeJSONDecoder().decode(PlaylistPlaybackResult.self, from: end).entry)
        XCTAssertThrowsError(try HTTPClient.makeJSONDecoder().decode(PlaylistPlaybackResult.self, from: Data("{}".utf8)))
    }

    func testOlderServersDoNotAdvertisePlaylists() async throws {
        stub.reply(404, "")
        let (api, _, auth) = try await client()
        do {
            _ = try await api.playlistRead(PlaylistCapability.self, suffix: "/capabilities", auth: auth)
            XCTFail("A missing capability endpoint must not enable playlists")
        } catch {
            XCTAssertEqual(stub.requests.count, 1)
        }
    }

    func testTransientCapabilityFailuresRemainRetryable() {
        XCTAssertTrue(PlaylistCapability.isUnsupported(APIv2Error.httpStatus(404)))
        XCTAssertFalse(PlaylistCapability.isUnsupported(APIv2Error.httpStatus(503)))
        XCTAssertFalse(PlaylistCapability.isUnsupported(URLError(.timedOut)))
        XCTAssertFalse(PlaylistCapability.isUnsupported(HTTPError.authorityChanged))
    }

    func testOnlyAccessAndMissingMediaFailuresSkipAnEntry() {
        XCTAssertTrue(PlayerViewModel.isUnavailablePlaylistItem(HTTPError.http(statusCode: 403, body: nil)))
        XCTAssertTrue(PlayerViewModel.isUnavailablePlaylistItem(HTTPError.http(statusCode: 404, body: nil)))
        XCTAssertFalse(PlayerViewModel.isUnavailablePlaylistItem(HTTPError.http(statusCode: 503, body: nil)))
        XCTAssertFalse(PlayerViewModel.isUnavailablePlaylistItem(HTTPError.authorityChanged))
        XCTAssertFalse(PlayerViewModel.isUnavailablePlaylistItem(URLError(.timedOut)))
        XCTAssertTrue(PlayerViewModel.isUnavailablePlaylistItem(PlaybackV3TerminalFailure(reason: "source_unreadable", message: "Unavailable", retryable: false)))
        XCTAssertFalse(PlayerViewModel.isUnavailablePlaylistItem(PlaybackV3TerminalFailure(reason: "node_unavailable", message: "Unavailable", retryable: true)))
    }

    func testTwoPartPlaylistTitleFinishesBothPartsBeforeAdvancingEntry() throws {
        let json = #"[{"file_id":1,"presentation_kind":"multipart_movie","presentation_group_key":"split","presentation_part_index":1,"presentation_part_total":2},{"file_id":2,"presentation_kind":"multipart_movie","presentation_group_key":"split","presentation_part_index":2,"presentation_part_total":2}]"#
        let parts = try HTTPClient.makeJSONDecoder().decode([FileVersion].self, from: Data(json.utf8))
        XCTAssertEqual(PlayerQueueContinuation.resolve(isPlaylist: true, isShuffle: false,
            current: parts[0], versions: parts), .part(parts[1]))
        XCTAssertEqual(PlayerQueueContinuation.resolve(isPlaylist: true, isShuffle: false,
            current: parts[1], versions: parts), .playlistEntry)
        XCTAssertEqual(PlayerQueueContinuation.resolve(isPlaylist: false, isShuffle: false,
            current: parts[0], versions: parts), .postroll)
    }

    func testPlaylistAutoplayHonorsSettingAndStillWatchingLimit() {
        var guardState = PlayerStillWatchingGuard()
        XCTAssertFalse(guardState.canAutoAdvance(enabled: false, threshold: 0))
        XCTAssertTrue(guardState.canAutoAdvance(enabled: true, threshold: 1))
        guardState.recordAutoAdvance()
        XCTAssertFalse(guardState.canAutoAdvance(enabled: true, threshold: 1))
        XCTAssertTrue(guardState.canAutoAdvance(enabled: true, threshold: 0))
        guardState.recordViewerAction()
        XCTAssertTrue(guardState.canAutoAdvance(enabled: true, threshold: 1))
    }
}
