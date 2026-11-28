import AppKit
import Combine
import Foundation

/// How AppKit resolves light and dark colours for the editor and its chrome.
enum EditorAppearance: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` follows the system setting.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Monospaced font families offered to the source editor.
///
/// The names are AppKit families, not PostScript names, so the settings file
/// stays readable. A missing family falls back to the system monospaced font.
enum EditorFontFamily: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case menlo
    case monaco

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System Monospaced"
        case .menlo: return "Menlo"
        case .monaco: return "Monaco"
        }
    }

    /// `nil` asks `EditorTheme` for the system monospaced font.
    var fontName: String? {
        switch self {
        case .system: return nil
        case .menlo: return "Menlo-Regular"
        case .monaco: return "Monaco"
        }
    }
}

/// Persisted, app-wide editor settings.
struct EditorSettings: Codable, Equatable, Sendable {
    static let fontSizeRange: ClosedRange<Double> = 10...24
    static let defaultFontSize: Double = 13
    static let `default` = EditorSettings()

    var appearance: EditorAppearance = .system
    var fontFamily: EditorFontFamily = .system
    var fontSize: Double = defaultFontSize
    var softWrap = true

    /// Clamps values that could come from an old or hand-edited defaults file.
    func normalized() -> EditorSettings {
        var copy = self
        if !copy.fontSize.isFinite {
            copy.fontSize = Self.defaultFontSize
        } else {
            let range = Self.fontSizeRange
            copy.fontSize = min(max(copy.fontSize, range.lowerBound),
                                range.upperBound)
        }
        return copy
    }
}

/// Loads and saves the app-wide editor settings.
protocol EditorSettingsStore: Sendable {
    func load() -> EditorSettings
    func save(_ settings: EditorSettings)
}

/// Stores settings as one JSON blob in `UserDefaults`.
///
/// A single versioned key makes unknown or corrupt data fail closed: the
/// defaults are returned instead of a half-applied mix of old values.
final class UserDefaultsEditorSettingsStore: EditorSettingsStore, @unchecked Sendable {
    static let defaultKey = "ModEdit.editorSettings.v1"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard,
         key: String = UserDefaultsEditorSettingsStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> EditorSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(EditorSettings.self,
                                                       from: data)
        else { return .default }
        return settings.normalized()
    }

    func save(_ settings: EditorSettings) {
        guard let data = try? JSONEncoder().encode(settings.normalized()) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

/// In-memory store for tests and for models that should not share the app's
/// persisted preferences.
final class InMemoryEditorSettingsStore: EditorSettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: EditorSettings

    init(_ settings: EditorSettings = .default) {
        self.settings = settings.normalized()
    }

    func load() -> EditorSettings {
        lock.withLock { settings }
    }

    func save(_ settings: EditorSettings) {
        lock.withLock { self.settings = settings.normalized() }
    }
}

/// Observable, app-wide editor preferences.
///
/// Every open window observes the same instance, so changing the theme, font or
/// wrapping updates all editors without reopening them. The app creates models
/// with `shared`; tests get an isolated in-memory instance by default.
@MainActor
final class EditorPreferences: ObservableObject {
    static let shared = EditorPreferences(store: UserDefaultsEditorSettingsStore())

    @Published private(set) var settings: EditorSettings
    private let store: any EditorSettingsStore

    init(store: any EditorSettingsStore = InMemoryEditorSettingsStore()) {
        self.store = store
        self.settings = store.load().normalized()
    }

    /// Theme derived from the current settings. A font that is not installed
    /// falls back to the system monospaced font inside `EditorTheme`.
    var theme: EditorTheme {
        EditorTheme(fontSize: CGFloat(settings.fontSize),
                    fontName: settings.fontFamily.fontName)
    }

    func setAppearance(_ value: EditorAppearance) {
        update { $0.appearance = value }
    }

    func setFontFamily(_ value: EditorFontFamily) {
        update { $0.fontFamily = value }
    }

    func setFontSize(_ value: Double) {
        update { $0.fontSize = value }
    }

    func setSoftWrap(_ value: Bool) {
        update { $0.softWrap = value }
    }

    func toggleSoftWrap() {
        setSoftWrap(!settings.softWrap)
    }

    func reset() {
        update { $0 = .default }
    }

    private func update(_ transform: (inout EditorSettings) -> Void) {
        var next = settings
        transform(&next)
        next = next.normalized()
        guard next != settings else { return }
        settings = next
        store.save(next)
    }
}
