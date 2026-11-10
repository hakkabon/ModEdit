import UniformTypeIdentifiers

extension UTType {
    /// Markdown.
    ///
    /// `UTType.markdown` only exists in the macOS 27 SDK, so it cannot be used
    /// with a macOS 13 deployment target. Importing by identifier works on every
    /// OS version; the type is declared in `Info.plist` (`UTImportedTypeDeclarations`).
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown")

    /// LaTeX / TeX source. Also declared in `Info.plist`.
    static let latex = UTType(importedAs: "org.tug.tex")

    /// PL/0 source used by the experimental language workbench.
    static let pl0Source = UTType(importedAs: "io.github.hakkabon.pl0-source")

    /// BNF, EBNF, WSN, and the Grammar package's combined notation.
    static let grammarSource = UTType(
        importedAs: "io.github.hakkabon.grammar-source")

    /// Graphviz DOT source.
    static let dotSource = UTType(importedAs: "io.github.hakkabon.dot-source")

    /// CSS. `UTType.css` requires a newer deployment target.
    static let cssText = UTType(importedAs: "public.css")
}
