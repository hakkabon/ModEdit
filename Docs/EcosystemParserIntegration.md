# Ecosystem Parser Integration

## Purpose

Phase 3 connects ModEdit's controlled PL/0 language to the actual parser
packages used across the Grammar ecosystem. The integration is differential:
it preserves each engine's answer and evidence so a disagreement remains a
testable result rather than being hidden behind the reference parser.

The canonical engine family is:

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

## Architecture

`PL0EcosystemParserSession` is platform-neutral and depends on the
`EcosystemParserTransport` protocol. It lexes a versioned source snapshot with
`PL0LanguageKit`, then creates a deterministic schema-5 corpus containing:

* all 29 terminals from `PL0.grammar`;
* all 43 productions and their stable IDs;
* the authoritative start symbol and grammar fingerprint; and
* the current significant token-kind sequence, excluding EOF.

The production transport, `GrammarREPLConformanceProcessTransport`, writes that
corpus to an isolated temporary directory, executes
`grammar-repl-conformance`, reads its observation file and removes the
directory. ModEdit validates that the response contains exactly the canonical
ten engines in stable order before exposing an `EcosystemParserComparison`.

This out-of-process design is deliberate. Grammar-REPL already integrates and
resolves compatible versions of Grammar, Lexer, Parser, LL-Parsing, LR-Parsing,
Earley-Parser, both Earley table variants, CYK-Parser and RNGLR-Parser. Linking
all sibling packages directly into ModEdit would risk duplicate Swift module
identities and competing dependency resolutions. The conformance executable is
the ecosystem-owned integration host; ModEdit remains a consumer of its
portable contract.

## Running it

Build the adapter in Grammar-REPL:

```sh
swift build --product grammar-repl-conformance
```

Set `MODEDIT_GRAMMAR_REPL_CONFORMANCE` to the resulting absolute executable
path before starting ModEdit. In a PL/0 document, open the **Compare** tab and
choose **Run actual engines**.

For the optional real-engine test:

```sh
MODEDIT_TEST_GRAMMAR_REPL_CONFORMANCE=/absolute/path/to/grammar-repl-conformance \
swift test --filter realGrammarREPLRunsCanonicalEngineFamilyWhenConfigured
```

Ordinary unit tests use an injected transport and do not require sibling
repositories or external executables.

## Result semantics

Every engine observation includes support status, parse status, derivation
count, optional forest size and ambiguity, production-identity coverage and a
portable replay-event summary. `agreement` is:

* `complete` when at least two supported engines share the same acceptance;
* `divergent` when supported engines disagree; or
* `inconclusive` when fewer than two engines are supported.

The comparison records both document revision and source fingerprint. The UI
also discards results if the live revision changed while the process was
running.

The current real-engine baseline for `var x; begin x := 1 end.` is intentionally
recorded in the optional integration test. Earley, Earley SL/EL, RNGLR, LL(1),
SLR, LALR and LR(1) accept. LR(0) rejects, which is expected for a grammar that
is not LR(0). CYK also rejects and is retained as a normalization/integration
issue to investigate rather than being relabelled as acceptance.

## Current boundary and next work

The bridge currently transports recognition and compact forest/replay evidence.
The editor-native reference LL, generated SLR and Earley implementations still
own the rich CST, recovery, reuse and detailed trace views.

The next contract revision should transport native reduction trees, packed
forest nodes and edges, recovery edits, conflicts, timing and detailed replay
events using the shared `LanguageExperimentProtocol` identities. That will let
Grammar-REPL, Grammar-Workbench, benchmarks and mutation campaigns replay the
same artifact without weakening engine-specific evidence.
