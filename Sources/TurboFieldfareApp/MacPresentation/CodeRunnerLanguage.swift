import Foundation

/// How a listing's language tag maps to a file on disk and, when the language
/// is a script, the interpreter that runs it.
public struct CodeRunnerLanguage: Equatable, Sendable {
    public let name: String
    public let fileExtension: String
    /// The program and leading arguments; the saved file's path is appended.
    /// Nil for a language that can be saved but not run directly.
    public let interpreter: [String]?

    public var isRunnable: Bool { interpreter != nil }

    public static func forTag(_ tag: String) -> CodeRunnerLanguage {
        switch tag.lowercased() {
        case "python", "python3", "py":
            .init(name: "Python", fileExtension: "py", interpreter: ["python3"])
        case "bash":
            .init(name: "Bash", fileExtension: "sh", interpreter: ["bash"])
        case "sh", "shell", "console":
            .init(name: "Shell", fileExtension: "sh", interpreter: ["sh"])
        case "zsh":
            .init(name: "Zsh", fileExtension: "zsh", interpreter: ["zsh"])
        case "javascript", "js", "node", "mjs":
            .init(name: "JavaScript", fileExtension: "js", interpreter: ["node"])
        case "typescript", "ts":
            .init(name: "TypeScript", fileExtension: "ts", interpreter: ["npx", "--yes", "tsx"])
        case "ruby", "rb":
            .init(name: "Ruby", fileExtension: "rb", interpreter: ["ruby"])
        case "perl", "pl":
            .init(name: "Perl", fileExtension: "pl", interpreter: ["perl"])
        case "php":
            .init(name: "PHP", fileExtension: "php", interpreter: ["php"])
        case "lua":
            .init(name: "Lua", fileExtension: "lua", interpreter: ["lua"])
        case "swift":
            .init(name: "Swift", fileExtension: "swift", interpreter: ["swift"])
        case "applescript", "osascript":
            .init(name: "AppleScript", fileExtension: "applescript", interpreter: ["osascript"])
        case "go", "golang":
            .init(name: "Go", fileExtension: "go", interpreter: ["go", "run"])
        case "html", "htm":
            .init(name: "HTML", fileExtension: "html", interpreter: nil)
        case "css":
            .init(name: "CSS", fileExtension: "css", interpreter: nil)
        case "json":
            .init(name: "JSON", fileExtension: "json", interpreter: nil)
        case "yaml", "yml":
            .init(name: "YAML", fileExtension: "yaml", interpreter: nil)
        case "markdown", "md":
            .init(name: "Markdown", fileExtension: "md", interpreter: nil)
        case "c":
            .init(name: "C", fileExtension: "c", interpreter: nil)
        case "cpp", "c++", "cxx":
            .init(name: "C++", fileExtension: "cpp", interpreter: nil)
        case "rust", "rs":
            .init(name: "Rust", fileExtension: "rs", interpreter: nil)
        case "java":
            .init(name: "Java", fileExtension: "java", interpreter: nil)
        case "sql":
            .init(name: "SQL", fileExtension: "sql", interpreter: nil)
        default:
            .init(name: tag.isEmpty ? "Text" : tag, fileExtension: "txt", interpreter: nil)
        }
    }

    /// The language tag for a file opened from disk. A file without an
    /// extension is read from its `#!` line, as the shell would.
    public static func tag(forFileExtension fileExtension: String, code: String) -> String {
        switch fileExtension.lowercased() {
        case "py", "pyw": return "python"
        case "sh", "bash": return "bash"
        case "zsh": return "zsh"
        case "js", "mjs", "cjs": return "javascript"
        case "ts", "mts": return "typescript"
        case "rb": return "ruby"
        case "pl", "pm": return "perl"
        case "php": return "php"
        case "lua": return "lua"
        case "swift": return "swift"
        case "applescript": return "applescript"
        case "go": return "go"
        case "html", "htm": return "html"
        case "css": return "css"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "md", "markdown": return "markdown"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp": return "cpp"
        case "rs": return "rust"
        case "java": return "java"
        case "sql": return "sql"
        case "":
            guard code.hasPrefix("#!") else { return "" }
            let shebang = code.prefix { $0 != "\n" }
            for (needle, tag) in [("python", "python"), ("node", "javascript"),
                                  ("ruby", "ruby"), ("perl", "perl"), ("zsh", "zsh"),
                                  ("bash", "bash"), ("/sh", "sh")]
            where shebang.contains(needle) {
                return tag
            }
            return ""
        default:
            return fileExtension.lowercased()
        }
    }

    /// A file name the save panel and the scratch run start from.
    public func suggestedFileName(index: Int) -> String {
        "snippet-\(index + 1).\(fileExtension)"
    }
}
