# Semantics, Compiler, and LSP

Phase 5 adds one semantic ownership boundary after the unified PL/0 front end.
`PL0LanguageSession.analyze(_:)` now returns a `PL0Analysis` containing the exact
prepared input, parse result, and semantic model for one document revision.

```text
PL0PreparedFrontend
        |
        v
    ParseResult
        |
        v
 PL0SemanticModel
    /          \
PL0Compiler   PL0LSPAdapter
    |              |
 bytecode      diagnostics, completion,
               definition, hover, references,
               and semantic tokens
```

## Semantic model

`PL0SemanticModel` owns lexical scopes, stable declarations, resolved
references, source-located diagnostics, and semantic classifications. Symbols
record their declaration token identity, lexical level, storage slot, and
constant value where applicable. Since declaration IDs come from incremental
lexer tokens, an edit outside a declaration can retain its semantic identity.

The analyzer reports duplicate declarations, unknown identifiers, invalid
assignment/call targets, procedure-as-value errors, and integer literals that
cannot be represented by the PL/0 VM. The model is public and independent of
AppKit and LSP wire types.

## Compiler integration

`PL0Compiler` accepts a `PL0Analysis`, rejects the same semantic diagnostics
published by the LSP, and lowers resolved symbol IDs directly. The lowerer no
longer performs its own name lookup: loads, stores, constants, and calls use the
semantic model's lexical levels, slots, values, and declaration identities.

`PL0CompilationArtifacts` also includes a projection of the concrete, recovered
CST into the linked Compiler package's public `SyntaxNode` boundary.
The tiny `CompilerBridge` target gives those upstream types unambiguous names;
the upstream module and its main class are both named `Compiler`.

PL/0 bytecode remains language-specific for now. Compiler's demonstration IR
does not represent PL/0 static links or nested procedures, so translating it
prematurely would lose lexical-address semantics. A future shared Compiler IR
extension should add explicit lexical levels/static links before the PL/0 VM is
replaced.

## LSP integration

Each open LSP document owns a `PL0LanguageSession`. A single ranged change is
converted to a versioned UTF-16 `SourceEdit`, allowing the incremental tokenizer
and stable semantic identities to be reused. Multiple simultaneous changes
safely fall back to full preparation.

The adapter now obtains every language feature from `PL0SemanticModel`:

* parser and semantic diagnostics;
* scope-aware completion using grammar-derived keyword spellings;
* definition, hover, and find-references;
* classified semantic tokens; and
* the standard five-integer delta-encoded semantic-token stream, with
  declaration modifier bit zero.

The adapter remains transport-neutral. JSON-RPC framing, capability negotiation,
request cancellation, and process lifecycle belong in a future thin server
target rather than in the semantic engine.

## Workbench

The Problems view combines syntax and semantic diagnostics. The Semantics view
shows lexical scopes and their declarations, including kind, lexical level,
and storage slot. Compilation from the Run view reuses the analysis already
computed for the displayed editor revision.
