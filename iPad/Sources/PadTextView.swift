import IncrementalParsing
import SwiftUI
import UIKit

struct PadTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    let tokens: [LanguageProviderToken]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        view.backgroundColor = .systemBackground
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        let textChanged = view.text != text
        if textChanged { view.text = text }
        let range = NSRange(location: min(selection.location, view.textStorage.length),
                            length: min(selection.length, max(0, view.textStorage.length - selection.location)))
        if view.selectedRange != range {
            view.selectedRange = range
            view.scrollRangeToVisible(range)
        }
        guard view.markedTextRange == nil else { return }
        guard textChanged || context.coordinator.tokens != tokens else { return }
        context.coordinator.tokens = tokens
        let storage = view.textStorage
        storage.beginEditing()
        storage.setAttributes([.font: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular),
                               .foregroundColor: UIColor.label],
                              range: NSRange(location: 0, length: storage.length))
        for token in tokens {
            let range = NSRange(location: token.range.location, length: token.range.length)
            guard NSMaxRange(range) <= storage.length else { continue }
            let color: UIColor
            switch token.classification {
            case "keyword": color = .systemPurple
            case "string": color = .systemRed
            case "comment": color = .systemGreen
            case "number": color = .systemBlue
            default: color = .label
            }
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }
        storage.endEditing()
        view.typingAttributes = [.font: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular),
                                 .foregroundColor: UIColor.label]
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PadTextView
        var updating = false
        var tokens: [LanguageProviderToken] = []
        init(_ parent: PadTextView) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            guard !updating else { return }
            parent.text = view.text
            parent.selection = view.selectedRange
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            guard !updating else { return }
            parent.selection = view.selectedRange
        }
    }
}
