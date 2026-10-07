import SwiftUI
import TurboFieldfareAppCore
import TurboFieldfareMacPresentation

enum CodeRunnerWindow {
    static let id = "code-runner"
}

extension AppModel {
    /// Every answer the transcript is drawing, oldest first. A stored chat
    /// being read draws only its own pairs; the live fields belong to another
    /// conversation then, which is why `outputResponsePlainText` alone found
    /// nothing in a reopened chat.
    var displayedAnswers: [String] {
        var answers = transcriptHistory.map(\.assistant.text)
        if showsLiveTurn { answers.append(outputResponsePlainText) }
        return answers
    }

    var displayedCodeBlocks: (blocks: [ExtractedCodeBlock], newest: Int) {
        CodeBlockExtractor.blocks(inAnswers: displayedAnswers)
    }
}

/// Tools ▸ Code Runner: opens the runner on the listings of the chat on
/// screen, or on what it already holds when that chat has none.
struct CodeRunnerMenuButton: View {
    let model: AppModel
    let runner: CodeRunner
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Code Runner") {
            let found = model.displayedCodeBlocks
            if !found.blocks.isEmpty { runner.present(blocks: found.blocks, selecting: found.newest) }
            openWindow(id: CodeRunnerWindow.id)
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
    }
}
