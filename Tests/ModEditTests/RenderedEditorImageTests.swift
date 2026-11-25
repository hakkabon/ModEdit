import Testing
import AppKit
@testable import ModEditCore

@Suite("Rendered editor images", .serialized)
@MainActor
struct RenderedEditorImageTests {

    @Test func relativeDestinationsResolveAgainstTheDocumentDirectory() throws {
        let base = URL(fileURLWithPath: "/tmp/modedit-doc")
        #expect(RenderedEditorImageCache.resolvedURL(
            for: "images/pic.png", baseURL: base)?.path
            == "/tmp/modedit-doc/images/pic.png")
        #expect(RenderedEditorImageCache.resolvedURL(
            for: "my%20pic.png", baseURL: base)?.lastPathComponent == "my pic.png")
        #expect(RenderedEditorImageCache.resolvedURL(
            for: "/absolute/pic.png", baseURL: base)?.path == "/absolute/pic.png")
        #expect(RenderedEditorImageCache.resolvedURL(
            for: "file:///tmp/pic.png", baseURL: nil)?.path == "/tmp/pic.png")
    }

    @Test func relativeDestinationsNeedADocumentDirectory() {
        #expect(RenderedEditorImageCache.resolvedURL(
            for: "pic.png", baseURL: nil) == nil)
    }

    @Test func remoteAndDataDestinationsAreNotFilePaths() {
        #expect(RenderedEditorImageCache.resolvedURL(
            for: "https://example.com/pic.png", baseURL: nil) == nil)
        #expect(RenderedEditorImageCache.resolvedURL(
            for: "data:image/png;base64,AAAA", baseURL: nil) == nil)
    }

    @Test func localImagesLoadFromDisk() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePNG(width: 12, height: 8, to: directory.appendingPathComponent("pic.png"))
        let cache = RenderedEditorImageCache()
        cache.setBaseURL(directory)

        let image = try #require(cache.image(for: "pic.png"))
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
        // A second lookup is served from the cache and still works.
        #expect(cache.image(for: "pic.png") != nil)
    }

    @Test func missingFilesAndRemoteURLsStayUnresolved() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = RenderedEditorImageCache()
        cache.setBaseURL(directory)

        #expect(cache.image(for: "missing.png") == nil)
        #expect(cache.image(for: "https://example.com/pic.png") == nil)
    }

    @Test func base64DataImagesLoad() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pic.png")
        try writePNG(width: 4, height: 3, to: url)
        let data = try Data(contentsOf: url)
        let cache = RenderedEditorImageCache()

        #expect(cache.image(for: "data:image/png;base64,\(data.base64EncodedString())") != nil)
        #expect(cache.image(for: "data:text/plain;base64,\(data.base64EncodedString())") == nil)
    }

    @Test func onlyStandaloneReferencesAreLoaded() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePNG(width: 4, height: 3, to: directory.appendingPathComponent("pic.png"))
        let cache = RenderedEditorImageCache()
        cache.setBaseURL(directory)

        let loaded = cache.loadImages(for: [
            RenderedEditorImage(sourceRange: 0..<14, destination: "pic.png",
                                altText: "a", isStandalone: false),
            RenderedEditorImage(sourceRange: 20..<34, destination: "pic.png",
                                altText: "b", isStandalone: true),
        ])

        #expect(loaded.count == 1)
        #expect(loaded.first?.sourceRange == 20..<34)
    }

    @Test func standaloneImageBecomesAHeightReservingAttachment() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePNG(width: 40, height: 20, to: directory.appendingPathComponent("pic.png"))
        let source = "before\n\n![pic](pic.png)\n\nafter\n"
        let harness = makeHarness(text: source, caret: source.utf16.count,
                                  baseURL: directory)
        let text = source as NSString
        let syntax = text.range(of: "![pic](pic.png)")
        let line = text.lineRange(for: NSRange(location: syntax.location, length: 0))

        let attachments = harness.coordinator.renderedImageAttachmentsForTesting
        #expect(attachments.count == 1)
        let attachment = try #require(attachments.first)
        #expect(attachment.sourceRange == syntax.location..<NSMaxRange(syntax))
        #expect(attachment.lineRange == line.location..<NSMaxRange(line))
        #expect(attachment.displaySize.width > 0)
        #expect(attachment.displaySize.height > 0)
        #expect(harness.coordinator.renderedImageLinesForTesting
            == [line.location..<NSMaxRange(line)])

        // The source stays in storage; only its presentation is hidden.
        #expect(harness.textView.string == source)
        #expect(harness.document.content.text == source)
        let storage = try #require(harness.textView.textStorage)
        let color = storage.attribute(.foregroundColor, at: syntax.location,
                                      effectiveRange: nil) as? NSColor
        #expect(color?.alphaComponent == 0)
        let paragraph = storage.attribute(.paragraphStyle, at: syntax.location,
                                          effectiveRange: nil) as? NSParagraphStyle
        #expect(paragraph?.minimumLineHeight
            == EditorNSTextView.reservedImageHeight(for: attachment.displaySize))
    }

    @Test func caretLineRevealsTheImageSourceAndDropsTheAttachment() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePNG(width: 40, height: 20, to: directory.appendingPathComponent("pic.png"))
        let source = "before\n\n![pic](pic.png)\n\nafter\n"
        let harness = makeHarness(text: source, caret: source.utf16.count,
                                  baseURL: directory)
        #expect(harness.coordinator.renderedImageAttachmentsForTesting.count == 1)

        let syntax = (source as NSString).range(of: "![pic](pic.png)")
        harness.textView.setSelectedRange(NSRange(location: syntax.location, length: 0))
        harness.coordinator.applyRenderedProjection(full: false)

        #expect(harness.coordinator.renderedImageAttachmentsForTesting.isEmpty)
        #expect(harness.coordinator.renderedImageLinesForTesting.isEmpty)
        let storage = try #require(harness.textView.textStorage)
        let color = storage.attribute(.foregroundColor, at: syntax.location,
                                      effectiveRange: nil) as? NSColor
        #expect(color?.alphaComponent ?? 0 > 0)
        #expect(harness.textView.string == source)
    }

    @Test func inlineAndRemoteImagesKeepTheirSourceForm() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePNG(width: 40, height: 20, to: directory.appendingPathComponent("pic.png"))
        let source = "before ![pic](pic.png) after\n\n![remote](https://example.com/pic.png)\n"
        let harness = makeHarness(text: source, caret: 0, baseURL: directory)

        #expect(harness.coordinator.renderedImageAttachmentsForTesting.isEmpty)
        #expect(harness.textView.string == source)
    }

    @Test func leavingRenderedModeRemovesAttachmentsAndReservations() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePNG(width: 40, height: 20, to: directory.appendingPathComponent("pic.png"))
        let source = "before\n\n![pic](pic.png)\n\nafter\n"
        let harness = makeHarness(text: source, caret: source.utf16.count,
                                  baseURL: directory)
        let syntax = (source as NSString).range(of: "![pic](pic.png)")
        #expect(harness.coordinator.renderedImageAttachmentsForTesting.count == 1)

        harness.model.showsRenderedEditing = false
        harness.coordinator.modelDidChange()
        harness.coordinator.applySourceHighlightingNow()

        #expect(harness.coordinator.renderedImageAttachmentsForTesting.isEmpty)
        #expect(harness.coordinator.renderedImageLinesForTesting.isEmpty)
        let storage = try #require(harness.textView.textStorage)
        let paragraph = storage.attribute(.paragraphStyle, at: syntax.location,
                                          effectiveRange: nil) as? NSParagraphStyle
        #expect((paragraph?.minimumLineHeight ?? 0) < 20)
        #expect(harness.textView.string == source)
    }

    @Test func imageDisplaySizeKeepsAspectRatioAndCapsTheHeight() {
        let size = EditorNSTextView.displaySize(
            for: NSSize(width: 100, height: 50), availableWidth: 400)
        #expect(size == NSSize(width: 100, height: 50))

        let capped = EditorNSTextView.displaySize(
            for: NSSize(width: 1_000, height: 800), availableWidth: 200)
        #expect(capped.width == 200)
        #expect(abs(capped.height - 160) < 0.001)

        let tall = EditorNSTextView.displaySize(
            for: NSSize(width: 100, height: 4_000), availableWidth: 400)
        #expect(tall.height == EditorNSTextView.maximumImageHeight)
        #expect(abs(tall.width - 8) < 0.001)
    }

    // MARK: Helpers

    private func makeHarness(text: String, caret: Int? = nil,
                             baseURL: URL? = nil) -> Harness {
        let document = EditorDocument()
        document.setText(text)
        let model = EditorModel(document: document)
        model.setFormat(MarkdownFormat())
        model.resourceBaseURL = baseURL
        let coordinator = EditorTextView.Coordinator(model: model)
        let textView = EditorNSTextView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        textView.allowsUndo = true
        textView.string = model.textSnapshot()
        coordinator.attach(to: textView)
        model.showsRenderedEditing = true
        coordinator.modelDidChange()
        if let caret {
            textView.setSelectedRange(NSRange(location: caret, length: 0))
        }
        coordinator.applyRenderedProjection(full: true)
        return Harness(document: document, model: model,
                       coordinator: coordinator, textView: textView)
    }

    private struct Harness {
        let document: EditorDocument
        let model: EditorModel
        let coordinator: EditorTextView.Coordinator
        let textView: EditorNSTextView
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModEditImageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()

        let representation = try #require(NSBitmapImageRep(data: image.tiffRepresentation!))
        let png = try #require(representation.representation(
            using: .png, properties: [:]))
        try png.write(to: url)
    }
}
