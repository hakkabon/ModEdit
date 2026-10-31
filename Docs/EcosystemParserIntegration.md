# Direct Ecosystem Parser Integration

## Dependency model

ModEdit directly links the released Grammar/Parser ecosystem packages through
SwiftPM. `PL0Language` depends on Grammar, Parser, Lexer, LL-Parsing,
LR-Parsing, Earley-Parser, Earley-TableParser, CYK-Parser, RNGLR-Parser,
GrammarDiagram and Compiler. SwiftPM resolves one shared package identity for
each dependency; there is no copied parser implementation or subprocess
required to compare engines.

The resolved versions are recorded in `Package.resolved`. They deliberately
follow the compatible release ranges proven by Grammar-REPL rather than sibling
repositories' potentially newer development branches.

## PL/0 adapters

`ecosystemGrammar(_:)` projects the authoritative `PL0.grammar` artifact into
Grammar's `Grammar`, `Production`, `Symbol`, `Terminal` and `NonTerminal`
types. `PL0EcosystemTokenStream` implements Lexer's positioned `TokenStream`
contract and converts ModEdit's UTF-16 token ranges to `String.Index` ranges.
All engines therefore receive the same grammar instance and terminal sequence.

The editor's SLR and Earley choices are thin adapters:

* `LRPL0Parser` invokes `LR_Parsing.LRParser` with `.slr`, projects its native
  reduction tree and retains its actual shift/reduce trace.
* `EarleyPL0Parser` invokes `Earley_Parser.EarleyParser`, exports the package
  SPPF through Parser's `ParseForestSnapshot`, and projects that portable forest
  into the existing workbench view.

The former local SLR table generator, LR machine, Earley chart algorithm and
private packed-forest builder have been deleted.

`PL0EcosystemParserSession` runs the canonical family directly:

1. Earley
2. Earley Table SL
3. Earley Table EL
4. CYK
5. RNGLR
6. LL(1)
7. LR(0)
8. SLR(1)
9. LALR(1)
10. Canonical LR(1)

No environment variable or Grammar-REPL executable is needed. Open the
workbench's **Compare** tab and select **Run actual engines**.

## Result semantics

Each observation retains support and parse status, derivation count, available
forest size and ambiguity, production-identity coverage, and portable replay
events. The comparison records document revision, grammar fingerprint and
source fingerprint. Editing clears the displayed comparison, and late results
for an older revision are discarded.

`agreement` is `complete` when at least two supported engines agree on
acceptance, `divergent` when they disagree, and `inconclusive` when fewer than
two engines are supported. ModEdit never changes an engine's decision to match
the compatibility parser.

RNGLR 0.2.x does not yet accept Lexer's `TokenStream`, so its adapter feeds the
same normalized terminal names as a synthetic source string. This is an API
compatibility shim, not another recognizer.

## Remaining duplication

The course correction is intentionally staged around behavior-preserving
deletion. These pieces remain and should be removed in subsequent migrations:

* The handwritten PL/0 recovery parser still supplies the editor's normalized
  missing/skipped-token CST on malformed input. LL-Parsing already performs
  recovery; the missing work is a lossless projection into ModEdit's concrete
  terminal model.
* The PL/0 scanner retains UTF-16 incremental identities and lossless comment
  trivia. Lexer supplies the DFA scanner and `TokenStream`; its result must be
  combined with incremental trivia ownership before the local scanner can be
  deleted without regressing editing behavior.
* The PL/0 compiler and VM predate the direct Compiler dependency. PL/0
  semantic lowering should target Compiler's syntax adapter, IR, bytecode and
  runtime contracts, retaining only genuinely language-specific semantics.
* Stable-prefix counts are currently adapter evidence, not native incremental
  LR stack or Earley chart reuse. Genuine reusable states belong in the shared
  parser packages so Grammar-REPL, Grammar-Workbench and ModEdit exercise the
  same implementation.

Tests cover the directly linked ten-engine family, editor-facing LR/Earley
adapters, deterministic comparison serialization, recovery compatibility,
mutation campaigns and the existing editor/LSP/compiler behavior.
