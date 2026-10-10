import Foundation
import Testing
import TurboFieldfare
import TurboFieldfareDecodeProtocol
@testable import TurboFieldfareAppCore

@Suite struct WebSearchTests {
    /// Trimmed from a live results page: one organic result, one ad, and a
    /// second organic result whose markup carries entities and inline tags.
    private static let page = """
        <div id="links" class="results">
          <div class="result results_links results_links_deep web-result ">
            <div class="links_main links_deep result__body">
              <h2 class="result__title">
                <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.swift.org%2F&amp;rut=9a58">Swift.org - <b>Welcome</b></a>
              </h2>
              <div class="result__extras"><a class="result__url" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.swift.org%2F&amp;rut=9a58"> www.swift.org </a></div>
              <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.swift.org%2F&amp;rut=9a58">Swift is a general-purpose
                 <b>programming</b> language.</a>
            </div>
          </div>
          <div class="result results_links results_links_deep result--ad ">
            <div class="links_main links_deep result__body">
              <h2 class="result__title">
                <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fduckduckgo.com%2Fy.js%3Fad_domain%3Dexample.com&amp;rut=77">Learn Swift Today</a>
              </h2>
              <a class="result__snippet" href="//duckduckgo.com/y.js?ad_domain=example.com">An advertisement.</a>
            </div>
          </div>
          <div class="result results_links results_links_deep web-result ">
            <div class="links_main links_deep result__body">
              <h2 class="result__title">
                <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FSwift_(programming_language)&amp;rut=41">Swift (programming language) &amp; more &#x27;quoted&#39;</a>
              </h2>
              <a class="result__snippet" href="#">Tom &amp; Jerry &lt;b&gt; 5 &gt; 3</a>
            </div>
          </div>
        </div>
        """

