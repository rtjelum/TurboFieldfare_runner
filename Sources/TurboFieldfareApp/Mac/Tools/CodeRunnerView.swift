import AppKit
import SwiftUI
import TurboFieldfareMacPresentation

/// The Code Runner window: pick a listing from an answer, edit it, save it,
/// and run it. A run always asks first; the model never starts one.
struct CodeRunnerView: View {
    @Bindable var runner: CodeRunner
    @StoredState private var pendingRun: CodeRunner.RunPlan?
    @StoredState private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(12)
            Divider()
            VSplitView {
                editor
                    .frame(minHeight: 160)
                outputPane
                    .frame(minHeight: 120)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        // A closed window has no Stop button, so nothing may outlive it.
        .onDisappear(perform: runner.stop)
        .confirmationDialog(
            "Run this code?",
            isPresented: Binding(get: { pendingRun != nil },
                                 set: { if !$0 { pendingRun = nil } }),
            titleVisibility: .visible
        ) {
            Button(pendingRun.map { $0.packages.isEmpty && $0.requirements == nil } ?? true
                   ? "Run" : "Install and Run") {
                if let plan = pendingRun { runner.run(plan) }
                pendingRun = nil
            }
            .accessibilityIdentifier(.runnerConfirmRun)
            Button("Cancel", role: .cancel) { pendingRun = nil }
        } message: {
            if let plan = pendingRun {
                Text(confirmationMessage(plan))
            }
        }
        .alert("Code Runner", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            if runner.blocks.count > 1 {
                Picker("Block", selection: $runner.selectedIndex) {
                    ForEach(runner.blocks) { block in
                        Text(block.summary).tag(block.index)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                .disabled(runner.isRunning)
                .accessibilityIdentifier(.runnerBlock)
            }
            TextField("Language", text: $runner.languageTag)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .disabled(runner.isRunning)
                .help("The fence's language tag; decides the file extension and interpreter")
                .accessibilityIdentifier(.runnerLanguage)
            Text(runner.language.isRunnable
                 ? runner.language.interpreter!.joined(separator: " ")
                 : "save only")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open…", systemImage: "folder.badge.plus", action: openFile)
                .disabled(runner.isRunning)
                .keyboardShortcut("o", modifiers: .command)
                .help("Open a script from disk to edit and run it where it is")
                .accessibilityIdentifier(.runnerOpen)
            Button("Save As…", systemImage: "square.and.arrow.down", action: saveAs)
                .disabled(runner.code.isEmpty)
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityIdentifier(.runnerSave)
            if let saved = runner.savedURL {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([saved])
                }
                .labelStyle(.iconOnly)
                .help("Show \(saved.lastPathComponent) in Finder")
                if !runner.language.isRunnable {
                    Button("Open", systemImage: "arrow.up.forward.app") {
                        NSWorkspace.shared.open(saved)
                    }
                    .help("Open \(saved.lastPathComponent) in its default app")
                }
            }
            if runner.isRunning {
                Button("Stop", systemImage: "stop.fill", action: runner.stop)
                    .disabled(runner.phase == .preparing)
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityIdentifier(.runnerStop)
            } else {
                Button("Run", systemImage: "play.fill", action: requestRun)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!runner.language.isRunnable || runner.code.isEmpty)
                    .help(runner.language.isRunnable
                          ? "Run with \(runner.language.name)"
                          : "\(runner.language.name) can be saved but not run here")
                    .accessibilityIdentifier(.runnerRun)
            }
        }
    }

    // MARK: - Editor and output

    private var editor: some View {
        VStack(alignment: .leading, spacing: 4) {
            if runner.blocks.indices.contains(runner.selectedIndex),
               runner.blocks[runner.selectedIndex].isTruncated {
                Label("The answer ended inside this block; it may be incomplete.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            TextEditor(text: $runner.code)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .disabled(runner.isRunning)
                .padding(8)
                .accessibilityIdentifier(.runnerCode)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Output").font(.headline)
                phaseLabel
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(runner.outputText, forType: .string)
                }
                .labelStyle(.iconOnly)
                .disabled(runner.output.isEmpty)
                Button("Clear", systemImage: "trash", action: runner.clearOutput)
                    .labelStyle(.iconOnly)
                    .disabled(runner.output.isEmpty || runner.isRunning)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(runner.output) { line in
                            Text(line.text.hasSuffix("\n") ? String(line.text.dropLast()) : line.text)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(color(for: line.stream))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: runner.output.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .accessibilityIdentifier(.runnerOutput)
        }
    }

    @ViewBuilder
    private var phaseLabel: some View {
        switch runner.phase {
        case .idle:
            EmptyView()
        case .preparing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("preparing").font(.caption).foregroundStyle(.secondary)
            }
        case .running:
            ProgressView().controlSize(.small)
        case .finished(let status):
            Text(status == 0 ? "exit 0" : "exit \(status)")
                .font(.caption.monospaced())
                .foregroundStyle(status == 0 ? Color.secondary : Color.red)
        case .stopped:
            Text("stopped").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Text("failed").font(.caption).foregroundStyle(.red)
        }
    }

    private func color(for stream: CodeRunner.Stream) -> Color {
        switch stream {
        case .stdout: .primary
        case .stderr: .red
        case .system: .secondary
        }
    }

    // MARK: - Actions

    private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a script to open in the Code Runner"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try runner.open(url)
        } catch {
            errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = runner.savedURL?.lastPathComponent
            ?? runner.language.suggestedFileName(index: runner.selectedIndex)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try runner.save(to: url)
        } catch {
            errorMessage = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func requestRun() {
        Task {
            do {
                pendingRun = try await runner.prepare(runner.runTarget())
            } catch {
                errorMessage = "Could not prepare the run: \(error.localizedDescription)"
            }
        }
    }

    private func confirmationMessage(_ plan: CodeRunner.RunPlan) -> String {
        var parts: [String] = []
        if let syntaxError = plan.syntaxError {
            parts.append("This script has a syntax error (\(syntaxError)), "
                + "so it will stop before doing anything and its packages cannot be "
                + "checked. Cancel to fix it in the editor.")
        }
        if !plan.packages.isEmpty || plan.requirements != nil {
            var what = plan.packages.joined(separator: ", ")
            if plan.requirements != nil {
                what = what.isEmpty ? "requirements.txt" : "requirements.txt and " + what
            }
            parts.append("First installs \(what) from PyPI into "
                + "\(plan.environment?.path ?? "the Python environment"). "
                + "Package names come from the generated code; check they are the ones you expect.")
        }
        if !plan.unavailable.isEmpty {
            parts.append("The script imports \(plan.unavailable.joined(separator: ", ")), "
                + "which pip cannot install.")
        }
        parts.append("Then runs \(plan.steps.last?.description ?? "") in "
            + "\(plan.file.deletingLastPathComponent().path) with your account's "
            + "permissions. Generated code can read, change, or delete your "
            + "files. Run it only if you have read it and trust it.")
        return parts.joined(separator: "\n\n")
    }
}
