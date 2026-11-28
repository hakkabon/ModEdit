import AppKit
import SwiftUI

/// App-wide editor settings. Changes apply to every open window immediately.
@MainActor
struct EditorSettingsView: View {
    @ObservedObject var preferences: EditorPreferences

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: appearance) {
                    ForEach(EditorAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                Picker("Font", selection: fontFamily) {
                    ForEach(EditorFontFamily.allCases) { family in
                        Text(family.displayName).tag(family)
                    }
                }
                HStack {
                    Text("Size")
                    Slider(value: fontSize,
                           in: EditorSettings.fontSizeRange,
                           step: 1)
                    Text("\(Int(preferences.settings.fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Toggle("Wrap long lines", isOn: softWrap)
            }

            Section {
                Button("Restore Defaults") {
                    preferences.reset()
                    NSApp.appearance = preferences.settings.appearance.nsAppearance
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var appearance: Binding<EditorAppearance> {
        Binding(
            get: { preferences.settings.appearance },
            set: { value in
                preferences.setAppearance(value)
                NSApp.appearance = value.nsAppearance
            })
    }

    private var fontFamily: Binding<EditorFontFamily> {
        Binding(
            get: { preferences.settings.fontFamily },
            set: { preferences.setFontFamily($0) })
    }

    private var fontSize: Binding<Double> {
        Binding(
            get: { preferences.settings.fontSize },
            set: { preferences.setFontSize($0) })
    }

    private var softWrap: Binding<Bool> {
        Binding(
            get: { preferences.settings.softWrap },
            set: { preferences.setSoftWrap($0) })
    }
}

/// Standalone settings window owned by the app delegate.
@MainActor
final class EditorSettingsWindowController: NSWindowController {
    init(preferences: EditorPreferences) {
        let hosting = NSHostingController(
            rootView: EditorSettingsView(preferences: preferences))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Editor Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
