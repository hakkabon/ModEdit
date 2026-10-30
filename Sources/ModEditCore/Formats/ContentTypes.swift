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
}
