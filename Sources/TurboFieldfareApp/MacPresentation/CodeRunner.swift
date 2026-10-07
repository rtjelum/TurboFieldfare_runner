import Foundation
import Observation

/// Saves listings from answers and runs them as a child process.
///
/// Nothing here runs on the model's initiative: a run starts only from the
/// runner window's Run button, after the person has confirmed it. The process
/// runs as the signed-in user with that user's permissions, so the confirmation
/// says so.
///
/// The interpreter is resolved through a login `zsh`, because an app launched
/// from Finder or the Dock inherits launchd's minimal `PATH` and would not find
/// a Homebrew `node` or `python3` that works in Terminal.
///
/// Python runs in a virtual environment of its own. Before a run, the
/// script's imports are read and the ones the environment lacks are listed in
/// the confirmation; only after it are they installed with pip.
@MainActor
@Observable
public final class CodeRunner {
    public enum Phase: Equatable, Sendable {
        case idle
        case preparing
        case running
        case finished(status: Int32)
        case stopped
        case failed(String)
    }

    public enum Stream: Sendable { case stdout, stderr, system }

    public struct OutputLine: Identifiable, Equatable, Sendable {
        public let id: Int
        public let stream: Stream
        public let text: String
    }

    /// The listings of the answer the window was opened from.
    public private(set) var blocks: [ExtractedCodeBlock] = []
    public var selectedIndex = 0 {
        didSet { if selectedIndex != oldValue { loadSelection() } }
    }
    /// The code to save or run, editable before either.
    public var code = ""
    public var languageTag = ""
    /// Where the code was last saved; a run uses this file when it matches.
    public private(set) var savedURL: URL?
    public private(set) var phase: Phase = .idle
    public private(set) var output: [OutputLine] = []
    /// Bumped each time the window is pointed at new listings, so the window
    /// can come forward.
    public private(set) var presentationID = 0

    private var process: Process?
    private var nextLineID = 0
    private var partial: [Stream: String] = [:]
    /// Total bytes kept, so a runaway loop printing forever cannot exhaust
    /// memory; past the cap the output is dropped with a note.
    private var keptBytes = 0
    private static let outputByteCap = 4 * 1024 * 1024

    public init(pythonEnvironment: URL = CodeRunner.defaultPythonEnvironment) {
        self.pythonEnvironment = pythonEnvironment
    }

    public var language: CodeRunnerLanguage { .forTag(languageTag) }
    /// Busy from preparation until the last step ends.
    public var isRunning: Bool { phase == .running || phase == .preparing }

    public func present(blocks: [ExtractedCodeBlock], selecting index: Int = 0) {
        self.blocks = blocks
        selectedIndex = min(max(index, 0), max(blocks.count - 1, 0))
        loadSelection()
        presentationID += 1
    }

    private func loadSelection() {
        guard blocks.indices.contains(selectedIndex) else {
            code = ""
            languageTag = ""
            return
        }
        let block = blocks[selectedIndex]
        code = block.code
        languageTag = block.language
        savedURL = nil
    }

    // MARK: - Saving

    /// Writes the code with a trailing newline, as editors and interpreters
    /// expect, and marks a script executable when it has a shebang.
    public func save(to url: URL) throws {
        try Self.write(code, to: url)
        savedURL = url
    }

