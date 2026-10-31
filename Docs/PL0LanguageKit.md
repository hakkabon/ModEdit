# PL/0 Single-Source Language Kit

## Authority

`Sources/PL0Language/Resources/PL0.grammar` is the authoritative PL/0 lexical
and syntactic definition. SwiftPM packages it with `PL0Language`; there is no
second example copy that can drift.

`PL0LanguageKit.loadBundled()` reads and compiles that resource. A malformed or
incompatible bundled grammar stops immediately during language-kit
initialization. The compiled artifact contains:

* artifact ID, revision and FNV-1a source fingerprint;
* start symbol;
* 29 typed token definitions and skip patterns;
* 43 productions with stable ordinal identities; and
* typed terminal/nonterminal symbols.

The compiler verifies that every RHS symbol is declared, every typed PL/0 token
is present exactly once, the start symbol exists, and the 18 nonterminals match
`PL0Nonterminal`. These typed bindings are the current lightweight equivalent
of generated Grammar-Macros bindings. They can later be replaced by macro
output without changing the runtime artifact.

## Consumers

The same artifact now drives several components:

1. `PL0Lexer` derives keywords and operators from `%token` patterns.
2. `LRPL0Parser` projects the productions into Grammar and invokes
   LR-Parsing's SLR implementation.
3. `EarleyPL0Parser` invokes Earley-Parser with that same Grammar value.
4. `PL0Frontend` records the artifact identity in every `ParseResult`.
5. `PL0ExperimentContract` uses that identity by default and rejects a supplied
   identity with a different artifact/revision/fingerprint.
6. Grammar Workbench uses the exact bundled source by default and reports when
   an experimental external grammar differs from the native artifact.
7. `PL0EcosystemParserSession` runs the complete directly linked engine family
   with the same Grammar value and positioned Lexer token stream.

The handwritten reference LL parser remains the recovery oracle. Its typed
token and nonterminal assumptions are checked against the bundled grammar, but
its control flow remains deliberately handwritten for transparent recovery
experiments.

## Experimental grammar revisions

An experiment can compile another source without replacing global state:

```swift
let source = PL0LanguageKit.bundled.artifact.source
    .replacingOccurrences(of: "%token CALL /call\\b/",
                          with: "%token CALL /invoke\\b/")
let kit = try PL0LanguageKit.compile(source: source, revision: 2)
let lexer = PL0Lexer(languageKit: kit)
let lr = LRPL0Parser(languageKit: kit)
let earley = EarleyPL0Parser(languageKit: kit)
```

Incremental lexer and parser sessions take a kit at initialization, so caches
cannot accidentally cross artifact boundaries. A new kit creates a new session.

## Lossless lexical stream

`LexResult` now contains two views:

* `tokens`: significant tokens plus EOF, preserving the existing parser API;
* `losslessTokens`: significant tokens, invalid input, whitespace, line
  comments and block comments in exact source order.

Concatenating the lossless lexemes reconstructs the source. Incremental
tokenization reuses and relocates trivia identities alongside significant-token
identities. The formatter consumes comment trivia from this stream instead of
rescanning source independently, and experiment bundles export trivia through
the shared token channel.

Trivia is not yet assigned as leading/trailing trivia on CST nodes. That policy
belongs in a later lossless syntax projection because ownership at blank lines,
declaration boundaries and recovered regions needs explicit rules.

## Grammar Workbench overrides

Only `MODEDIT_GRAMMAR_WORKBENCH_SERVICE` is required. ModEdit sends the bundled
grammar source when opening the Workbench session. `MODEDIT_PL0_GRAMMAR` remains
available for deliberate hot-reload experiments; the UI labels a differing
fingerprint instead of implying that the native and external parsers are using
the same artifact.
