# ModEdit

A native macOS text editor for **editing text that renders differently from its
plain-ASCII source**. You type Markdown or LaTeX on the left; a live preview on
the right shows it as headings, emphasis, symbols and mathematics.

> **Status: early development (v0.1.0).** The editor, syntax colouring, format
> switching, file open/save and the live preview work end to end for Plain Text,
> Markdown, LaTeX and HTML. An initial PL/0 parsing workbench provides a
> reference lexer/parser with incremental token and syntax-tree reuse, explicit
> recovery traces and CST inspection.
> Rendering *inside* the editor pane (single-pane
> "live preview" with a caret that moves through rendered text) is the next big
> milestone; see the [roadmap](#roadmap).

## Table of contents

1. [Features](#features)
2. [Requirements](#requirements)
3. [Build, run, test](#build-run-test)
4. [Architecture](#architecture)
5. [Formats](#formats)
6. [The preview](#the-preview)
7. [PL/0 parsing workbench](#pl0-parsing-workbench)
8. [Language experiment protocol](#language-experiment-protocol)
9. [Adding a format](#adding-a-format)
10. [Project layout](#project-layout)
11. [Design decisions](#design-decisions)
12. [Known limitations](#known-limitations)
13. [Roadmap](#roadmap)
14. [Contributing](#contributing)
15. [License](#license)

## Features

* Document-based app (open, save, save a copy, revert, autosave) built on an
  `NSDocument` shell that hosts the SwiftUI editor. Saves are reported as
  successful only after the file write actually completes.
* TextKit-backed `NSTextView` editor with find bar, undo/redo and **all automatic
  text "corrections" disabled** (smart quotes, dashes, replacement), because this
  is a source editor.
* Adaptive **line-number gutter** with a distinct background, plus synchronized
  current-line highlighting in the gutter and editor. A
  soft-wrapped logical line is numbered once; its continuation rows stay blank,
  and the current-line highlight spans every visual fragment. The bottom status
  bar shows the one-based cursor position, active text format, tab size and a
  high-contrast clean/dirty document indicator.
* **Syntax colouring** for Markdown, LaTeX and HTML: debounced, incremental
  (only the edited lines and only those bytes are copied), chunked on load so
  large files do not freeze the UI, state-aware for multiline Markdown fences
  and HTML tags/comments, and safe with input methods
  (Japanese/Chinese/Korean composition).
* **Live preview** (WebKit) that keeps its scroll position while you type.
  Documents above 5 MB show a notice instead of being copied and rendered:
  * *Markdown* — headings, paragraphs, lists, block quotes, fenced code,
    `**bold**`, `*italic*`, `` `code` ``, links (including URLs with balanced
    parentheses such as `/wiki/Foo_(bar)`).
  * *LaTeX* — `\section`, `\textbf`, `\emph`, math with Greek letters and
    operators (`\alpha` → α), super/subscripts (`x^2`, `x_{i}`), comments hidden.
  * *HTML* — your page as written, with scripts, frames and remote loads
    disabled by the preview policy.
* **Encoding-faithful I/O**: UTF-8 (with/without BOM), UTF-16 little- and
  big-endian (with BOM, plus unambiguous BOM-less ASCII/Latin text), and
  detected legacy encodings are written back with the same encoding. UTF-16
  byte order and the presence or absence of a BOM are preserved, so saving
  never silently replaces characters or changes the file's byte layout.
* Light/dark mode aware: `EditorTheme` has explicit light and dark palettes for
  text, syntax, gutter and current-line colours; preview pages use
  `color-scheme` so they follow the system appearance too.
* Experimental **PL/0 language workbench**: native `.pl0` documents, incremental
  UTF-16 tokenization and reference LL parsing with identity reuse, robust error
  recovery, a parser-neutral CST with source/missing/skipped terminals,
  Problems/Recovery/Tokens/CST views, reuse metrics and source-editor
  visualization of diagnostics and repairs. A deterministic formatter and
  bounded bytecode VM turn the workbench into a small executable PL/0 IDE.

## Requirements

* macOS 13 or newer
* Swift 6.1 / Xcode 16.3 or newer
* No third-party dependencies

## Build, run, test

```sh
swift build
swift test                      # macOS only: the module uses AppKit/SwiftUI/WebKit

scripts/make-app.sh             # builds .build/.../ModEdit.app (debug)
scripts/make-app.sh release     # release build
scripts/package-release.sh      # release .app + dist/ModEdit-<version>-macos.zip
open "$(swift build --show-bin-path)/ModEdit.app"
```

The current source is verified with `swift build` and `swift test` (223 tests)
using Swift 6.1.2 and the macOS 15.5 SDK. CI builds and tests both debug and
release, packages the release app, and uploads the zip as an artifact on every
push and pull request. The large-file benchmark suite is skipped by default;
see [Large-file benchmark](#large-file-benchmark).

Why a script? `swift run` starts a bare executable without an app bundle, so the
document types in `Info.plist` are not registered and Finder cannot open files
with it. `make-app.sh` wraps the binary in a minimal bundle and ad-hoc signs it.
You can also open `Package.swift` in Xcode and run the `ModEdit` scheme.

### Large-file benchmark

The benchmark is deliberately separate from the normal test run:

```sh
scripts/benchmark-large-files.sh
# equivalent to:
# MODEDIT_BENCHMARK=1 swift test -c release --filter LargeFileBenchmark
```

It builds 10 MB and 50 MB Markdown files (headings, emphasis, links and fenced
code) and measures load + line index construction, cursor lookup, edits at the
end and in the middle, save snapshots, UTF-8 encoding, a dirty-line highlight
near the end (cold and after checkpoints), the last 50k local highlight chunk,
and a complete line-aligned highlight pass. Results from the development
machine (release build, x86_64):

| Operation | 10 MB | 50 MB |
|-----------|------:|------:|
| Load + line index | 17–20 ms | 79–98 ms |
| Line/column lookup | < 2 µs | < 2 µs |
| Append edit | 0.001 ms | 0.001 ms |
| Middle one-character edit | 0.08–0.09 ms | 0.52–0.75 ms |
| Save snapshot | 5–7 ms | 28–34 ms |
| UTF-8 encode | 5–8 ms | 27–32 ms |
| Dirty-line Markdown highlight | 22–27 ms | 101–127 ms |
| Dirty-line highlight after checkpoints | 0.14–0.31 ms | 0.16–0.20 ms |
| Last 50k local highlight chunk | 36–43 ms | 115–138 ms |
| Full line-aligned highlight pass | 3.1–4.1 s | 15.9–18.5 s |

The important part is not the absolute numbers (they vary by machine) but the
shape: edits and lookups stay flat, and the remaining growth is proportional to
the bytes that genuinely have to be copied or scanned. The full pass is linear
(it carries Markdown/HTML state across chunks instead of re-scanning the prefix
per chunk); the remaining cost is applying attributes to every matched range
(several per dense prose line). It runs in cancellable chunks and yields between
them, so the document is editable while it colours in.

The first dirty-line pass after a fresh load still has to recover Markdown fence
or HTML tag state from the document start. Every full-pass chunk then records a
line-aligned scanner checkpoint, so subsequent passes resume from the nearest
one: on 50 MB the same near-end edit drops from about 115 ms to about 0.2 ms.
Checkpoints are invalidated at and after each edit, keeping the resumed state
consistent with the current text.

### PL/0 parser benchmark

The parser benchmark is also opt-in and always runs with optimization:

```sh
scripts/benchmark-pl0.sh
# equivalent to:
# MODEDIT_PL0_BENCHMARK=1 swift test -c release --filter PL0ParserBenchmark
```

It generates programs containing 100, 250 and 500 statements and reports
full lexer, Reference LL, generated SLR(1), Earley, native tree/forest and
near-end incremental-edit timings. Records use a stable `PL0BENCH` prefix and
include milliseconds, nanoseconds per token, reuse counts, trace events and
forest nodes. A representative x86_64 release run produced:

| Statements | Reference LL | SLR(1) | Earley | Incremental SLR | Incremental Earley | Forest nodes |
|-----------:|-------------:|-------:|-------:|----------------:|-------------------:|-------------:|
| 100 | 2.2 ms | 13.7 ms | 116 ms | 0.8 ms | 21 ms | 17,259 |
| 250 | 4.1 ms | 40.7 ms | 737 ms | 1.5 ms | 105 ms | 99,384 |
| 500 | 7.5 ms | 140 ms | 2.78 s | 4.3 ms | 412 ms | 386,259 |

The forest counts deliberately expose the controlled grammar's ambiguous
nullable statement-list shape. A 5,000-statement exploratory run exhausted the
test process, so the published all-engine corpus is bounded at 500 rather than
hiding the scaling problem. This is a measurement target for future forest
compaction and grammar-refactoring experiments.

### PL/0 mutation campaigns

The normal test suite runs deterministic token deletion and insertion matrices
over a controlled corpus, plus 200 seeded random UTF-16 edits. Every mutation
checks parser termination, bounded recovery, LR/Earley recognition agreement,
and incremental-versus-full CST, diagnostics, expectation and semantic recovery
equivalence for all three engines. The published seed is `0xC0FFEE5EED`, making
failures exactly reproducible. Recovery comparisons intentionally exclude token
identity: incremental tokens retain stable IDs while a fresh parse creates new
ones.

## Architecture

```
PL0Language (platform-neutral library)
┌──────────────────────────────────────────────────────────────────────────┐
│ SourceSnapshot/Edit (versioned UTF-16 ranges)                            │
│ Incremental PL0Lexer → stable PL0Token[] + lexical diagnostics/metrics  │
│ Incremental Reference LL · generated SLR(1) · Earley chart parsers       │
│ Native LR trees · Earley packed forests · traces · parser-neutral CST    │
│ Grammar Workbench JSON-lines session · watched grammar hot reload        │
│ Comment-preserving formatter · lexical-scope compiler · bounded stack VM │
│ Versioned LSP adapter → diagnostics/completion/definition/semantic tokens │
└──────────────────────────────────────────────────────────────────────────┘
                │
                ▼
ModEditApp (executable)           thin: @main calls ModEditApplication.run()
        │
        ▼  AppKit application + document shell
ModEditCore (library)
┌──────────────────────────────────────────────────────────────────────────┐
│ App           ModEditApplication (NSApplicationDelegate, menu)           │
│               ModEditDocument (NSDocument: read/write/save completion)    │
│               ModEditWindowController (window, toolbar, SwiftUI hosting) │
│ UI            EditorRootView ─ EditorTextView (NSTextView) ─ PreviewPane │
│                       └ PL0WorkbenchPane (Problems/CST/Compare/Trace/Run) │
│                 status bar       └ LineNumberRulerView       (WKWebView) │
│                    │                  │  ▲ edits           (WKWebView)    │
│ Model         EditorModel (@MainActor, @Published revision/format)       │
│                    │ writes through                                       │
│               EditorDocument (locked mutable text; atomic snapshots)      │
│                 └ LineIndex (shared, incrementally updated line starts)  │
│ IO            TextIO (decode/encode, BOM, encoding detection)            │
│                                                                          │
│ Formats       DocumentFormat ── FormatRegistry (immutable, injected)     │
│                 • id, content types                                      │
│                 • highlightRules + optional StatefulScanner              │
│                 • makePreviewRenderer()                                  │
│               FormatPreferenceStore (explicit choice per file URL)       │
│ Highlighting  Tokenizer → Token(range, kind)   (pure, platform-neutral)  │
│               MarkdownScanner / HTMLScanner (scanner protocol)           │
│               EditorTheme: TokenKind → fonts/colours (AppKit)            │
│               StorageHighlighter: applies tokens to NSTextStorage        │
│               DirtyRange: accumulates pending edits for debouncing       │
│ Preview       PreviewRenderer → MarkdownHTML / LaTeXHTML → PreviewPage   │
└──────────────────────────────────────────────────────────────────────────┘
```

Data flow while typing:

1. `NSTextView` edits its text storage.
2. The storage delegate reports the edit → `DirtyRange` accumulates it → after an
   80 ms debounce `StorageHighlighter` re-colours **only the touched lines**.
   The tokenizer works on `NSTextStorage.mutableString` and copies only the
   dirty-line substring; stateful scanners search for candidate delimiters with
   a chunked `memchr` scan instead of materialising a line string per line. The
   Markdown/HTML state is resumed from the nearest cached checkpoint and every
   edit invalidates the checkpoints at and after it.
3. The storage delegate applies only the replacement range to the document's
   locked `NSMutableString`, increments a cheap published revision, and tells
   `ModEditDocument` about the change so autosave and the edited indicator see it.
4. SwiftUI re-evaluates `EditorRootView`; after a 250 ms debounce `PreviewPane`
   takes one immutable snapshot on the main actor, renders the HTML on a detached
   task, skips identical output, and restores the scroll position. Fast typing
   therefore does not copy the complete file for every keystroke. Documents over
   5 MB are not copied at all; the preview shows a size notice.
5. Selection changes update the status bar's one-based `line:column` location.
   A successful write records the exact saved generation; the document becomes
   clean only when no newer edit exists.

Navigation uses one cached UTF-16 line-start index owned by the document. Both
the status bar and the gutter query it, so they cannot disagree. The index is
updated incrementally on every edit: only the edited line window is rescanned,
later starts are shifted by the edit delta, and line/column lookup is binary
search rather than a scan from the beginning. The gutter still asks the layout
manager only for visible line fragments.

## Formats

| Format     | Types                         | Colouring                                      | Preview |
|------------|-------------------------------|------------------------------------------------|---------|
| PL/0       | `io.github.hakkabon.pl0-source` | keywords, numbers, operators, comments       | workbench |
| Plain Text | `public.plain-text`, UTF-8    | —                                              | —       |
| Markdown   | `net.daringfireball.markdown` | headings, bold, links, quotes, lists, code     | yes     |
| LaTeX      | `org.tug.tex`                 | commands, arguments, math, comments            | yes     |
| HTML       | `public.html`                 | tags, attributes, strings, comments            | yes     |

The format is chosen from the file's type on open and can be changed from the
status-bar picker (which also lets you pick a format for a new, untitled
document). An explicit choice is remembered for that file's URL and wins over
the extension when it is reopened; unknown or removed formats are ignored.
XML, JSON and YAML open as plain text.

> `UTType.markdown` only exists in the macOS 27 SDK, so Markdown is imported by
> identifier (`UTType(importedAs:)`) and declared in `Info.plist`.

## The preview

Previewed files are *untrusted input*, so the preview is hardened:

* the web view runs with **JavaScript disabled** and a **non-persistent data
  store**, so previews leave no cookies or cache behind;
* **navigation is blocked** — only the initial in-memory load is allowed.
  Clicked `http`, `https` and `mailto` links open in your browser or mail client;
  every other scheme and every document-initiated navigation (redirect, form,
  frame) is cancelled. Link previews and back/forward gestures are disabled;
* all text is **HTML-escaped** before markup is added; raw HTML in a Markdown or
  LaTeX file is shown as text;
* Markdown link destinations are parsed with balanced parentheses and escaped
  before insertion, so emphasis cannot rewrite a URL. Only `http`, `https` and
  `mailto` become links; `javascript:`, `data:` and `file:` stay literal text;
* generated pages and user HTML files carry the same **Content-Security-Policy**:
  no scripts, frames, objects, forms or connections, and no remote loads
  (`data:` images and fonts still work). The policy is injected into a user
  document's `<head>`, after `<html>`, after a doctype, or before a fragment.

Earlier versions inserted LaTeX source into the page unescaped (so a `.tex` file
containing `<script>` would execute it) and parsed Markdown links with a regular
expression that mishandled URLs containing `*` or parentheses.

Rendering is kept off the main actor: after the debounce the pane snapshots the
document on the main actor, the format's renderer transforms it on a detached
task, and only the finished HTML returns to the main actor for the `WKWebView`
load and scroll restoration. A superseded render is cancelled, and identical
output is skipped before the web view is touched.

## PL/0 parsing workbench

Open [`Examples/squares.pl0`](Examples/squares.pl0), choose **PL/0** in the
status-bar format menu, or press the **Parsing Workbench** toolbar button from
any document. The toolbar button selects PL/0 when necessary; once PL/0 is
active it toggles the right-hand workbench.

The first implementation is a deliberately small vertical slice:

* `PL0Language` is a separate, platform-neutral Swift target. It does not import
  AppKit or know about ModEdit.
* `SourceSnapshot` carries a document version, text and optional `SourceEdit`.
  Public ranges use UTF-16, matching TextKit and LSP.
* `PL0Lexer` recognizes classic PL/0 plus `//` and `/* ... */` comments. The
  stateful `PL0IncrementalTokenizer` preserves identities for reusable tokens.
* `PL0Frontend` selects **Reference LL**, generated **SLR(1)** or **Earley**.
  `PL0ParserProtocol` is their common immutable input/output contract. LR emits
  its native reduction tree. Earley retains a shared packed forest keyed by
  grammar symbol and token span, then projects one alternative as its CST.
* `PL0LanguageSession` retains lexer and parser caches for one versioned
  document. Successful blocks, statements, conditions, expressions, terms and
  factors can be reused without invoking their grammar productions again. LR
  resumes from its last stable state/node-stack checkpoint; Earley reuses closed
  chart columns and their packed forest nodes before the first changed token.
* `ConcreteSyntaxTree` combines grammatical nodes with an ordered concrete
  terminal stream. Terminals are explicitly classified as source, missing
  (inserted) or skipped (deleted), so repairs remain inspectable in the tree.
* `RecoveryModel` exposes ordered events, expected terminals, linked diagnostic
  IDs, insertion/deletion counts and an additive cost. The older `root`,
  `recoveryActions` and `expectations` result properties remain compatibility
  views over these first-class models.
* The reference engine declares deterministic-tree, recovery and expected-token
  capabilities. Diagnostics carry expected terminal sets, while compound
  statements and expressions synchronize past bad tokens so later syntax is
  retained instead of being discarded in a cascade.
* `PL0Formatter` rejects recovered syntax, preserves `//` and `/* ... */`
  comments, emits deterministic two-space indentation and is idempotent.
* `PL0Compiler` lowers the controlled grammar to lexical-addressed bytecode.
  `PL0VirtualMachine` executes integer arithmetic, conditions, loops, nested
  procedures and recursion with checked arithmetic and an instruction limit.
* `PL0LSPAdapter` is a transport-neutral, multi-document language service. It
  accepts full or ranged LSP changes, rejects stale versions and provides
  parser plus semantic diagnostics, scope-aware completion, go-to-definition
  and semantic tokens. Positions are zero-based UTF-16 line/character pairs.
* `GrammarWorkbenchHotReloadSession` speaks Grammar Workbench's published
  schema-1 JSON-lines protocol without linking ModEdit to Workbench packages.
  It retains one document session, sends UTF-16 edits and atomically activates
  valid grammar replacements while keeping the last good revision on failure.
* Parsing starts 120 ms after an edit on a detached task. A result is displayed
  only if its version still matches the document revision.

The parser menu switches engines for the current document. The **Compare** tab
shows acceptance, consumed tokens and LR action/stack or Earley chart-item
metrics side by side. The **Trace** tab exposes LR shift/reduce/state-stack
events or Earley predict/scan/complete/chart events, including incremental
reuse. The Problems tab shows diagnostics; Recovery shows the ordered repair trace and
cost; Tokens shows lexer locations and classifications; CST shows grammatical
nesting followed by the recovered terminal stream. The header reports snapshot
version, token count, scanned UTF-16 length, lexer reuse, parser node/token reuse
and lexer+parser time.

### Grammar Workbench hot reload

Build `grammar-workbench-service`, then launch ModEdit with these environment
variables (absolute paths are recommended):

```sh
MODEDIT_GRAMMAR_WORKBENCH_SERVICE=/path/to/grammar-workbench-service \
MODEDIT_PL0_GRAMMAR=/path/to/ModEdit/Examples/PL0.grammar \
swift run ModEdit
```

The **Grammar WB** tab reports connection state, grammar and document
revisions, parse status, token count and diagnostics. ModEdit polls the grammar
file's modification date twice per second. A saved change triggers
`sessionReplaceGrammar`; Grammar Workbench recompiles the grammar and reanalyzes
the retained PL/0 document. Invalid replacements are reported but do not replace
the active grammar. Editor changes are sent through `documentChange` as
revisioned UTF-16 edits. **Reload Now** is available for an explicit refresh.

The repository includes [Examples/PL0.grammar](Examples/PL0.grammar), validated
against Grammar Workbench as 43 productions and 29 terminals.

The source editor projects the current result directly onto the text: errors and
warnings are underlined, missing tokens receive an orange insertion marker, and
skipped tokens are tinted and struck through. These are TextKit temporary
attributes, not document attributes, so they never affect undo, syntax colours
or saved bytes. Clicking a Problem, Recovery event or Token reveals and selects
its UTF-16 range in the editor. The status bar reports problem and repair counts.
Every visualization is tagged with its document version; edits remove the old
markers immediately and late parser results are rejected.

**Format** rewrites the document through the live text view, so the operation is
an ordinary dirty, undoable editor change. **Run** compiles and executes on a
detached task. The Run tab reports global values, instruction count, maximum
operand-stack depth and a source-linked bytecode listing. Syntax/semantic
failures, division by zero, integer overflow and the instruction safety limit
are displayed as controlled failures rather than crashing or blocking the UI.

For an edit, tokenization keeps tokens strictly before a safe token boundary,
then scans from that boundary until a newly produced token aligns with the
unchanged old suffix. Remaining tokens retain their identities while their
ranges and line/column locations are relocated. Edits carry the version they
apply to; if UI debouncing skips an intermediate revision, the session performs
a safe full scan. Tests compare every result in multi-edit sequences with a
fresh full tokenization, including token-boundary merging, newline relocation,
invalid characters and unterminated block comments.

Parser cache entries are keyed by grammar rule and the first stable token ID.
Reuse requires an exact match for every consumed token ID and the following
lookahead token ID. A reused subtree keeps its syntax identity and all of its
ranges are relocated when an earlier edit changes source offsets. Regions that
produced a diagnostic, recovery action or expectation are deliberately not
cached, so malformed input is parsed and recovered again instead of preserving
stale errors. If document versions skip, full tokenization also clears the
parser cache, so reuse safely falls back to zero. The program root and any
invalidated ancestor paths are rebuilt on every edit.

The reference-parser test corpus covers every controlled grammar production,
direct-parser/frontend equivalence, expected terminals, missing-token insertion,
garbage deletion, recovery that preserves later statements, and bounded
termination across malformed fragment combinations. It is intended to be the
correctness oracle for the other parser implementations, not the eventual
high-performance parser.

```ebnf
program     = block "." ;
block       = [ "const" ident "=" number { "," ident "=" number } ";" ]
              [ "var" ident { "," ident } ";" ]
              { "procedure" ident ";" block ";" } statement ;
statement   = ident ":=" expression | "call" ident
            | "begin" statement { ";" statement } "end"
            | "if" condition "then" statement
            | "while" condition "do" statement | empty ;
condition   = "odd" expression | expression relation expression ;
expression  = [ "+" | "-" ] term { ( "+" | "-" ) term } ;
term        = factor { ( "*" | "/" ) factor } ;
factor      = ident | number | "(" expression ")" ;
relation    = "=" | "#" | "<" | "<=" | ">" | ">=" ;
```

## Language experiment protocol

`LanguageExperimentProtocol` is a standalone Swift library target containing
the versioned, transport-neutral integration contract for ModEdit,
Grammar-REPL, Grammar-Workbench, parser engines, language servers and compiler
experiments. It deliberately has no dependency on PL/0, AppKit, or any parser
implementation.

Schema version 1 records:

* exact document revision, full source, coordinate space and FNV-1a fingerprint;
* grammar artifact identity, revision, notation, normal form and optional
  normalized-to-source production provenance;
* stable token identities, spelling, channel and source ranges;
* requested and effective parser engines, including an explicit fallback reason;
* completed/limited/cancelled/failed operation disposition and semantic parse status;
* diagnostics and ordered recovery edits with costs and diagnostic links;
* separate token, parser-state, syntax, chart, forest and semantic reuse dimensions;
* typed measurements and a syntax fingerprint; and
* deterministic, schema-checked JSON experiment bundles containing one engine
  comparison or an entire edit sequence.

The PL/0 adapter is in
`Sources/PL0Language/PL0ExperimentContract.swift`. It projects existing
`ParseResult` values without changing the parser API. In particular, malformed
LR or Earley input is recorded as a request for that engine whose effective
result came from reference LL recovery; recovery is not incorrectly attributed
to the requested recognizer.

```swift
import LanguageExperimentProtocol
import PL0Language

let source = SourceSnapshot(version: 1, text: "begin call p end.")
let result = PL0Frontend(engine: .generatedLR).parse(source)
let grammarText = try String(contentsOfFile: "Examples/PL0.grammar")
let grammar = try PL0ExperimentContract.grammarArtifact(source: grammarText)
let run = try result.experimentRun(
    snapshot: source,
    documentURI: "file:///experiment.pl0",
    grammar: grammar)
let bundle = try PL0ExperimentContract.bundle(
    id: "pl0-first-run", title: "PL/0 parser experiment", runs: [run])
let json = try bundle.json()
```

See [Language Experiment Protocol](Docs/LanguageExperimentProtocol.md) for the
field model, invariants and ecosystem adoption path.

## Adding a format

1. Create a type conforming to `DocumentFormat` (see `MarkdownFormat.swift`):

   ```swift
   struct TOMLFormat: DocumentFormat {
       let id = "toml"
       let displayName = "TOML"
       let contentTypes: [UTType] = [UTType(importedAs: "org.toml")]
       let fileExtensions = ["toml"]

       // Lowest priority first: later rules win where they overlap.
       var highlightRules: [HighlightRule] {
           [
               HighlightRule(#"^\s*\[[^\]\n]+\]"#, .heading),
               HighlightRule(#""[^"\n]*""#, .string),
               HighlightRule(#"#.*$"#, .comment),      // opaque rules last
           ]
       }
       func makePreviewRenderer() -> (any PreviewRenderer)? { nil }
   }
   ```
2. Add it to the `FormatRegistry` passed to `EditorDocument`/`ModEditDocument`.
   The app's default is `FormatRegistry.standard`; tests often build their own.
3. If the syntax has constructs that span lines, implement `StatefulScanner`
   and return an instance from `var scanner` (see `MarkdownScanner` and
   `HTMLScanner`). The default is `nil`, which uses only the regex rules.
4. Declare the type in `Info.plist` (`UTImportedTypeDeclarations` and
   `CFBundleDocumentTypes`) if the system does not know it. AppKit asks for
   document types on the class before a document exists, so also add the format
   to `FormatRegistry.standard` for Finder registration.
5. Add tests: `FormatTests.swift` already checks that **every** shipped rule
   compiles, so a typo cannot silently disable highlighting.

Explicit format choices are persisted per file URL by
`FormatPreferenceStore`; saved IDs are validated against the document's
registry before use.

A new preview is a `PreviewRenderer` returning an HTML string; wrap bodies with
`PreviewPage.wrap(body:)` and escape text with `HTMLEscaping.escape`.

## Project layout

```
Package.swift
scripts/make-app.sh                 build ModEdit.app
scripts/package-release.sh          build and zip the release app
scripts/benchmark-large-files.sh    run the 10/50 MB benchmark
scripts/benchmark-pl0.sh            run the LL/LR/Earley benchmark
Sources/
  LanguageExperimentProtocol/      versioned cross-tool experiment contract
  PL0Language/                     lexer/parser, CST, formatter, VM and LSP adapter
  ModEditApp/                       @main entry point, Info.plist
  ModEditCore/
    ModEditApplication.swift        AppKit application, delegate and main menu
    Model/ModEditDocument.swift     NSDocument shell and window controller
    Formats/                        DocumentFormat, FormatRegistry, PreferenceStore, formats
    Highlighting/                   Token, Tokenizer, scanners, DirtyRange, EditorTheme, StorageHighlighter
    IO/TextIO.swift
    Model/                          EditorDocument, EditorModel, LineIndex, LineNumberSource
    Preview/                        PreviewRenderer, MarkdownHTML, LaTeXHTML, escaping, page
    Workbench/                      PL/0 parser inspector
    UI/                             root/status bar, editor/gutter, preview
Tests/ModEditTests/                 Swift Testing suites
Tests/PL0LanguageTests/             lexer/parser/recovery contract tests
Tests/LanguageExperimentProtocolTests/ schema and JSON compatibility tests
Examples/squares.pl0                sample controlled-language program
.github/workflows/ci.yml            debug + release build, tests and packaged artifact
```

## Design decisions

* **Semantic tokens, not AppKit attributes, in formats.** Formats say *what* text
  is (`TokenKind`); `EditorTheme` says how it looks. Formats become pure,
  `Sendable` and testable; theming is one file.
* **One adaptive theme, explicit light and dark palettes.** `EditorTheme` builds
  dynamic `NSColor`s from both palettes, so AppKit resolves the right colours
  when it draws and an appearance switch needs no re-highlighting. The editor
  background, current-line fill, gutter, caret and every token kind come from
  the same theme.
* **Soft wrapping is a layout concern, not a document concern.** Line numbers
  come from the shared logical `LineIndex`, so a wrapped line is numbered once.
  Current-line drawing asks TextKit for every visual fragment of the caret's
  logical line instead of assuming one fragment per line.
* **Encoding and BOM are part of the document snapshot.** Saving replays the
  exact UTF-16 byte order and BOM state that was read. UTF-16 is decoded before
  UTF-8 when its zero-byte pattern is unambiguous, because ASCII UTF-16 is also
  valid UTF-8 containing NULs.
* **Immutable registry, injected where it is used.** No registration step to
  forget or race. `EditorDocument`, `EditorModel`, `ModEditDocument` and the
  status-bar picker take a `FormatRegistry`, so tests can supply a small one
  instead of depending on `.standard`.
* **Formats carry an optional scanner, not a mode enum.** A `StatefulScanner`
  owns its own state type and is layered around the regex rules. Adding a
  syntax with multiline constructs means implementing the protocol (and
  choosing which tokens go before or after the regex pass), not adding another
  branch to the tokenizer.
* **Explicit format choices survive reopening.** `FormatPreferenceStore`
  records the chosen format ID against the standardized file URL, and the
  saved ID is validated against the document's registry. This is separate from
  the file's type: a `.txt` note can stay Markdown across launches.
* **Document shell vs. buffer split.** `NSDocument` owns windows, save panels,
  undo change counts and the disk write. The persisted text stays in a
  lock-protected buffer that hands out immutable snapshots, while UI state lives
  in a `@MainActor` model. This keeps saving off the main thread without racing
  ongoing typing.
* **Success means the write finished.** SwiftUI's `ReferenceFileDocument` exposes
  no post-write callback, so save success is recorded only in `NSDocument`'s
  save completion handler. A failed or interrupted write leaves the document
  dirty, and an older completed save cannot mark newer edits clean.
* **Rules are ordered by priority** ("later wins") so comments and code spans
  reliably override anything matching inside them.
* **State machines for multiline syntax live behind a protocol.** Markdown
  fences and HTML tags/comments implement `StatefulScanner`; regex rules remain
  useful for local tokens. Tokens are clipped to the dirty lines before AppKit
  attributes change.
* **No whole-document copies on hot paths.** A local highlight pass reads
  `NSTextStorage.mutableString`, copies only the dirty-line substring for the
  regex rules and scans for fence/tag candidates with a chunked `memchr` window.
  The line index is updated in place. Full snapshots exist only for saving and
  small previews; the preview refuses documents above 5 MB.
* **One incremental state machine per pass.** A full-document highlight splits on
  line boundaries and carries one `Tokenizer.State` between chunks, so Markdown
  fences and HTML tags/comments are scanned once instead of re-reading the
  prefix per chunk. Each chunk boundary also caches a line-aligned checkpoint;
  a later dirty-line pass resumes from the nearest checkpoint at or before the
  edit. Checkpoints at and after a character edit are discarded. If an edit
  lands mid-pass, the pass restarts because the carried offsets are stale; the
  edit itself is coloured immediately by the debounced local pass.
* **Preview rendering is off the main actor.** The preview snapshots the source
  on the main actor, renders Markdown/LaTeX/HTML on a detached task, then
  returns to the main actor for the `WKWebView` load and scroll restoration.
  Cancellation is forwarded to the detached render, and identical HTML is
  skipped before the web view is touched.
* **One shared incremental line index.** The document owns the UTF-16 line
  starts. A text edit rebuilds only the affected line window and shifts the
  remaining starts; the status bar and gutter both read that index instead of
  maintaining their own copies.
* **Generation-based view synchronization.** Editor-originated mutations record
  the document generation immediately. A different generation is treated as an
  external replacement and pulled into the text view, covering reload/revert.
* **Generation-based save status.** Save snapshots carry their source generation.
  A completed older autosave cannot incorrectly mark a newer edit clean.
* **Small public surface.** Only `ModEditApplication` is public.
* **Language engine outside the editor.** `PL0Language` exposes immutable,
  `Sendable` snapshots and results. ModEdit is one client; command-line and LSP
  executables can consume the same engine later.
* **Recovery is data.** Insertions and deletions are explicit result values,
  making recovery observable, testable and suitable for editor code actions.
* **Parser visualization is ephemeral.** Diagnostics and recovery markers use
  temporary layout attributes and a revision-bound presentation model. They do
  not enter text storage, undo registration or persistence.

## Known limitations

* **Partial language grammars.** The stateful scanner handles multiline Markdown
  fences and HTML tags/comments, but it is not a complete CommonMark or HTML
  parser (for example, tilde fences and embedded languages are not recognised).
* **Preview is a separate pane.** The caret and scroll position are not
  synchronised with the source.
* **Markdown subset only** (no nested lists, tables, images, setext headings).
  **LaTeX subset only** (no environments, `\frac`, `\sqrt`, macros).
* **HTML preview cannot load relative resources** (images, CSS) yet. The
  `NSDocument` shell now exposes the document URL, so supplying it as the web
  view's base URL is a natural next step.
* **Live preview is capped at 5 MB.** Larger documents remain editable and
  savable; the preview pane shows a notice instead of copying and rendering
  them.
* **Edits still move suffix bytes.** The document uses `NSMutableString`, so it
  avoids a second full-file model copy but insertion near the beginning of a very
  large file remains O(n). A piece table or rope is the next scaling step.
* **Checkpoint recovery is bounded, not zero.** A local highlight pass resumes
  from the nearest scanner checkpoint, normally the previous full-pass chunk
  (about 32–50k UTF-16 units). An edit near the top of the document invalidates
  every later checkpoint, so a later edit far from it replays the prefix once
  (about 115 ms on a 50 MB Markdown file). Subsequent passes reuse the new
  checkpoint. The initial full pass over that file takes about 18 s, in
  cancellable chunks that yield so editing stays responsive.
* **BOM-less UTF-16 detection is conservative.** Files without a BOM are
  recognised when their zero-byte pattern is unambiguous (typically ASCII or
  Latin text). Other UTF-16 files should carry a BOM; otherwise they may be
  interpreted as a legacy single-byte encoding.
* **Status columns use UTF-16 offsets.** This matches AppKit and LSP position
  accounting, but a grapheme such as a composed emoji can occupy several columns.
* **macOS only.** Core depends on AppKit, SwiftUI and WebKit.
* **Parser reuse is conservative and region-based.** The reference LL parser
  memoizes successful grammar regions; it does not yet incrementally repair an
  individual production or reuse recovered subtrees. Invalidated ancestor paths
  and the program root are rebuilt.
* **The PL/0 CST is normalized, not trivia-preserving.** It retains every lexer
  token plus missing and skipped recovery terminals, but whitespace and comments
  are currently discarded by the lexer. A future lossless-token mode can add
  trivia without changing the grammatical node or recovery contracts.
* **The PL/0 VM is deliberately small.** Values are checked machine integers;
  the controlled grammar has no input/output statement, so execution results
  currently expose final global variables rather than a console stream.
* **The LSP layer is transport-neutral.** It intentionally does not own stdin,
  sockets or JSON-RPC framing. `PL0LSPAdapter` can be called directly by
  ModEdit and wrapped by a small standards-facing server without coupling the
  language engine to one process model. Semantic analysis continues over a
  recovered token stream, so useful results remain available while typing.
* **Recovery remains normalized.** On valid input LR builds a native reduction
  tree and Earley projects its packed forest. When either engine rejects the
  current, incomplete program, the reference recovery adapter supplies the
  common missing/skipped-terminal model. Incremental reuse is therefore native
  for successful LR/Earley prefixes but recovery-region reuse remains future
  experimental work.
* **Grammar Workbench is opt-in and out-of-process.** ModEdit does not build,
  locate or launch an unspecified Workbench binary automatically. Both paths
  must be supplied through environment variables. The bundled external grammar
  currently skips whitespace and `//` comments; ModEdit's native lexer also
  supports block comments.

## Roadmap

The first ecosystem-integration phase is complete in ModEdit: the shared
language experiment schema, deterministic bundle format, PL/0 adapter, fallback
disclosure and reuse/recovery evidence are implemented. Adoption by the sibling
repositories and embedding Parser's portable semantic/operational snapshots are
the next cross-repository steps.

1. **Parser comparison laboratory.** Extend the connected LL, SLR(1) and Earley
   traces with stepping and forest visualization; then connect Earley-table,
   CYK and RNGLR with recovery-cost and full-versus-incremental differential
   tests.
2. **Finer incremental parsing.** Add declaration-level reuse, dependency-aware
   invalidation, recovered-region reuse experiments, mutation minimization and
   grammar-aware mutation operators. The seeded raw-edit differential campaign
   already checks every incremental result against a fresh full parse.
3. **Standards-facing LSP transport.** Wrap the implemented, version-safe
   `PL0LSPAdapter` in JSON-RPC framing, add initialize/capability negotiation,
   cancellation and the standard delta-encoded semantic-token wire format.
4. **Rendering inside the editor.** Introduce a
   platform-neutral `TextRenderer` that emits *runs tiling the source exactly*
   (hidden markup = zero-width run) with a two-way source↔display offset map;
   draw the rendered form for everything except the line under the caret using
   TextKit 2 layout fragments or text attachments. The offset map is what lets
   the caret move through rendered text.
5. **Scroll and caret synchronisation** between source and preview (needs the
   same source map).
6. **Real markup parsers:** `swift-markdown` for CommonMark/GFM and a bundled KaTeX for
   typeset maths; expand stateful highlighting to embedded languages.
7. **Relative resources in the preview**, using the document URL as the web
   view's base URL.
8. User-selectable themes, font and size settings; soft-wrap toggle.
9. Export (HTML/PDF) from the preview.

## Contributing

* Keep formats free of AppKit types; put visual choices in `EditorTheme`.
* Every behaviour change needs a test (`swift test` must pass).
* Escape anything inserted into HTML (`HTMLEscaping.escape`).
* Document non-obvious decisions with `///` comments, especially invariants.

## License

See [LICENSE](LICENSE).
