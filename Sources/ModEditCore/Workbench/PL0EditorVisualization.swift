import Foundation
import PL0Language

/// Editor-facing projection of a parse result. Keeping this smaller than
/// `ParseResult` avoids publishing the full CST and token stream through the
/// editor model merely to draw diagnostics.
struct PL0EditorVisualization: Sendable, Equatable {
    enum AnnotationKind: String, Sendable {
        case error
        case warning
        case information
        case missingToken
        case skippedToken
    }

    struct Annotation: Sendable, Equatable, Identifiable {
        let id: String
        let kind: AnnotationKind
        let range: SourceRange
        let message: String
    }

    let version: UInt64
    let annotations: [Annotation]
    let problemCount: Int
    let recoveryCount: Int

    init(result: ParseResult) {
        version = result.version
        problemCount = result.diagnostics.count
        recoveryCount = result.recovery.events.count

        var projected = result.diagnostics.enumerated().map { index, diagnostic in
            let kind: AnnotationKind = switch diagnostic.severity {
            case .error: .error
            case .warning: .warning
            case .information: .information
            }
            return Annotation(id: "diagnostic:\(index):\(diagnostic.id)",
                              kind: kind, range: diagnostic.range,
                              message: diagnostic.message)
        }
        projected.append(contentsOf: result.recovery.events.map { event in
            let kind: AnnotationKind
            switch event.action {
            case .insert: kind = .missingToken
            case .delete: kind = .skippedToken
            }
            return Annotation(id: "recovery:\(event.id)", kind: kind,
                              range: event.action.range,
                              message: event.action.summary)
        })
        annotations = projected
    }
}

struct EditorRevealRequest: Equatable {
    let id: UInt64
    let range: SourceRange
}

struct EditorSourceReplacementRequest: Equatable {
    let id: UInt64
    let text: String
}
