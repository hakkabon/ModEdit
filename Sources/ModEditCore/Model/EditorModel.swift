import Combine
import Foundation
import PL0Language
import IncrementalParsing
import LanguageTooling

/// Main-actor view model for one editor window.
///
/// Publishes a cheap revision counter instead of a complete `String` on every
/// keystroke. Preview and saving request a snapshot only after their debounce
/// or when the document is written.
@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var textRevision: UInt64
    @Published private(set) var format: any DocumentFormat
    @Published private(set) var cursorLine = 1
    @Published private(set) var cursorColumn = 1
    @Published private(set) var isDocumentDirty: Bool
    @Published private(set) var lineCount: Int
    /// Revision-bound PL/0 problems and recovery markers drawn over the editor.
    @Published private(set) var pl0Visualization: PL0EditorVisualization?
    /// Monotonic request used to reveal workbench items in the source editor.
    @Published private(set) var revealRequest: EditorRevealRequest?
    @Published private(set) var sourceReplacementRequest: EditorSourceReplacementRequest?
    /// Whether the live-preview pane is shown. Owned here rather than in the
    /// view so the window's toolbar can toggle it.
    @Published var showPreview = true
    /// Whether the experimental parser inspector is visible for PL/0.
    @Published var showWorkbench = false
    @Published var showProblems = false
    @Published private(set) var buildResult: EditorBuildResult?
    @Published private(set) var isBuilding = false
    private var buildID: UUID?
    private var isFormattingDocument = false
    @Published private(set) var languageAnalysis: LanguageProviderAnalysis?
    private var toolingDocument: LanguageToolingDocument?
    private let toolingURI = "modedit://current-document"
    @Published private(set) var selection = NSRange(location: 0, length: 0)
    /// The last replacement, used by incremental language services. It is not
    /// published separately because every edit also publishes `textRevision`.
    private(set) var lastSourceEdit: PL0Language.SourceEdit?
    private var nextRevealID: UInt64 = 0
    private var nextReplacementID: UInt64 = 0

    let tabSize = 4
    /// The format catalogue shown in the status-bar picker.
    let registry: FormatRegistry

    /// Called after an edit has been applied to the buffer. The `NSDocument`
    /// shell uses this to record a change for autosave and the window's edited
    /// indicator.
    var onTextChange: (() -> Void)?
    /// Called when the user picks a different format.
    var onFormatChange: ((any DocumentFormat) -> Void)?

    private let document: EditorDocument

    init(document: EditorDocument, registry: FormatRegistry? = nil) {
        self.document = document
        self.registry = registry ?? document.registry
        self.textRevision = document.textGeneration
        self.format = document.currentFormat
        self.isDocumentDirty = document.isDirty
        self.lineCount = document.numberOfLines
        self.lastSourceEdit = nil
        self.pl0Visualization = nil
        self.revealRequest = nil
        self.sourceReplacementRequest = nil
        document.setSaveObserver { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDocumentState()
            }
        }
        document.setExternalChangeObserver { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAfterExternalChange()
            }
        }
    }

    deinit {
        document.setSaveObserver(nil)
        document.setExternalChangeObserver(nil)
    }

    func textSnapshot() -> String { document.text }

    /// Snapshot for the live preview. Large documents return `nil` instead of
    /// being copied and rendered on every debounce.
    func previewSnapshot(upTo limit: Int) -> String? {
        document.textSnapshot(upTo: limit)
    }

    var documentTextGeneration: UInt64 { document.textGeneration }

    /// Applies one TextKit edit using UTF-16 offsets. `editedRange` is the
    /// post-edit range and `delta` is the change in storage length.
    @discardableResult
    func applyTextEdit(editedRange: NSRange, delta: Int, replacement: String) -> UInt64 {
        let oldLength = editedRange.length - delta
        let oldRange = NSRange(location: editedRange.location, length: oldLength)
        let baseVersion = document.textGeneration
        let generation = document.replaceText(in: oldRange, with: replacement)
        lastSourceEdit = PL0Language.SourceEdit(
            baseVersion: baseVersion,
            replacedRange: SourceRange(location: oldRange.location, length: oldRange.length),
            replacementLength: (replacement as NSString).length)
        pl0Visualization = nil
        languageAnalysis = nil
        clearBuild()
        textRevision = generation
        lineCount = document.numberOfLines
        isDocumentDirty = document.isDirty
        onTextChange?()
        return generation
    }

    func updateCursor(line: Int, column: Int, selection: NSRange) {
        if self.selection != selection { self.selection = selection }
        let line = max(1, line)
        let column = max(1, column)
        if cursorLine != line { cursorLine = line }
        if cursorColumn != column { cursorColumn = column }
    }

    /// Shared line lookup used by the status bar and the gutter.
    func lineAndColumn(at location: Int) -> (line: Int, column: Int) {
        document.lineAndColumn(at: location)
    }

    /// Refreshes UI state after a document replacement that did not originate
    /// in the text view (for example Revert to Saved).
    func refreshAfterExternalChange() {
        lastSourceEdit = nil
        pl0Visualization = nil
        languageAnalysis = nil
        clearBuild()
        toolingDocument = nil
        format = document.currentFormat
        textRevision = document.textGeneration
        lineCount = document.numberOfLines
        isDocumentDirty = document.isDirty
    }

    private func refreshDocumentState() {
        isDocumentDirty = document.isDirty
    }

    /// Switches the document's format (highlighting and preview).
    func setFormat(_ newFormat: any DocumentFormat) {
        format = newFormat
        pl0Visualization = nil
        languageAnalysis = nil
        clearBuild()
        toolingDocument = nil
        document.setFormat(newFormat)
        onFormatChange?(newFormat)
    }

    /// Opens the PL/0 workbench from any document. The toolbar item is a
    /// launcher as well as a visibility toggle, so it must never become a
    /// disabled dead end while another format is selected.
    func activatePL0Workbench() {
        if format.id != "pl0", let pl0 = registry.format(withID: "pl0") {
            setFormat(pl0)
        }
        showWorkbench = true
    }

    /// Accepts only current PL/0 results. This is the final stale-result guard
    /// between the detached parser and TextKit presentation.
    func publishPL0Visualization(_ result: ParseResult) {
        guard format.id == "pl0", result.version == textRevision else { return }
        pl0Visualization = PL0EditorVisualization(result: result)
    }

    var supportsLanguageQueries: Bool {
        registry.provider(withID: format.id)?.descriptor.capabilities.contains(.semantics) == true
    }

    var supportsProblems: Bool {
        registry.provider(withID: format.id)?.descriptor.capabilities.contains(.diagnostics) == true
    }

    var canFormatDocument: Bool {
        !isFormattingDocument
            && registry.provider(withID: format.id)?.descriptor.capabilities.contains(.formatting) == true
    }

    func formatDocument() async throws {
        guard canFormatDocument, let provider = registry.provider(withID: format.id) else { return }
        let snapshot = IncrementalParsing.SourceSnapshot(
            text: textSnapshot(), revision: .init(documentTextGeneration))
        isFormattingDocument = true
        defer { isFormattingDocument = false }
        let result: Result<String, any Error>
        do {
            result = .success(try await provider.makeToolingSession().format(snapshot))
        } catch {
            result = .failure(error)
        }
        guard format.id == provider.descriptor.id,
              snapshot.revision.rawValue == textRevision,
              snapshot.revision.rawValue == documentTextGeneration else { return }
        requestSourceReplacement(try result.get())
    }

    var problemCount: Int {
        (languageAnalysis?.diagnostics.count ?? 0) + (buildResult?.diagnostics.count ?? 0)
    }

    func buildPL0() async {
        guard format.id == "pl0", !isBuilding else { return }
        let id = UUID()
        let snapshot = PL0Language.SourceSnapshot(version: textRevision, text: textSnapshot())
        buildID = id
        buildResult = nil
        isBuilding = true
        let result = await Task.detached(priority: .userInitiated) {
            EditorBuildResult.compile(snapshot)
        }.value
        guard buildID == id else { return }
        isBuilding = false
        buildID = nil
        guard snapshot.version == documentTextGeneration else { return }
        buildResult = result
    }

    private func clearBuild() {
        buildID = nil
        buildResult = nil
        isBuilding = false
    }

    func refreshLanguageDiagnostics() async {
        guard let provider = registry.provider(withID: format.id),
              provider.descriptor.capabilities.contains(.diagnostics) else { return }
        let snapshot = IncrementalParsing.SourceSnapshot(
            text: textSnapshot(), revision: .init(textRevision))
        let session = toolingDocument ?? LanguageToolingDocument(
            provider: provider, documentURI: toolingURI)
        toolingDocument = session
        while isCurrent(session, revision: snapshot.revision.rawValue), !Task.isCancelled {
            do {
                let result: LanguageProviderAnalysis
                let previous = await session.snapshot
                if previous == snapshot, let cached = await session.analysis {
                    result = cached
                } else {
                    result = try await session.update(
                        snapshot, change: exactChange(from: previous, to: snapshot))
                }
                guard isCurrent(session, revision: result.revision.rawValue),
                      !Task.isCancelled else { return }
                languageAnalysis = result
                pl0Visualization = PL0EditorVisualization(analysis: result)
                return
            } catch LanguageToolingError.documentUpdateInProgress {
                do { try await Task.sleep(for: .milliseconds(15)) } catch { return }
            } catch {
                return
            }
        }
    }

    private func exactChange(
        from previous: IncrementalParsing.SourceSnapshot?,
        to snapshot: IncrementalParsing.SourceSnapshot
    ) -> SourceChange? {
        guard let previous, let edit = lastSourceEdit,
              edit.baseVersion == previous.revision.rawValue,
              snapshot.revision.rawValue == previous.revision.rawValue + 1 else { return nil }
        let newRange = NSRange(location: edit.replacedRange.location, length: edit.replacementLength)
        guard let range = Range(newRange, in: snapshot.text) else { return nil }
        let change = try? IncrementalParsing.SourceEdit(
            baseRevision: previous.revision, range: edit.replacedRange,
            replacement: String(snapshot.text[range])).applying(to: previous)
        return change?.after == snapshot ? change : nil
    }

    private func isCurrent(_ session: LanguageToolingDocument, revision: UInt64) -> Bool {
        toolingDocument === session && textRevision == revision && documentTextGeneration == revision
    }

    func goToDefinition() async -> Bool {
        let revision = textRevision
        let selected = selection
        await refreshLanguageDiagnostics()
        guard let session = toolingDocument, isCurrent(session, revision: revision),
              selection == selected else { return false }
        let map = SourceLineMap(textSnapshot())
        guard let location = try? await session.definition(at: map.position(of: selected.location)),
              location.uri == toolingURI, let range = map.sourceRange(location.range),
              isCurrent(session, revision: revision), selection == selected else { return false }
        revealSourceRange(range)
        return true
    }

    func completionSuggestions() async -> [EditorCompletionSuggestion] {
        let revision = textRevision
        let selected = selection
        let source = textSnapshot() as NSString
        guard selected.location <= source.length else { return [] }
        let prefixRange = selected.length == 0
            ? (source.substring(to: selected.location) as NSString).range(
                of: "[a-zA-Z_][a-zA-Z_0-9]*$", options: .regularExpression)
            : selected
        let replacementRange = prefixRange.location == NSNotFound ? selected : prefixRange
        let prefix = selected.length == 0 ? source.substring(with: replacementRange) : ""
        await refreshLanguageDiagnostics()
        guard let session = toolingDocument, isCurrent(session, revision: revision),
              selection == selected else { return [] }
        let position = SourceLineMap(source as String).position(of: selected.location)
        guard let items = try? await session.completions(at: position),
              isCurrent(session, revision: revision), selection == selected else { return [] }
        return items.filter { $0.label.lowercased().hasPrefix(prefix.lowercased()) }
            .map { .init(item: $0, revision: revision, selection: selected,
                         range: replacementRange) }
    }

    func acceptCompletion(_ suggestion: EditorCompletionSuggestion) {
        guard selection == suggestion.selection else { return }
        requestLanguageEdit(suggestion.item.insertText, range: suggestion.range,
                            revision: suggestion.revision)
    }

    func suggestedReplacement(for action: LanguageProviderRecoveryAction) -> String? {
        switch action {
        case .insert(let terminal, _):
            if format.id == "pl0", let spelling = [
                "'period'": ".", "'semicolon'": ";", "'comma'": ",",
                "'rightParen'": ")", "'assign'": ":=",
            ][terminal] { return spelling }
            let literal = terminal.hasPrefix("'") && terminal.hasSuffix("'")
                ? String(terminal.dropFirst().dropLast()) : terminal
            // Provider terminal names can describe categories, such as identifier.
            return [".", ";", ",", ":", ")", "]", "}", ":="].contains(literal) ? literal : nil
        case .delete: return ""
        case .replace(_, _, let replacement): return replacement
        case .skip: return nil
        }
    }

    func applySuggestedFix(_ fix: LanguageProviderRecoveryEdit, revision: UInt64) {
        guard let analysis = languageAnalysis, analysis.revision.rawValue == revision,
              analysis.recoveryEdits.contains(fix),
              fix.diagnosticID != nil,
              let replacement = suggestedReplacement(for: fix.action) else { return }
        let range = fix.action.range
        requestLanguageEdit(replacement, range: NSRange(location: range.location, length: range.length),
                            revision: revision)
    }

    private func requestLanguageEdit(_ text: String, range: NSRange, revision: UInt64) {
        guard revision == textRevision, revision == documentTextGeneration,
              Range(range, in: textSnapshot()) != nil else { return }
        nextReplacementID &+= 1
        sourceReplacementRequest = EditorSourceReplacementRequest(
            id: nextReplacementID, text: text,
            range: .init(location: range.location, length: range.length), revision: revision)
    }

    func revealSourceRange(_ range: SourceRange) {
        nextRevealID &+= 1
        revealRequest = EditorRevealRequest(id: nextRevealID, range: range)
    }

    func acknowledgeRevealRequest(id: UInt64) {
        if revealRequest?.id == id { revealRequest = nil }
    }

    func requestSourceReplacement(_ text: String) {
        guard text != textSnapshot() else { return }
        nextReplacementID &+= 1
        sourceReplacementRequest = EditorSourceReplacementRequest(
            id: nextReplacementID, text: text, range: nil, revision: textRevision)
    }

    func acknowledgeSourceReplacement(id: UInt64) {
        if sourceReplacementRequest?.id == id { sourceReplacementRequest = nil }
    }
}

struct EditorCompletionSuggestion: Identifiable {
    let item: ToolingCompletionItem
    let revision: UInt64
    let selection: NSRange
    let range: NSRange
    var id: String { item.id }
}

extension EditorModel: LineNumberSource {
    func lineNumber(at location: Int) -> Int {
        document.lineAndColumn(at: location).line
    }

    func isLineStart(at location: Int) -> Bool {
        document.isLineStart(at: location)
    }
}
