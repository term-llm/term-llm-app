import XCTest
@testable import TermLLM

// MARK: - HTML parsing tests

final class HubClientHTMLParsingTests: XCTestCase {

    func testParseDashboardConfig() throws {
        let html = """
        <div id="root" data-hub-config="{&#34;page&#34;:&#34;dashboard&#34;,&#34;authMode&#34;:&#34;none&#34;,&#34;canAddNodes&#34;:true,&#34;passkeyAuth&#34;:false}"></div>
        """
        let config = try HubClient.parseDataHubConfig(html: html)
        XCTAssertEqual(config.page, "dashboard")
        XCTAssertEqual(config.authMode, "none")
        XCTAssertTrue(config.canAddNodes)
    }

    func testParseBearerLoginConfig() throws {
        let html = """
        <div id="root" data-hub-config="{&#34;page&#34;:&#34;bearer-login&#34;,&#34;authMode&#34;:&#34;bearer&#34;,&#34;basePath&#34;:&#34;/hub&#34;,&#34;invalidToken&#34;:true,&#34;formAction&#34;:&#34;/hub/&#34;}"></div>
        """
        let config = try HubClient.parseDataHubConfig(html: html)
        XCTAssertEqual(config.page, "bearer-login")
        XCTAssertEqual(config.invalidToken, true)
        XCTAssertFalse(config.canAddNodes)
        XCTAssertFalse(config.passkeyAuth)
    }

    func testParseWithQuotEntity() throws {
        let html = """
        <div id="root" data-hub-config="{&quot;page&quot;:&quot;dashboard&quot;,&quot;authMode&quot;:&quot;passkey&quot;}"></div>
        """
        XCTAssertEqual(try HubClient.parseDataHubConfig(html: html).authMode, "passkey")
    }

    func testParseWithAmpEntity() throws {
        let html = """
        <div id="root" data-hub-config="{&#34;page&#34;:&#34;dashboard&#34;,&#34;authMode&#34;:&#34;none&#34;,&#34;basePath&#34;:&#34;/a&amp;b&#34;}"></div>
        """
        XCTAssertEqual(try HubClient.parseDataHubConfig(html: html).basePath, "/a&b")
    }

    func testParseMissingAttributeThrows() {
        XCTAssertThrowsError(try HubClient.parseDataHubConfig(html: "<div id=\"root\"></div>")) { error in
            XCTAssertTrue((error as? HubAPIError)?.message.contains("does not contain") == true)
        }
    }

    func testParseMalformedJSONThrows() {
        let html = "<div data-hub-config=\"{not valid}\"></div>"
        XCTAssertThrowsError(try HubClient.parseDataHubConfig(html: html)) { error in
            XCTAssertTrue((error as? HubAPIError)?.message.contains("malformed") == true)
        }
    }

    func testParseNoClosingQuoteThrows() {
        XCTAssertThrowsError(try HubClient.parseDataHubConfig(html: "data-hub-config=\"{&#34;page&#34;")) { error in
            XCTAssertTrue((error as? HubAPIError)?.message.contains("closing quote") == true)
        }
    }
}
