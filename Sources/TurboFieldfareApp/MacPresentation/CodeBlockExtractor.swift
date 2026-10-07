import Foundation

/// One fenced listing lifted out of an answer, ready to be saved or run.
public struct ExtractedCodeBlock: Equatable, Identifiable, Sendable {
    /// Position among the answer's listings, from zero.
    public let index: Int
    /// The first word of the info string, lowercased; empty when the fence
    /// named no language.
    public let language: String
    /// The listing's bytes, with the fence's own indentation removed and no
    /// trailing newline.
    public let code: String
    /// The fence was never closed — the answer was cut off inside it.
    public let isTruncated: Bool

    public var id: Int { index }

    public init(index: Int, language: String, code: String, isTruncated: Bool = false) {
        self.index = index
        self.language = language
        self.code = code
        self.isTruncated = isTruncated
    }

    public var lineCount: Int {
        code.isEmpty ? 0 : code.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// "python · 12 lines", for menus and pickers.
    public var summary: String {
        let name = language.isEmpty ? "text" : language
        let lines = lineCount == 1 ? "1 line" : "\(lineCount) lines"
        return "\(index + 1). \(name) · \(lines)"
    }
}

/// Finds the fenced code blocks in a raw markdown answer.
///
/// Uses the same fence grammar as the renderer (`FenceLine`), so a listing the
/// transcript draws as code is exactly a listing offered here. A fence inside
/// a list item is indented past the top-level limit; it is measured against
/// its own indentation, and its body has that indentation removed.
public enum CodeBlockExtractor {
    /// Every listing across several answers, oldest first and numbered as
    /// one list, with the index of the first listing of the newest answer
    /// that has any — the one a reader most likely wants.
    public static func blocks(inAnswers answers: [String]) -> (blocks: [ExtractedCodeBlock], newest: Int) {
        var all: [ExtractedCodeBlock] = []
        var newest = 0
        for answer in answers {
            let found = blocks(in: answer)
            guard !found.isEmpty else { continue }
            newest = all.count
            for block in found {
                all.append(ExtractedCodeBlock(
                    index: all.count, language: block.language,
                    code: block.code, isTruncated: block.isTruncated))
            }
        }
        return (all, newest)
    }

    public static func blocks(in answer: String) -> [ExtractedCodeBlock] {
        var blocks: [ExtractedCodeBlock] = []
        var open: (run: FenceLine.Run, language: String, lines: [Substring])?

        func finish(truncated: Bool) {
            guard let current = open else { return }
            let body = current.lines.map { strip(indent: current.run.indent, from: $0) }
            blocks.append(ExtractedCodeBlock(
                index: blocks.count,
                language: current.language,
                code: body.joined(separator: "\n"),
                isTruncated: truncated))
            open = nil
        }

        for line in answer.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = line.hasSuffix("\r") ? line.dropLast() : line
            let indent = leadingColumns(line)
            if let current = open {
                if let run = FenceLine.run(line, containerIndent: max(indent - 3, 0)),
                   run.closes(marker: current.run.marker, length: current.run.length) {
                    finish(truncated: false)
                } else {
                    open?.lines.append(line)
                }
                continue
            }
            guard let run = FenceLine.run(line, containerIndent: indent) else { continue }
            open = (run, language(of: line, run: run), [])
        }
        finish(truncated: true)
        return blocks
    }

    private static func language(of line: Substring, run: FenceLine.Run) -> String {
        let info = line.drop { $0 == " " || $0 == "\t" }.dropFirst(run.length)
        let word = info.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" || $0 == "," })
            .first ?? ""
        return word.lowercased()
    }

    private static func leadingColumns(_ line: Substring) -> Int {
        var columns = 0
        for character in line {
            if character == " " { columns += 1 } else if character == "\t" { columns += 4 } else { break }
        }
        return columns
    }

    private static func strip(indent: Int, from line: Substring) -> Substring {
        var remaining = indent
        var rest = line
        while remaining > 0, let first = rest.first, first == " " || first == "\t" {
            remaining -= first == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        return rest
    }
}
