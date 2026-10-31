# Language Experiment Protocol

## Purpose

The `LanguageExperimentProtocol` target defines the boundary between an editor
revision and the grammar, lexer, parser, semantic, and compiler tools that
observe it. The protocol is a data contract, not another parser API. Algorithm
packages continue to own their native charts, automata, stacks, forests, and
traces; adapters export only portable evidence.

The first producer is `PL0Language`. Intended additional producers and
consumers are Grammar, Lexer, Parser, LL-Parsing, LR-Parsing, Earley-Parser,
Earley-TableParser, CYK-Parser, RNGLR-Parser, Grammar-REPL,
Grammar-Workbench, and Compiler.

## Versioning

`LanguageExperimentBundle.schemaVersion` is currently `1`. Decoding fails for
an unsupported version instead of silently interpreting a changed model.
Producers should add optional evidence in a backwards-compatible schema only
when old consumers can safely ignore it. Renaming fields, changing meanings,
or changing invariants requires a new schema version.

JSON is emitted with sorted keys. This makes fixtures, diffs, discrepancy
artifacts, and reproducibility checks stable. Source and grammar identity use
the ecosystem's `fnv1a64` interchange fingerprint. It is an identity checksum,
not a security signature.

## Model

One `LanguageExperimentBundle` contains one or more `ParseExperimentRun`
values. Runs can represent:

* multiple engines parsing the same revision;
* successive revisions in an incremental edit campaign;
* full and incremental executions of the same revision; or
* a minimized parser discrepancy.

Each run contains the following layers.

### Source identity

`DocumentRevision` declares the URI, language ID, monotonically assigned
revision, coordinate space, measured length, and source fingerprint.
`SourceArtifact` retains the complete source and verifies its length and
fingerprint. Retaining the text makes a bundle replayable without a live editor
buffer.

ModEdit uses UTF-16 because TextKit and LSP positions use UTF-16 offsets. Other
producers must declare UTF-8 or Unicode-scalar coordinates explicitly rather
than relying on an implicit convention.

### Grammar identity and provenance

`GrammarArtifactIdentity` identifies the exact grammar revision used for the
run. It includes notation, optional normal form, fingerprint, and optional
`ProductionProvenance` entries relating normalized productions to source
productions.

Grammar-Workbench should eventually populate provenance from Grammar's
normalization report. A parser adapter must copy the same identity into its
token and parse evidence so clients can reject stale combinations.

### Token snapshot

`TokenSnapshot` contains ordered `ExperimentToken` values with stable identity,
kind, spelling, range, and channel. Channels distinguish source tokens, trivia,
invalid input, and EOF. Construction rejects duplicate identities and ranges
outside the declared source revision.

The current PL/0 lexer discards trivia, so its adapter exports source, invalid,
and EOF channels only. The contract is ready for a future lossless tokenizer.

### Parser execution

`EngineExecutionPath` distinguishes the requested parser from the engine that
produced the editor-facing result. When they differ, a non-empty fallback
reason is mandatory. This is especially important in the current PL/0 workbench:
LR and Earley recognize valid input natively but use reference LL recovery for
invalid input.

`ExperimentOperationDisposition` states whether an invocation completed, was
unsupported, reached a limit, was cancelled, or failed. This is distinct from
`ExperimentParseStatus`, which states whether the language input was accepted,
recovered, or rejected.

### Diagnostics and recovery

Diagnostics retain severity, message, expected terminal names, and source
range. Recovery evidence is an ordered list of insert/delete/skip edits. Each
edit includes its cost and associated diagnostic identities. A consumer can
therefore compare native recovery policies without parsing a human-readable
message.

### Reuse evidence

`ReuseEvidence` never publishes one aggregate "incremental percentage". It
contains independent `ReuseMeasurement` values for tokens, parser states,
syntax nodes, chart columns, forest nodes, and semantic nodes. Every measurement
names its strategy and separately reports reused and rebuilt units. Invalidation
is optional because not every existing engine can measure it truthfully.

The PL/0 adapter currently exports token and syntax-node reuse for every engine,
and closed chart-column reuse for Earley. LR's resume token boundary is exported
as a typed operational measurement until the LR engine can report a genuine
count of reused parser states.

## Invariants

Constructors and decoding enforce the following rules:

1. Required identities and display fields are non-empty.
2. Ranges and counts are non-negative.
3. Token and diagnostic ranges fit within the declared source revision.
4. Token identities are unique within a snapshot.
5. Source length and fingerprint match the retained text.
6. Source, grammar, and token snapshots refer to the same language/revision.
7. Fallback metadata agrees with requested and effective engines.
8. Incremental evidence identifies a base revision.
9. Run IDs are unique within a bundle.
10. Unsupported schema versions fail closed.

## Relationship to Parser

The sibling Parser package remains authoritative for portable semantic parse
results, production-aware trees, BSR/SPPF snapshots, replay events, operational
capabilities, limits, and parser laws. This ModEdit target covers the surrounding
editor experiment: exact source and grammar revision, tokens, fallback path,
incremental reuse, timings, and bundling of edit sequences.

The planned Parser adapter should embed or reference Parser's
`ParseOperationalSnapshot` rather than reimplementing its production tree or
forest schemas here. Keeping these roles separate prevents a second generalized
parser contract from emerging in ModEdit.

## Adoption sequence

1. Grammar-Workbench supplies the grammar artifact fingerprint and normalization
   provenance when a grammar is compiled or hot-reloaded.
2. Lexer supplies the stable token snapshot, including trivia and lexical-state
   reuse when available.
3. Algorithm adapters attach Parser semantic/operational snapshots and map their
   native reuse measurements into the experiment run.
4. Grammar-REPL imports and exports bundles for replay, comparison, minimization,
   and scripting.
5. Compiler attaches semantic/IR/runtime artifact identities to later schema
   versions without changing the parser-engine contract.

Until those repositories adopt the target directly, its deterministic JSON is
the interchange boundary. Once the schema stabilizes across consumers, the
target can move to the shared Parser or SDK layer without changing its wire
format.
