import Foundation

/// Remembers the format the user chose for a file.
///
/// Without this, reopening a file would always use the format implied by its
/// extension and silently discard an explicit choice (for example opening a
/// `.txt` note as Markdown). Preferences are keyed by the standardized file
/// path, so moving or renaming a file starts from its new extension; the new
/// path is recorded on the next save.
protocol FormatPreferenceStore: Sendable {
    func formatID(for url: URL) -> String?
    func setFormatID(_ id: String?, for url: URL)
}

/// Persists format choices in `UserDefaults`.
///
/// `UserDefaults` is thread-safe; `@unchecked Sendable` documents that the
/// store is safe to call from the save completion handler as well as the main
/// actor.
final class UserDefaultsFormatStore: FormatPreferenceStore, @unchecked Sendable {
    static let defaultKeyPrefix = "ModEdit.format."

    private let defaults: UserDefaults
    private let keyPrefix: String

    init(defaults: UserDefaults = .standard,
         keyPrefix: String = UserDefaultsFormatStore.defaultKeyPrefix) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func formatID(for url: URL) -> String? {
        defaults.string(forKey: key(for: url))
    }

    func setFormatID(_ id: String?, for url: URL) {
        let key = key(for: url)
        if let id {
            defaults.set(id, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func key(for url: URL) -> String {
        keyPrefix + normalizedKey(for: url)
    }
}

/// An in-memory store for tests and for throwaway documents.
final class InMemoryFormatPreferenceStore: FormatPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var formats: [String: String] = [:]

    func formatID(for url: URL) -> String? {
        lock.withLock { formats[normalizedKey(for: url)] }
    }

    func setFormatID(_ id: String?, for url: URL) {
        let key = normalizedKey(for: url)
        lock.withLock {
            if let id {
                formats[key] = id
            } else {
                formats.removeValue(forKey: key)
            }
        }
    }
}

private func normalizedKey(for url: URL) -> String {
    url.standardizedFileURL.path
}
