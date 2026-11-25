import AppKit

/// Resolves Markdown image destinations and caches decoded editor images.
///
/// Only local files and `data:image` payloads are loaded. Remote URLs are
/// deliberately rejected: opening a document must not silently contact a
/// network host, and the preview's CSP does not allow remote images either.
/// A missing or unreadable file simply leaves the alt text visible.
@MainActor
final class RenderedEditorImageCache {
    struct LoadedImage {
        let sourceRange: Range<Int>
        let destination: String
        let altText: String
        let image: NSImage
    }

    /// Refuse enormous reference images before handing them to AppKit.
    static let maximumFileSize = 32 * 1_024 * 1_024

    private var images: [String: NSImage?] = [:]
    private var baseURL: URL?

    /// The document directory used to resolve relative destinations. Changing
    /// it (Save As) drops every cached path because the same relative path can
    /// now point at a different file.
    func setBaseURL(_ url: URL?) {
        guard baseURL != url else { return }
        baseURL = url
        images.removeAll()
    }

    /// Loads every distinct standalone image. Inline images keep their alt text
    /// for now, so their files are not read at all.
    func loadImages(for references: [RenderedEditorImage]) -> [LoadedImage] {
        var loaded: [LoadedImage] = []
        for reference in references where reference.isStandalone {
            guard let image = image(for: reference.destination) else { continue }
            loaded.append(LoadedImage(
                sourceRange: reference.sourceRange,
                destination: reference.destination,
                altText: reference.altText,
                image: image))
        }
        return loaded
    }

    func image(for destination: String) -> NSImage? {
        if let cached = images[destination] { return cached }

        let image: NSImage?
        if destination.hasPrefix("data:") {
            image = Self.imageFromDataURI(destination)
        } else if let url = Self.resolvedURL(for: destination, baseURL: baseURL) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true,
               let size = values?.fileSize,
               size <= Self.maximumFileSize {
                image = NSImage(contentsOf: url)
            } else {
                image = nil
            }
        } else {
            image = nil
        }
        images[destination] = image
        return image
    }

    /// Resolves a Markdown destination against the document directory.
    ///
    /// File URLs and absolute paths are accepted as written; scheme-bearing
    /// URLs (http, https, ftp, ...) are rejected. Percent escapes are decoded
    /// so `my%20picture.png` finds the file with a space.
    static func resolvedURL(for destination: String, baseURL: URL?) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("data:") else { return nil }

        let decoded = trimmed.removingPercentEncoding ?? trimmed
        if let url = URL(string: decoded), url.scheme != nil {
            return url.isFileURL ? url.standardizedFileURL : nil
        }
        if decoded.hasPrefix("/") {
            return URL(fileURLWithPath: decoded).standardizedFileURL
        }
        guard let baseURL else { return nil }
        // A document directory URL usually arrives without a trailing slash;
        // `URL(fileURLWithPath:relativeTo:)` would otherwise replace its last
        // component instead of appending to it.
        let directory = baseURL.hasDirectoryPath
            ? baseURL
            : URL(fileURLWithPath: baseURL.path, isDirectory: true)
        return URL(fileURLWithPath: decoded, relativeTo: directory)
            .standardizedFileURL
    }

    private static func imageFromDataURI(_ uri: String) -> NSImage? {
        guard uri.hasPrefix("data:image/"),
              let comma = uri.firstIndex(of: ",") else { return nil }
        let metadata = uri[uri.startIndex..<comma]
        guard metadata.contains(";base64") else { return nil }
        let payload = String(uri[uri.index(after: comma)...])
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              data.count <= maximumFileSize else { return nil }
        return NSImage(data: data)
    }
}
