import AppKit
import Foundation
import Testing
@testable import ModEditCore

@Suite("Editor preferences")
@MainActor
struct EditorPreferencesTests {

    @Test func defaultsMatchThePreviousEditorConfiguration() {
        let preferences = EditorPreferences()

        #expect(preferences.settings == .default)
        #expect(preferences.settings.appearance == .system)
        #expect(preferences.settings.fontFamily == .system)
        #expect(preferences.settings.fontSize == 13)
        #expect(preferences.settings.softWrap)
        #expect(preferences.theme.baseFont.pointSize == 13)
    }

    @Test func changesPersistAcrossInstances() {
        let store = InMemoryEditorSettingsStore()
        let preferences = EditorPreferences(store: store)

        preferences.setAppearance(.dark)
        preferences.setFontFamily(.menlo)
        preferences.setFontSize(17)
        preferences.setSoftWrap(false)

        let reloaded = EditorPreferences(store: store)
        #expect(reloaded.settings == preferences.settings)
        #expect(reloaded.settings.appearance == .dark)
        #expect(reloaded.settings.fontFamily == .menlo)
        #expect(reloaded.settings.fontSize == 17)
        #expect(!reloaded.settings.softWrap)
    }

    @Test func userDefaultsStoreRoundTripsSettings() {
        let suite = "ModEditTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsEditorSettingsStore(defaults: defaults)
        let expected = EditorSettings(appearance: .light,
                                      fontFamily: .monaco,
                                      fontSize: 19,
                                      softWrap: false)

        store.save(expected)

        #expect(store.load() == expected)
    }

    @Test func corruptOrMissingDataFallsBackToDefaults() {
        let suite = "ModEditTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsEditorSettingsStore(defaults: defaults)

        #expect(store.load() == .default)
        defaults.set(Data("not json".utf8),
                     forKey: UserDefaultsEditorSettingsStore.defaultKey)
        #expect(store.load() == .default)
    }

    @Test func storedFontSizesAreClampedToTheSupportedRange() {
        let store = InMemoryEditorSettingsStore(EditorSettings(fontSize: 500))
        let preferences = EditorPreferences(store: store)

        #expect(preferences.settings.fontSize == 24)

        preferences.setFontSize(1)
        #expect(preferences.settings.fontSize == 10)
    }

    @Test func resetRestoresDefaultsAndPersistsThem() {
        let store = InMemoryEditorSettingsStore()
        let preferences = EditorPreferences(store: store)
        preferences.setAppearance(.light)
        preferences.setFontSize(21)

        preferences.reset()

        #expect(preferences.settings == .default)
        #expect(EditorPreferences(store: store).settings == .default)
    }

    @Test func themeUsesTheSelectedFamilyAndSize() {
        let preferences = EditorPreferences()
        preferences.setFontFamily(.menlo)
        preferences.setFontSize(17)

        #expect(preferences.theme.baseFont.pointSize == 17)
        #expect(preferences.theme.baseFont.fontName.hasPrefix("Menlo"))
        #expect(preferences.theme.boldFont.pointSize == 17)
    }

    @Test func appearanceMapsToAppKitAppearances() {
        #expect(EditorAppearance.system.nsAppearance == nil)
        #expect(EditorAppearance.light.nsAppearance?.name == .aqua)
        #expect(EditorAppearance.dark.nsAppearance?.name == .darkAqua)
    }

    @Test func modelKeepsTheInjectedPreferences() {
        let preferences = EditorPreferences()
        preferences.setFontSize(20)
        let model = EditorModel(document: EditorDocument(),
                                preferences: preferences)

        #expect(model.preferences === preferences)
        #expect(model.preferences.settings.fontSize == 20)
    }

    @Test func liveViewUpdateAppliesFontAndWrappingChanges() {
        let preferences = EditorPreferences()
        let model = EditorModel(document: EditorDocument(),
                                preferences: preferences)
        let coordinator = EditorTextView.Coordinator(model: model)
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let textView = EditorNSTextView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        textView.string = "one two three"
        scrollView.documentView = textView
        coordinator.attach(to: textView)
        coordinator.applyPreferences(in: scrollView)

        #expect(coordinator.theme.baseFont.pointSize == 13)
        #expect(textView.font?.pointSize == 13)
        #expect(textView.textContainer?.widthTracksTextView == true)
        #expect(!scrollView.hasHorizontalScroller)

        textView.setSelectedRange(NSRange(location: 4, length: 0))
        preferences.setFontFamily(.menlo)
        preferences.setFontSize(19)
        preferences.setSoftWrap(false)
        coordinator.applyPreferences(in: scrollView)

        #expect(coordinator.theme.baseFont.pointSize == 19)
        #expect(textView.font?.fontName.hasPrefix("Menlo") == true)
        #expect(textView.textContainer?.widthTracksTextView == false)
        #expect(scrollView.hasHorizontalScroller)
        #expect(textView.string == "one two three")
        #expect(textView.selectedRange() == NSRange(location: 4, length: 0))
    }
}

@Suite("Soft wrap")
@MainActor
struct EditorSoftWrapTests {

    @Test func togglingWrapChangesTheTextContainerAndScroller() {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let textView = EditorNSTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.string = "one two three"
        scrollView.documentView = textView
        scrollView.layoutSubtreeIfNeeded()
        let container = textView.textContainer!

        EditorSoftWrap.apply(false, to: textView, in: scrollView)

        #expect(!container.widthTracksTextView)
        #expect(textView.isHorizontallyResizable)
        #expect(scrollView.hasHorizontalScroller)
        #expect(container.containerSize.width > 1_000_000)
        #expect(textView.maxSize.width > 1_000_000)

        EditorSoftWrap.apply(true, to: textView, in: scrollView)

        #expect(container.widthTracksTextView)
        #expect(!textView.isHorizontallyResizable)
        #expect(!scrollView.hasHorizontalScroller)
        #expect(container.containerSize.width <= scrollView.contentSize.width + 1)
        #expect(textView.string == "one two three")
    }
}
