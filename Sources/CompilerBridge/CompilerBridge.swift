import Compiler

/// Stable names for Compiler's public syntax boundary. The upstream module and
/// its main class are both named `Compiler`, which makes qualified references
/// ambiguous in clients that also define syntax types.
public typealias EcosystemSyntaxNode = SyntaxNode
public typealias EcosystemSyntaxToken = SyntaxToken
public typealias EcosystemSourceRange = SourceRange
public typealias EcosystemSourceLocation = SourceLocation
