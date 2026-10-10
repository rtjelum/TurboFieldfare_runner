import Foundation
import TurboFieldfare

public struct WebSearchResult: Equatable, Sendable {
    public let title: String
    public let url: URL
    public let snippet: String

    public init(title: String, url: URL, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

public enum WebSearchError: Error, Equatable, CustomStringConvertible {
    case emptyQuery
    case blocked
    case http(status: Int)
    case unreadable
    case transport(String)

    public var description: String {
        switch self {
        case .emptyQuery: "the search query was empty"
        case .blocked: "the search service refused the request as automated"
        case .http(let status): "the search service answered HTTP \(status)"
        case .unreadable: "the search results page could not be read"
        case .transport(let detail): "the search request failed: \(detail)"
        }
    }
}

/// What the web tool asks of a search backend. The session only ever holds
/// this, so a test drives the tool loop without a network.
public protocol WebSearchProviding: Sendable {
    func search(query: String, maxResults: Int) async throws -> [WebSearchResult]
}

/// DuckDuckGo's keyless HTML results page.
///
/// This is a page meant for people, not an API: its markup can change without
/// notice, and a request it takes for a bot is answered with a challenge. Both
/// are reported as errors the model is told about, never as an empty result
/// set, so a broken scrape cannot pass for "the web has nothing on this".
public struct DuckDuckGoWebSearch: WebSearchProviding {
    static let endpoint = URL(string: "https://html.duckduckgo.com/html/")!
    /// Identifies the app rather than imitating a browser. The endpoint
    /// challenges a spoofed browser agent that arrives without that browser's
    /// other headers, and answers this one.
    static let userAgent = "TurboFieldfare/1.0 (macOS; local chat app)"
    static let timeout: TimeInterval = 12
    static let maximumPageBytes = 2 * 1_024 * 1_024

    public init() {}

    public func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebSearchError.emptyQuery }
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        // `URLQueryItem` leaves `+` alone, which a form decoder reads as a
        // space: "C++" would be searched as "C  ".
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!, timeoutInterval: Self.timeout)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw WebSearchError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard data.count <= Self.maximumPageBytes else { throw WebSearchError.unreadable }
        let page = String(decoding: data, as: UTF8.self)
        // The challenge arrives as 202 with an ordinary HTML body.
        guard status != 202, !DuckDuckGoResultsPage.isChallenge(page) else {
            throw WebSearchError.blocked
        }
        guard status == 200 else { throw WebSearchError.http(status: status) }
        return try DuckDuckGoResultsPage.results(in: page, limit: maxResults)
    }
}

/// Reads organic results out of the HTML results page.
enum DuckDuckGoResultsPage {
    private static let resultOpen = "<div class=\"result "

    static func isChallenge(_ page: String) -> Bool {
        page.contains("anomaly-modal") || page.contains("bots use DuckDuckGo too")
    }

    /// Throws `unreadable` for a page with no result markup at all, which is a
    /// layout change; a page that says it found nothing returns an empty list.
    static func results(in page: String, limit: Int) throws -> [WebSearchResult] {
        let blocks = page.components(separatedBy: resultOpen).dropFirst()
        guard !blocks.isEmpty else {
            if page.contains("class=\"no-results\"") || page.contains("No results") {
                return []
            }
            throw WebSearchError.unreadable
        }
        var results: [WebSearchResult] = []
        var seen: Set<URL> = []
        for block in blocks where results.count < limit {
            // The class list is what the split left at the head of the block.
            let classes = block.prefix { $0 != "\"" }
            guard !classes.contains("result--ad") else { continue }
            guard let anchor = element(in: block, withClass: "result__a"),
                  let href = attribute("href", in: anchor.tag),
                  let url = destination(of: href), seen.insert(url).inserted else {
                continue
            }
            let title = plainText(anchor.body)
            guard !title.isEmpty else { continue }
            let snippet = element(in: block, withClass: "result__snippet")
                .map { plainText($0.body) } ?? ""
            results.append(WebSearchResult(title: title, url: url, snippet: snippet))
        }
        return results
    }

    /// The first `<a>` in `html` carrying `className`, as its opening tag and
    /// inner HTML.
    private static func element(in html: String,
                                withClass className: String) -> (tag: Substring, body: Substring)? {
        var search = html.startIndex..<html.endIndex
        while let open = html.range(of: "<a ", range: search),
              let tagEnd = html.range(of: ">", range: open.upperBound..<html.endIndex) {
            let tag = html[open.lowerBound..<tagEnd.upperBound]
            if let classes = attribute("class", in: tag),
               classes.split(separator: " ").contains(Substring(className)),
               let close = html.range(of: "</a>", range: tagEnd.upperBound..<html.endIndex) {
                return (tag, html[tagEnd.upperBound..<close.lowerBound])
            }
            search = tagEnd.upperBound..<html.endIndex
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: Substring) -> String? {
        guard let start = tag.range(of: " \(name)=\""),
              let end = tag.range(of: "\"", range: start.upperBound..<tag.endIndex) else {
            return nil
        }
        return decodingEntities(String(tag[start.upperBound..<end.lowerBound]))
    }

    /// Result links go through a redirect that carries the real address in
    /// `uddg`. Anything that is not plain http(s) once unwrapped is dropped.
    static func destination(of href: String) -> URL? {
        let absolute = href.hasPrefix("//") ? "https:" + href : href
        guard var url = URL(string: absolute) else { return nil }
        // `URL.path` drops the trailing slash of "/l/".
        if url.host == "duckduckgo.com", url.path == "/l" || url.path == "/l/" {
            guard let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "uddg" })?.value,
                  let unwrapped = URL(string: target) else {
                return nil
            }
            url = unwrapped
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty, !host.hasSuffix("duckduckgo.com") else {
            return nil
        }
        return url
    }