    @Test func organicResultsAreReadAndAdsAreSkipped() throws {
        let results = try DuckDuckGoResultsPage.results(in: Self.page, limit: 5)
        #expect(results.map(\.url.absoluteString) == [
            "https://www.swift.org/",
            "https://en.wikipedia.org/wiki/Swift_(programming_language)",
        ])
        #expect(results[0].title == "Swift.org - Welcome")
        #expect(results[0].snippet == "Swift is a general-purpose programming language.")
        #expect(results[1].title == "Swift (programming language) & more 'quoted'")
        #expect(results[1].snippet == "Tom & Jerry <b> 5 > 3")
    }

    @Test func theLimitIsRespected() throws {
        #expect(try DuckDuckGoResultsPage.results(in: Self.page, limit: 1).count == 1)
    }

    /// A page with no result markup is a layout change, and has to be told
    /// apart from a search that found nothing.
    @Test func anUnrecognisedPageIsAnErrorNotAnEmptyResult() throws {
        #expect(throws: WebSearchError.unreadable) {
            try DuckDuckGoResultsPage.results(in: "<html><body>hello</body></html>", limit: 5)
        }
        let nothing = "<div class=\"no-results\">No results found for x.</div>"
        #expect(try DuckDuckGoResultsPage.results(in: nothing, limit: 5).isEmpty)
    }

    @Test func theBotChallengeIsRecognised() {
        #expect(DuckDuckGoResultsPage.isChallenge(
            "<p>Unfortunately, bots use DuckDuckGo too.</p>"))
        #expect(!DuckDuckGoResultsPage.isChallenge(Self.page))
    }

    @Test func onlyUnwrappedWebAddressesAreAccepted() {
        #expect(DuckDuckGoResultsPage.destination(
            of: "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1&rut=1")?
            .absoluteString == "https://example.com/a?b=1")
        #expect(DuckDuckGoResultsPage.destination(of: "https://example.org/x")?
            .absoluteString == "https://example.org/x")
        #expect(DuckDuckGoResultsPage.destination(
            of: "//duckduckgo.com/l/?uddg=javascript%3Aalert(1)") == nil)
        #expect(DuckDuckGoResultsPage.destination(of: "//duckduckgo.com/y.js?ad=1") == nil)
        #expect(DuckDuckGoResultsPage.destination(of: "file:///etc/passwd") == nil)
    }

    @Test func entitiesDecodeWithoutEatingStrayAmpersands() {
        #expect(DuckDuckGoResultsPage.decodingEntities("a &amp; b & c &bogus; &#65;&#x42;")
            == "a & b & c &bogus; AB")
    }

    // MARK: - Tool

    private func call(_ arguments: JSONValue) -> ParsedToolCall {
        ParsedToolCall(id: "call_1", name: WebSearchTool.name,
                       arguments: arguments, argumentsJSON: "{}")
    }

    @Test func theQueryIsTakenFromTheCallOrRefused() {
        #expect(WebSearchTool.query(of: call(.object(["query": .string("  swift 6  ")])))
            == "swift 6")
        #expect(WebSearchTool.query(of: call(.object(["query": .string("   ")]))) == nil)
        #expect(WebSearchTool.query(of: call(.object(["q": .string("x")]))) == nil)
        #expect(WebSearchTool.query(of: call(.object(["query": .integer(3)]))) == nil)
    }

    @Test func theResponseListsResultsAndShrinksToTheLimit() throws {
        let results = try DuckDuckGoResultsPage.results(in: Self.page, limit: 5)
        let full = WebSearchTool.response(query: "swift", results: results)
        #expect(full.contains("1. Swift.org - Welcome"))
        #expect(full.contains("URL: https://www.swift.org/"))
        #expect(full.contains("2. Swift (programming language)"))
        let one = WebSearchTool.response(query: "swift", results: results, limit: 1)
        #expect(!one.contains("2. "))
        #expect(WebSearchTool.response(query: "swift", results: results, limit: 0)
            == "No results found for \"swift\".")
    }

    @Test func longSnippetsAreClipped() {
        let result = WebSearchResult(
            title: "t", url: URL(string: "https://example.com")!,
            snippet: String(repeating: "x", count: 5_000))
        #expect(WebSearchTool.response(query: "q", results: [result]).count < 500)
    }

    @Test func transcriptLinesKeepMarkdownIntact() throws {
        #expect(WebSearchTool.transcriptHeading(query: "a*b\n[c]")
            == "\n\n*Web search: a\\*b \\[c\\]*\n\n")
        let results = try DuckDuckGoResultsPage.results(in: Self.page, limit: 5)
        #expect(WebSearchTool.transcriptSources(results)
            == "Sources: [www.swift.org](https://www.swift.org/) · "
            + "[en.wikipedia.org](https://en.wikipedia.org/wiki/Swift_%28programming_language%29)\n\n")
        #expect(WebSearchTool.transcriptSources([]) == "No results.\n\n")
    }

    @Test func theSystemPromptCarriesTheDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7))!
        #expect(WebSearchTool.systemPrompt(today: day, calendar: calendar)
            .hasSuffix("Today's date is 2026-03-07."))
    }

    // MARK: - Plumbing

    @Test func theSettingDefaultsOnAndARequestDefaultsOff() throws {
        // A bare request is not the app's setting: nothing searches unless
        // the caller says so.
        #expect(!AppGenerationRequest(
            modelDirectory: URL(fileURLWithPath: "/tmp/m"), prompt: "hi").webSearchEnabled)
        #expect(MacAppSettings().webSearchEnabled)

        var settings = MacAppSettings()
        settings.webSearchEnabled = false
        let encoded = try JSONEncoder().encode(settings)
        #expect(!(try JSONDecoder().decode(MacAppSettings.self, from: encoded))
            .webSearchEnabled)

        // Settings written before the tool existed get the default.
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "webSearchEnabled")
        let older = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(MacAppSettings.self, from: older)
            .webSearchEnabled)
    }

    /// A request from a build that predates the field must still decode, as
    /// a turn that may not search.
    @Test func theWireFlagIsOptional() throws {
        let request = DecodeGenerationRequest(
            prompt: "hi", maxNewTokens: 8, maxContextTokens: 4_096,
            temperature: 0, webSearchEnabled: true)
        let encoded = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(DecodeGenerationRequest.self, from: encoded)
            .webSearchEnabled == true)
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "webSearchEnabled")
        let older = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(DecodeGenerationRequest.self, from: older)
            .webSearchEnabled == nil)
    }
}
