import XCTest
@testable import TermLLM

final class CatalogParsingTests: XCTestCase {
    func testKeepsReadableSongsFromASearchPage() {
        let json = #"""
        {"results": {"songs": {"href": "/v1/catalog/au/search?term=portishead", "data": [
          {"id": "1", "type": "songs", "attributes": {"name": "Glory Box", "artistName": "Portishead",
            "albumName": "Dummy", "artwork": {"url": "https://is1.mzstatic.com/a/{w}x{h}bb.jpg", "width": 3000}}},
          {"id": "2", "type": "songs"},
          {"id": "3", "type": "songs", "attributes": {"name": 42}},
          {"type": "songs", "attributes": {"name": "No id"}},
          {"id": "4", "type": "songs", "attributes": {"name": "Roads", "artwork": "odd"}}
        ]}}}
        """#
        let songs = CatalogParsing.searchSongs(Data(json.utf8))
        XCTAssertEqual(songs, [
            MusicTrack(id: "1", title: "Glory Box", artist: "Portishead", album: "Dummy",
                       artworkURL: URL(string: "https://is1.mzstatic.com/a/300x300bb.jpg")),
            MusicTrack(id: "4", title: "Roads", artist: nil, album: nil, artworkURL: nil),
        ])
    }

    func testEmptyOrUnexpectedResponses() {
        XCTAssertEqual(CatalogParsing.searchSongs(Data(#"{"results": {}}"#.utf8)), [])
        XCTAssertEqual(CatalogParsing.searchSongs(Data("not json".utf8)), [])
        XCTAssertEqual(CatalogParsing.resourceSongs(Data(#"{"errors": [{"status": "401"}]}"#.utf8)), [])
    }

    func testResourceLookups() {
        let json = #"{"data": [{"id": "9", "attributes": {"name": "Teardrop", "artistName": "Massive Attack"}}]}"#
        XCTAssertEqual(CatalogParsing.resourceSongs(Data(json.utf8)).map(\.title), ["Teardrop"])
    }

    func testDescribesDecodingFailures() {
        struct Song: Decodable { let name: String }
        struct Page: Decodable { let data: [Song] }
        do {
            _ = try JSONDecoder().decode(Page.self, from: Data(#"{"data": [{"name": "ok"}, {}]}"#.utf8))
            XCTFail("expected a decoding error")
        } catch {
            XCTAssertTrue(AppleMusicCatalog.isDecodingFailure(error))
            XCTAssertEqual(CatalogParsing.describe(error), "missing name at data.1")
            XCTAssertEqual(error.localizedDescription, "The data couldn’t be read because it is missing.")
        }
        XCTAssertTrue(AppleMusicCatalog.isDecodingFailure(NSError(domain: NSCocoaErrorDomain, code: 4864)))
        XCTAssertFalse(AppleMusicCatalog.isDecodingFailure(MusicError.notAuthorized))
        XCTAssertFalse(AppleMusicCatalog.isDecodingFailure(URLError(.notConnectedToInternet)))
    }
}