    nonisolated static func write(_ code: String, to url: URL) throws {
        let text = code.hasSuffix("\n") ? code : code + "\n"
        try Data(text.utf8).write(to: url, options: .atomic)
        if text.hasPrefix("#!") {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    // MARK: - Running

    /// What a confirmed run will do, worked out before the confirmation so
    /// the person sees every package that would be downloaded.
    public struct RunPlan: Equatable, Sendable {
        public let file: URL
        /// Executed in order; a step that fails ends the run.
        public let steps: [Step]
        /// PyPI distributions the script imports that the environment lacks.
        public let packages: [String]
        /// A `requirements.txt` beside the file that will be installed first.
        public let requirements: URL?
        /// Imports that cannot be installed with pip, such as `tkinter`.
        public let unavailable: [String]
        public let environment: URL?

        public var commandDescription: String {
            steps.map(\.description).joined(separator: " && ")
        }
    }

    public struct Step: Equatable, Sendable {
        public let executable: URL
        public let arguments: [String]
        public let description: String
    }

    /// The command line a run will use, for the confirmation and the log.
    public func commandDescription(for url: URL) -> String? {
        guard let interpreter = language.interpreter else { return nil }
        return (interpreter + [url.lastPathComponent]).joined(separator: " ")
    }

    /// The file a run would execute: the saved file if its contents are
    /// still what is in the editor, otherwise a fresh scratch file.
    public func runTarget() throws -> URL {
        if let savedURL,
           let onDisk = try? String(contentsOf: savedURL, encoding: .utf8),
           onDisk == code || onDisk == code + "\n" {
            return savedURL
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboFieldfareRuns", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(
            language.suggestedFileName(index: selectedIndex))
        try Self.write(code, to: url)
        return url
    }

    /// Where Python runs get their packages: one environment shared by every
    /// run, so a package is downloaded once rather than on each run.
    public let pythonEnvironment: URL

    public static var defaultPythonEnvironment: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TurboFieldfare/CodeRunner/python-venv", isDirectory: true)
    }

    /// Readies a run of `url`. Python creates its environment if needed and
    /// lists the missing packages; nothing is downloaded or run here.
    public func prepare(_ url: URL) async throws -> RunPlan {
        guard !isRunning, let interpreter = language.interpreter else {
            throw CodeRunnerError.notRunnable
        }
        guard interpreter.first == "python3" else {
            return RunPlan(
                file: url,
                steps: [Self.loginShellStep(interpreter + [url.path],
                                            description: commandDescription(for: url) ?? "")],
                packages: [], requirements: nil, unavailable: [], environment: nil)
        }
        phase = .preparing
        defer { if phase == .preparing { phase = .idle } }
        let environment = pythonEnvironment
        let python = environment.appendingPathComponent("bin/python")
        if !FileManager.default.isExecutableFile(atPath: python.path) {
            try FileManager.default.createDirectory(
                at: environment.deletingLastPathComponent(), withIntermediateDirectories: true)
            let created = await Self.capture(Self.loginShellStep(
                ["python3", "-m", "venv", environment.path], description: ""))
            guard created.status == 0 else {
                throw CodeRunnerError.environment(
                    "Could not create a Python environment: \(created.output)")
            }
        }
        let scan = await Self.capture(Step(
            executable: python,
            arguments: ["-I", "-c", PythonImportScan.source, url.path],
            description: ""))
        guard scan.status == 0,
              let data = scan.output.split(separator: "\n").last.map({ Data($0.utf8) }),
              let result = try? JSONDecoder().decode(PythonImportScan.Result.self, from: data)
        else {
            throw CodeRunnerError.environment("Could not read the script's imports: \(scan.output)")
        }
        let packages = result.install.filter(PythonImportScan.isSafePackageName)
        let requirementsFile = url.deletingLastPathComponent()
            .appendingPathComponent("requirements.txt")
        let requirements = FileManager.default.fileExists(atPath: requirementsFile.path)
            && !url.path.hasPrefix(FileManager.default.temporaryDirectory.path)
            ? requirementsFile : nil

        var steps: [Step] = []
        if !packages.isEmpty || requirements != nil {
            var arguments = ["-m", "pip", "install", "--disable-pip-version-check"]
            if let requirements { arguments += ["-r", requirements.path] }
            arguments += packages
            steps.append(Step(
                executable: python, arguments: arguments,
                description: "pip install " + ((requirements != nil ? ["-r requirements.txt"] : [])
                    + packages).joined(separator: " ")))
        }
        steps.append(Step(executable: python, arguments: [url.path],
                          description: "python \(url.lastPathComponent)"))
        return RunPlan(file: url, steps: steps, packages: packages,
                       requirements: requirements, unavailable: result.unavailable,
                       environment: environment)
    }

    public func run(_ plan: RunPlan) {
        guard !isRunning, !plan.steps.isEmpty else { return }
        output = []
        partial = [:]
        keptBytes = 0
        append(.system, "$ cd \(plan.file.deletingLastPathComponent().path)\n")
        if let environment = plan.environment {
            append(.system, "# Python environment: \(environment.path)\n")
        }
        for name in plan.unavailable {
            append(.system, "# \(name) cannot be installed with pip; the script may fail to import it.\n")
        }
        remainingSteps = plan.steps
        directory = plan.file.deletingLastPathComponent()
        startNextStep()
    }

    private var remainingSteps: [Step] = []
    private var directory: URL?

    private func startNextStep() {
        guard !remainingSteps.isEmpty, let directory else { return }
        let step = remainingSteps.removeFirst()
        append(.system, "$ \(step.description)\n")

        let process = Process()
        process.executableURL = step.executable
        process.arguments = step.arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        forward(stdout, as: .stdout)
        forward(stderr, as: .stderr)
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let reason = finished.terminationReason
            // Give the pipe handlers a moment to deliver the tail.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MainActor.assumeIsolated {
                    self?.didTerminate(status: status, reason: reason)
                }
            }
        }
        do {
            try process.run()
            self.process = process
            phase = .running
        } catch {
            remainingSteps = []
            self.process = nil
            phase = .failed(error.localizedDescription)
            append(.system, "Could not start: \(error.localizedDescription)\n")
        }
    }

    /// A step run through a login `zsh`, so an interpreter on the user's
    /// Terminal `PATH` is found. `exec "$@"` hands the arguments over
    /// verbatim; nothing from the listing or the path is parsed by the shell.
    nonisolated static func loginShellStep(_ command: [String], description: String) -> Step {
        Step(executable: URL(fileURLWithPath: "/bin/zsh"),
             arguments: ["-l", "-c", "exec \"$@\"", "zsh"] + command,
             description: description)
    }

    /// Runs a short helper to completion, stdout and stderr together.
    nonisolated static func capture(_ step: Step) async -> (status: Int32, output: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = step.executable
            process.arguments = step.arguments
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return (-1, error.localizedDescription)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus,
                    String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    public func stop() {
        remainingSteps = []
        guard let process, process.isRunning else { return }
        phase = .stopped
        process.interrupt()
        let pid = process.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak process] in
            guard let process, process.isRunning else { return }
            kill(pid, SIGKILL)
        }
    }

    public func clearOutput() {
        guard !isRunning else { return }
        output = []
        phase = .idle
    }

    public var outputText: String { output.map(\.text).joined() }

    private func forward(_ pipe: Pipe, as stream: Stream) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(text, from: stream) }
            }
        }
    }

    private func receive(_ text: String, from stream: Stream) {
        let combined = (partial[stream] ?? "") + text
        guard let lastNewline = combined.lastIndex(of: "\n") else {
            partial[stream] = combined
            return
        }
        partial[stream] = String(combined[combined.index(after: lastNewline)...])
        append(stream, String(combined[...lastNewline]))
    }

    private func didTerminate(status: Int32, reason: Process.TerminationReason) {
        for stream in [Stream.stdout, .stderr] {
            if let rest = partial[stream], !rest.isEmpty { append(stream, rest + "\n") }
        }
        partial = [:]
        process = nil
        if phase == .stopped {
            remainingSteps = []
            append(.system, "Stopped.\n")
            return
        }
        let failed = reason == .uncaughtSignal || status != 0
        if !failed, !remainingSteps.isEmpty {
            startNextStep()
            return
        }
        if failed, !remainingSteps.isEmpty {
            append(.system, "Setup failed; the script was not run.\n")
            remainingSteps = []
        }
        phase = .finished(status: status)
        let description = reason == .uncaughtSignal
            ? "Terminated by signal \(status)."
            : "Exited with status \(status)."
        append(.system, description + "\n")
    }

    private func append(_ stream: Stream, _ text: String) {
        guard keptBytes < Self.outputByteCap else { return }
        keptBytes += text.utf8.count
        output.append(OutputLine(id: nextLineID, stream: stream, text: text))
        nextLineID += 1
        if keptBytes >= Self.outputByteCap {
            output.append(OutputLine(
                id: nextLineID, stream: .system,
                text: "Output limit reached; further output is discarded.\n"))
            nextLineID += 1
        }
    }
}

public enum CodeRunnerError: LocalizedError {
    case notRunnable
    case environment(String)

    public var errorDescription: String? {
        switch self {
        case .notRunnable: "This language can be saved but not run here."
        case .environment(let message): message
        }
    }
}
