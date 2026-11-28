import Foundation
import UniformTypeIdentifiers

/// File formats supported by preview export.
enum PreviewExportFormat: String, CaseIterable, Sendable {
    case html
    case pdf

    var displayName: String {
        switch self {
        case .html: return "HTML"
        case .pdf: return "PDF"
        }
    }

    var fileExtension: String { rawValue }

    var contentType: UTType {
        switch self {
        case .html: return .html
        case .pdf: return .pdf
        }
    }

    /// The document name without its extension plus the export extension.
    /// Untitled and extension-only names fall back to `Untitled`.
    ///
    /// When the source file already has the export extension (for example an
    /// HTML document exported as HTML), `-export` is appended so pressing Save
    /// cannot overwrite the open document by default.
    func defaultFileName(forDocumentNamed name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let stem = base.isEmpty || base == "." ? "Untitled" : base
        let sourceExtension = (name as NSString).pathExtension
        if sourceExtension.caseInsensitiveCompare(fileExtension) == .orderedSame {
            return "\(stem)-export.\(fileExtension)"
        }
        return "\(stem).\(fileExtension)"
    }
}

/// Everything needed to reproduce the current preview without touching the
/// live `WKWebView`.
struct PreviewExportRequest: Sendable {
    let source: String
    let baseURL: URL?
    let renderer: any PreviewRenderer
}

/// Renders the preview HTML and writes an HTML or PDF export.
///
/// The live preview and export share the same `PreviewRenderer`, so Markdown,
/// LaTeX and HTML exports contain exactly what the pane shows. HTML documents
/// keep the injected Content-Security-Policy and generated pages keep the same
/// escaped body. PDF rendering is delegated to a hardened offscreen web view.
@MainActor
enum PreviewExport {

    /// The complete HTML page for `request`, rendered off the main actor.
    static func html(for request: PreviewExportRequest) async throws -> String {
        try await PreviewRendering.renderHTML(from: request.source,
                                              baseURL: request.baseURL,
                                              with: request.renderer)
    }

    /// Renders and writes one export. HTML is written as UTF-8; PDF data comes
    /// from `pdfExporter`, which tests can replace.
    static func write(_ request: PreviewExportRequest,
                      as format: PreviewExportFormat,
                      to url: URL,
                      pdfExporter: any PreviewPDFExporting = PreviewPDFExporter()) async throws {
        let html = try await html(for: request)
        switch format {
        case .html:
            try html.write(to: url, atomically: true, encoding: .utf8)
        case .pdf:
            let data = try await pdfExporter.pdfData(from: html,
                                                     baseURL: request.baseURL)
            guard !data.isEmpty else { throw PreviewExportError.emptyPDF }
            try data.write(to: url, options: .atomic)
        }
    }
}

/// Turns preview HTML into PDF data.
@MainActor
protocol PreviewPDFExporting {
    func pdfData(from html: String, baseURL: URL?) async throws -> Data
}

enum PreviewExportError: LocalizedError {
    case emptyPDF
    case webContentTerminated
    case sourceTooLarge
    case noPreview

    var errorDescription: String? {
        switch self {
        case .emptyPDF:
            return "The PDF renderer returned an empty document."
        case .webContentTerminated:
            return "The preview renderer stopped before the PDF was complete."
        case .sourceTooLarge:
            return "This document is too large to export from the preview."
        case .noPreview:
            return "This format does not have an exportable preview."
        }
    }
}