    static func plainText(_ html: Substring) -> String {
        var text = ""
        var inTag = false
        for character in html {
            if character == "<" { inTag = true; continue }
            if character == ">", inTag { inTag = false; continue }
            if !inTag { text.append(character) }
        }
        return decodingEntities(text)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
    ]

    static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = text[...]
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            let tail = rest[rest.index(after: ampersand)...]
            guard let semicolon = tail.prefix(10).firstIndex(of: ";") else {
                result.append("&")
                rest = tail
                continue
            }
            let name = tail[..<semicolon]
            let decoded: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                decoded = UInt32(name.dropFirst(2), radix: 16)
                    .flatMap(UnicodeScalar.init).map(String.init)
            } else if name.hasPrefix("#") {
                decoded = UInt32(name.dropFirst())
                    .flatMap(UnicodeScalar.init).map(String.init)
            } else {
                decoded = namedEntities[String(name)]
            }
            if let decoded {
                result += decoded
                rest = tail[tail.index(after: semicolon)...]
            } else {
                result.append("&")
                rest = tail
            }
        }
        return result + rest
    }
}

/// The one tool the Mac app declares to the model.
public enum WebSearchTool {
    public static let name = "web_search"
    public static let maximumResults = 5
    /// Searches the model may make while answering one message. A model that
    /// keeps searching is told to answer instead of being cut off mid-turn.
    public static let maximumSearchesPerTurn = 3
    static let maximumTitleCharacters = 120
    static let maximumSnippetCharacters = 320

    public static let definition = GFTokenizer.FunctionDefinition(
        name: name,
        description: "Search the web and return the top results with their title, "
            + "URL and a short excerpt.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("What to search for."),
                ]),
            ]),
            "required": .array([.string("query")]),
        ]))

    /// The system turn that goes with the declaration. The date is fixed when
    /// the conversation opens: it is part of the tokens the KV is built on.
    public static func systemPrompt(today: Date = Date(),
                                    calendar: Calendar = .current) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: today)
        let date = String(format: "%04d-%02d-%02d",
                          day.year ?? 0, day.month ?? 0, day.day ?? 0)
        return "You can search the web with the \(name) tool. Use it when an answer "
            + "depends on recent or current information, or on facts you are not "
            + "sure of; otherwise answer directly. Base your answer on the results "
            + "and name the URLs you relied on. Today's date is \(date)."
    }

    /// The query of a parsed call, or nil when the model left it out.
    public static func query(of call: ParsedToolCall) -> String? {
        guard case .string(let query)? = call.arguments.objectValue?["query"] else {
            return nil
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What the model reads back. `limit` lets the caller drop trailing
    /// results until the response fits the context that is left.
    public static func response(query: String,
                                results: [WebSearchResult],
                                limit: Int = maximumResults) -> String {
        let kept = results.prefix(max(limit, 0))
        guard !kept.isEmpty else { return "No results found for \"\(query)\"." }
        var lines = ["Results for \"\(query)\":"]
        for (index, result) in kept.enumerated() {
            lines.append("\(index + 1). \(clipped(result.title, to: maximumTitleCharacters))")
            lines.append("   URL: \(result.url.absoluteString)")
            if !result.snippet.isEmpty {
                lines.append("   \(clipped(result.snippet, to: maximumSnippetCharacters))")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func failureResponse(_ reason: String) -> String {
        "Error: \(reason). Answer without the search, and say that you could not search."
    }

    // MARK: - Transcript lines

    /// Shown where the model's call was, in place of the call's raw markup.
    public static func transcriptHeading(query: String) -> String {
        "\n\n*Web search: \(escapingMarkdown(query))*\n\n"
    }

    public static func transcriptSources(_ results: [WebSearchResult]) -> String {
        guard !results.isEmpty else { return "No results.\n\n" }
        let links = results.map { result in
            let label = escapingMarkdown(result.url.host ?? result.url.absoluteString)
            let target = result.url.absoluteString
                .replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
            return "[\(label)](\(target))"
        }
        return "Sources: " + links.joined(separator: " · ") + "\n\n"
    }

    public static func transcriptFailure(_ reason: String) -> String {
        "Search unavailable: \(escapingMarkdown(reason)).\n\n"
    }

    private static func clipped(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    private static func escapingMarkdown(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if "\\`*_[]<>".contains(character) { escaped.append("\\") }
            escaped.append(character.isNewline ? " " : character)
        }
        return escaped
    }
}
