import Foundation
import Testing
@testable import TurboFieldfareMacPresentation

@Suite struct CodeBlockExtractorTests {
    @Test func extractsEachFencedBlockWithItsLanguage() {
        let answer = """
        Here is a script:

        ```python
        print("hi")

        print("bye")
        ```

        And a shell one:

        ~~~bash title="x"
        echo ok
        ~~~
        """
        let blocks = CodeBlockExtractor.blocks(in: answer)
        #expect(blocks.count == 2)
        #expect(blocks[0].language == "python")
        #expect(blocks[0].code == "print(\"hi\")\n\nprint(\"bye\")")
        #expect(!blocks[0].isTruncated)
        #expect(blocks[1].language == "bash")
        #expect(blocks[1].code == "echo ok")
    }

    @Test func untaggedAndTruncatedBlocks() {
        let blocks = CodeBlockExtractor.blocks(in: "```\nplain\n```\n\n```js\nconsole.log(1)")
        #expect(blocks.map(\.language) == ["", "js"])
        #expect(blocks[1].isTruncated)
        #expect(blocks[1].code == "console.log(1)")
    }

    @Test func listItemFenceLosesItsIndentation() {
        let answer = "1. Save this:\n\n   ```sh\n   echo a\n     echo b\n   ```\n"
        let blocks = CodeBlockExtractor.blocks(in: answer)
        #expect(blocks.count == 1)
        #expect(blocks[0].code == "echo a\n  echo b")
    }

    @Test func longerFenceIsNotClosedByShorterOne() {
        let answer = "````markdown\n```py\nx\n```\n````"
        let blocks = CodeBlockExtractor.blocks(in: answer)
        #expect(blocks.count == 1)
        #expect(blocks[0].code == "```py\nx\n```")
    }

    @Test func inlineTripleBackticksAreNotAFence() {
        #expect(CodeBlockExtractor.blocks(in: "Use ```bash``` here.").isEmpty)
    }

    @Test func blocksAcrossAnswersAreNumberedAsOneListPointingAtTheNewest() {
        let found = CodeBlockExtractor.blocks(inAnswers: [
            "```py\na\n```\n```sh\nb\n```",
            "no code here",
            "```js\nc\n```",
            "still none",
        ])
        #expect(found.blocks.map(\.code) == ["a", "b", "c"])
        #expect(found.blocks.map(\.index) == [0, 1, 2])
        #expect(found.newest == 2)
        #expect(CodeBlockExtractor.blocks(inAnswers: ["none"]).blocks.isEmpty)
    }

    @Test func languageMapping() {
        #expect(CodeRunnerLanguage.forTag("py").interpreter == ["python3"])
        #expect(CodeRunnerLanguage.forTag("JavaScript").fileExtension == "js")
        #expect(!CodeRunnerLanguage.forTag("html").isRunnable)
        #expect(CodeRunnerLanguage.forTag("").suggestedFileName(index: 2) == "snippet-3.txt")
    }
}

@MainActor
@Suite(.serialized) struct CodeRunnerTests {
    @Test func savesWithTrailingNewlineAndRunsTheSavedFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let runner = CodeRunner(pythonEnvironment: directory.appendingPathComponent("venv"))
        runner.present(blocks: [ExtractedCodeBlock(
            index: 0, language: "sh", code: "echo out\necho err >&2\nexit 3")])
        let url = directory.appendingPathComponent("t.sh")
        try runner.save(to: url)
        #expect(try String(contentsOf: url, encoding: .utf8).hasSuffix("exit 3\n"))
        #expect(try runner.runTarget() == url)

        let plan = try await runner.prepare(url)
        #expect(plan.steps.count == 1)
        runner.run(plan)
        for _ in 0..<100 where runner.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(runner.phase == .finished(status: 3))
        #expect(runner.output.contains { $0.stream == .stdout && $0.text == "out\n" })
        #expect(runner.output.contains { $0.stream == .stderr && $0.text == "err\n" })
    }

    @Test func editedCodeRunsFromAScratchFile() throws {
        let runner = CodeRunner()
        runner.present(blocks: [ExtractedCodeBlock(index: 0, language: "py", code: "1")])
        runner.code = "print(2)"
        let target = try runner.runTarget()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        #expect(target.pathExtension == "py")
        #expect(try String(contentsOf: target, encoding: .utf8) == "print(2)\n")
    }

    /// Creates a real environment but downloads nothing: the plan is only
    /// read, never run.
    @Test func pythonPlanListsOnlyMissingRequiredPackages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "X = 1\n".write(to: directory.appendingPathComponent("helper.py"),
                            atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("main.py")
        try """
        import json, os.path
        import requests
        from PIL import Image
        import helper
        from . import sibling
        try:
            import ujson
        except ImportError:
            ujson = None
        import tkinter_fake_but_unmapped as nope
        def f():
            import yaml
        """.write(to: script, atomically: true, encoding: .utf8)

        let environment = directory.appendingPathComponent("venv")
        let runner = CodeRunner(pythonEnvironment: environment)
        runner.present(blocks: [ExtractedCodeBlock(index: 0, language: "python", code: "")])
        let plan = try await runner.prepare(script)
        #expect(plan.packages == ["requests", "pillow", "tkinter_fake_but_unmapped", "pyyaml"])
        #expect(plan.steps.count == 2)
        #expect(plan.steps[0].arguments.prefix(3) == ["-m", "pip", "install"])
        #expect(plan.steps[1].executable == environment.appendingPathComponent("bin/python"))
        #expect(plan.steps[1].arguments == [script.path])
        #expect(runner.phase == .idle)
    }

    /// A model typo must not block the run: the plan says where the script
    /// is broken and still runs it, so Python can report the error in full.
    @Test func scriptThatDoesNotParseStillGetsAPlan() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("broken.py")
        try "import requests\nif 0 <= row < 9 and  <= col < 9:\n    pass\n"
            .write(to: script, atomically: true, encoding: .utf8)

        let runner = CodeRunner(pythonEnvironment: directory.appendingPathComponent("venv"))
        runner.present(blocks: [ExtractedCodeBlock(index: 0, language: "python", code: "")])
        let plan = try await runner.prepare(script)
        #expect(plan.syntaxError?.hasPrefix("line 2: ") == true)
        #expect(plan.packages.isEmpty)
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].arguments == [script.path])
    }

    @Test func packageNamesThatPipWouldMisreadAreRefused() {
        #expect(PythonImportScan.isSafePackageName("python-dateutil"))
        #expect(PythonImportScan.isSafePackageName("discord.py"))
        #expect(!PythonImportScan.isSafePackageName("--index-url"))
        #expect(!PythonImportScan.isSafePackageName("../evil"))
        #expect(!PythonImportScan.isSafePackageName("https://x/y.whl"))
    }
}
