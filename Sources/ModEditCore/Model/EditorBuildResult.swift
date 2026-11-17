import IncrementalParsing
import PL0Language

struct EditorBuildResult: Sendable {
    let succeeded: Bool
    let diagnostics: [LanguageProviderDiagnostic]

    static func compile(_ snapshot: PL0Language.SourceSnapshot) -> Self {
        do {
            _ = try PL0Compiler().compile(snapshot)
            return .init(succeeded: true, diagnostics: [])
        } catch PL0CompilationError.syntax(let diagnostics) {
            return .init(succeeded: false, diagnostics: diagnostics.map {
                .init(id: $0.id, severity: $0.severity, message: $0.message, range: $0.range)
            })
        } catch PL0CompilationError.semantic(let message, let range) {
            return .init(succeeded: false, diagnostics: [
                .init(severity: .error, message: message, range: range),
            ])
        } catch {
            return .init(succeeded: false, diagnostics: [
                .init(severity: .error, message: String(describing: error), range: .zero),
            ])
        }
    }
}
