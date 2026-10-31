# Unified experimental front ends

Phase 4 gives every PL/0 experiment one preparation boundary. A
`PL0PreparedFrontend` is an immutable, versioned package containing the source
snapshot, lossless lexer result, parser input, grammar fingerprint, and lexical
measurements. It is the unit passed from the editor to parser engines rather
than having each feature tokenize the document again.

```text
SourceSnapshot
      |
      v
PL0Frontend.prepare
      |
      +-- Reference LL / native SLR / native Earley
      +-- linked LL, LR, Earley, CYK and RNGLR packages
      +-- formatter and compiler
      `-- LSP analysis
```

## Editor session

`PL0LanguageSession` owns incremental token and parser state for an open
document. Its normal `parse` operation stores the prepared value. A subsequent
`compare` for the same snapshot reuses it, so the workbench comparison observes
the exact token identities and grammar revision already displayed by the
editor. A changed snapshot is prepared once before comparison.

The comparison itself remains off the UI actor and invokes the actual package
engines through `PL0EcosystemParserSession`. That session validates the prepared
grammar fingerprint before constructing the ecosystem token stream.

## Other consumers

`PL0Formatter`, `PL0Compiler`, and `PL0LSPAdapter` accept an injected
`PL0Frontend`. Their original convenience initializers remain source-compatible
and use the bundled language kit. Injection is important for
Grammar-Workbench hot reload: a compiled kit can now be installed consistently
in all three consumers instead of only in an isolated parser experiment.

## Invariants

* Source text, revision, token ranges, and parser input travel together.
* A prepared value records the grammar fingerprint that classified its tokens.
* Local parser engines retain token identities from the prepared input.
* Direct ecosystem comparisons reject a grammar-fingerprint mismatch.
* Incremental session state is discarded by `reset`, including its prepared
  comparison input.

This phase unifies orchestration inside ModEdit. It does not duplicate parser
algorithms: the broad comparison family continues to come directly from the
Grammar/Parser ecosystem packages. The next integration step is a shared
package-level language-session contract that Grammar-Workbench, Grammar-REPL,
and ModEdit can all adopt without depending on the PL/0 target.
