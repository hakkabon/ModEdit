import AppKit
import Foundation
import PDFKit
import Testing
@testable import ModEditCore

@Suite("Preview export formats")
struct PreviewExportFormatTests {

    @Test func defaultNamesReplaceTheDocumentExtension() {
        #expect(PreviewExportFormat.html.defaultFileName(forDocumentNamed: "notes.md")
                == "notes.html")
        #expect(PreviewExportFormat.pdf.defaultFileName(forDocumentNamed: "notes.md")
                == "notes.pdf")
        #expect(PreviewExportFormat.html.defaultFileName(forDocumentNamed: "notes")
                == "notes.html")
        #expect(PreviewExportFormat.pdf.defaultFileName(forDocumentNamed: "")
                == "Untitled.pdf")
        #expect(PreviewExportFormat.html.defaultFileName(forDocumentNamed: "notes.html")
                == "notes-export.html")
        #expect(PreviewExportFormat.pdf.defaultFileName(forDocumentNamed: "notes.pdf")
                == "notes-export.pdf")
    }

    @Test func formatsMapToTheirUniformTypes() {
        #expect(PreviewExportFormat.html.contentType == .html)
        #expect(PreviewExportFormat.pdf.contentType == .pdf)
        #expect(PreviewExportFormat.html.fileExtension == "html")
        #expect(PreviewExportFormat.pdf.fileExtension == "pdf")
    }
}

@Suite("Preview export", .serialized)
@MainActor
struct PreviewExportTests {

    @Test func htmlExportWritesTheSameRenderedPreview() async throws {
        let request = PreviewExportRequest(
            source: "# Title\n\nHello **export**",
            baseURL: nil,
            renderer: MarkdownPreviewRenderer())
        let url = temporaryURL(extension: "html")
        defer { try? FileManager.default.removeItem(at: url) }

        try await PreviewExport.write(request, as: .html, to: url)

        let html = try String(contentsOf: url, encoding: .utf8)
        #expect(html.contains("<h1 data-source-line=\"1\">Title</h1>"))
        #expect(html.contains("<strong>export</strong>"))
        #expect(html.contains(PreviewPage.contentSecurityPolicy))
    }

    @Test func htmlExportResolvesLocalImagesThroughTheDocumentDirectory() async throws {
        let baseURL = URL(fileURLWithPath: "/tmp/docs", isDirectory: true)
        let request = PreviewExportRequest(
            source: "![alt](pic.png)",
            baseURL: baseURL,
            renderer: MarkdownPreviewRenderer())
        let url = temporaryURL(extension: "html")
        defer { try? FileManager.default.removeItem(at: url) }

        try await PreviewExport.write(request, as: .html, to: url)

        let html = try String(contentsOf: url, encoding: .utf8)
        #expect(html.contains("<img src=\"pic.png\" alt=\"alt\">"))
    }

    @Test func userHTMLKeepsTheInjectedSecurityPolicy() async throws {
        let source = """
            <!DOCTYPE html><html><head><title>T</title></head>
            <body><script>alert(1)</script><p>visible</p></body></html>
            """
        let request = PreviewExportRequest(source: source,
                                           baseURL: nil,
                                           renderer: HTMLPreviewRenderer())
        let url = temporaryURL(extension: "html")
        defer { try? FileManager.default.removeItem(at: url) }

        try await PreviewExport.write(request, as: .html, to: url)

        let html = try String(contentsOf: url, encoding: .utf8)
        #expect(html.contains("script-src 'none'"))
        #expect(html.contains("frame-src 'none'"))
        #expect(html.contains("<p>visible</p>"))
    }

    @Test func pdfExportRendersOnceAndWritesTheExporterData() async throws {
        let spy = PDFExporterSpy(data: Data("%PDF-1.7\nspy".utf8))
        let request = PreviewExportRequest(source: "# PDF",
                                           baseURL: nil,
                                           renderer: MarkdownPreviewRenderer())
        let url = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try await PreviewExport.write(request, as: .pdf, to: url,
                                      pdfExporter: spy)

        #expect(spy.html?.contains("<h1 data-source-line=\"1\">PDF</h1>") == true)
        #expect(try Data(contentsOf: url) == spy.data)
    }

    @Test func pdfExportRejectsEmptyPDFData() async throws {
        let spy = PDFExporterSpy(data: Data())
        let request = PreviewExportRequest(source: "text",
                                           baseURL: nil,
                                           renderer: MarkdownPreviewRenderer())
        let url = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: PreviewExportError.self) {
            try await PreviewExport.write(request, as: .pdf, to: url,
                                          pdfExporter: spy)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func webKitProducesAReadablePDFFromThePreviewPage() async throws {
        let request = PreviewExportRequest(
            source: "# Export heading\n\nHello PDF",
            baseURL: nil,
            renderer: MarkdownPreviewRenderer())
        let html = try await PreviewExport.html(for: request)

        let data = try await PreviewPDFExporter().pdfData(from: html,
                                                          baseURL: nil)

        #expect(data.starts(with: Data("%PDF".utf8)))
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount >= 1)
        let text = pdf.page(at: 0)?.string ?? ""
        #expect(text.contains("Export heading"))
    }

    @Test func previewAndExportWebViewsDisableScriptsAndPersistentStorage() {
        let configuration = PreviewWebViewConfiguration.make()

        #expect(!configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(!configuration.websiteDataStore.isPersistent)
    }

    @Test func formatsWithWebPreviewsCanExport() {
        for format in [MarkdownFormat(), LaTeXFormat(), HTMLFormat()] as [any DocumentFormat] {
            let document = EditorDocument()
            document.setFormat(format)
            let model = EditorModel(document: document)

            #expect(model.canExportPreview, "\(format.id) should be exportable")
        }
    }

    @Test func formatsWithoutWebPreviewsCannotExport() {
        for format in [PlainTextFormat(), PL0Format()] as [any DocumentFormat] {
            let document = EditorDocument()
            document.setFormat(format)
            let model = EditorModel(document: document)

            #expect(!model.canExportPreview, "\(format.id) should not be exportable")
        }
    }

    @Test func oversizedDocumentsCannotExport() {
        let document = EditorDocument()
        document.setText(String(repeating: "a",
                                count: PreviewLimits.maximumSourceLength + 1))
        let model = EditorModel(document: document)

        #expect(!model.canExportPreview)
    }

    private func temporaryURL(extension fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ModEditExport-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
    }
}

@MainActor
private final class PDFExporterSpy: PreviewPDFExporting {
    let data: Data
    private(set) var html: String?
    private(set) var baseURL: URL?

    init(data: Data) {
        self.data = data
    }

    func pdfData(from html: String, baseURL: URL?) async throws -> Data {
        self.html = html
        self.baseURL = baseURL
        return data
    }
}
