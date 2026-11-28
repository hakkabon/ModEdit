# ModEdit

A native macOS text editor for **editing text that renders differently from its
plain-ASCII source**. You type Markdown or LaTeX on the left; a live preview on
the right shows it as headings, emphasis, symbols and mathematics.

**Current version:** <!-- VERSION -->0.41.0 (build 4100)<!-- /VERSION --> · [Versioning and releases](Docs/Versioning.md)

> **Status: active development.** The editor, syntax colouring, format
> switching, file open/save and the live preview work end to end for Plain Text,
> Markdown, LaTeX and HTML. A PL/0 language workbench provides a reference
> lexer/parser with incremental token and syntax-tree reuse, explicit recovery
> traces, CST inspection, semantic analysis, a compiler/VM and a ten-engine
> comparison.
> Hybrid rendered editing is available for Markdown: markup outside the caret
> line is collapsed in place while the caret line remains literal, editable
> source. Entities, escapes, bullets, thematic breaks and inline-code delimiters
> show their rendered glyphs, standalone local and `data:` images are drawn as
> attachments, and missing glyphs use Core Text font fallback. Rendered editing
> and the Markdown preview now share one `RenderedText` projection, so setext
> headings, nested and task lists, tables, strikethrough and block-quote lists
> appear in the preview too. The preview follows the caret line, and scrolling
> the preview reveals the matching source block without moving the caret.
> Relative images, styles and fonts resolve against the document's directory,
> including after Save As. See the [roadmap](#roadmap).

## Table of contents

1. [Features](#features)
2. [Requirements](#requirements)
3. [Build, run, test](#build-run-test)
4. [Architecture](#architecture)
5. [Formats](#formats)
6. [The preview](#the-preview)
7. [PL/0 parsing workbench](#pl0-parsing-workbench)
8. [Language experiment protocol](#language-experiment-protocol)
9. [Fine-grained incrementality](#fine-grained-incrementality)
10. [Adding a format](#adding-a-format)
11. [Project layout](#project-layout)
12. [Design decisions](#design-decisions)
13. [Known limitations](#known-limitations)
14. [Roadmap](#roadmap)
15. [Contributing](#contributing)
16. [License](#license)

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
* **Rendered editing** for Markdown (toolbar and status-bar toggle): markup
  outside the caret line is collapsed in place, headings and emphasis are styled,
  and the caret line stays literal source. Display-only content uses glyph
  substitution: entities and escapes show their decoded character, bullets use
  `•`, thematic breaks use a rule, and inline-code delimiters disappear.
  Standalone local and `data:` images are drawn over their source line as
  attachments, while inline images keep their alt text. If the editor font lacks
  a display glyph, Core Text selects a fallback font rather than drawing a blank
  box. The source in `NSTextStorage` is unchanged, so offsets, find, undo and
  saving behave exactly as in source mode, and the caret moves through display
  positions across collapsed markup. Edits reuse unchanged projection blocks;
  documents above 512 KB stay in source mode.
* **Live preview** (WebKit) that keeps its scroll position while you type. For
  Markdown it follows the caret's source line, and scrolling the preview reveals
  the matching block in the editor without moving the caret. Documents above
  5 MB show a notice instead of being copied and rendered:
  * *Markdown* — setext and ATX headings, paragraphs, nested and task lists,
    block quotes, tables, fenced code, `**bold**`, `*italic*`, `~~struck~~`,
    `` `code` `` and links (including URLs with balanced parentheses such as
    `/wiki/Foo_(bar)`). Local images resolve against the document's directory
    and `data:image` payloads work in any document; remote and unsafe image
    destinations keep their alt text.
  * *LaTeX* — `\section`, `\textbf`, `\emph`, math with Greek letters and
    operators (`\alpha` → α), super/subscripts (`x^2`, `x_{i}`), comments hidden.
  * *HTML* — your page as written, with scripts, frames and remote loads
    disabled by the preview policy. Local images, styles and fonts resolve
    against the document's directory.
* **Preview export** (File > Export as HTML… / Export as PDF…): renders the
  same page as the live preview and writes it through a save panel. HTML keeps
  the preview's escaped body and, for user HTML documents, the injected
  Content-Security-Policy. PDF runs an offscreen WebKit view with the same
  no-JavaScript, non-persistent and navigation-restricted configuration.
  Export is available for formats with an HTML preview and follows the same
  5 MB source cap.
* **Encoding-faithful I/O**: UTF-8 (with/without BOM), UTF-16 little- and
  big-endian (with BOM, plus unambiguous BOM-less ASCII/Latin text), and
  detected legacy encodings are written back with the same encoding. UTF-16
  byte order and the presence or absence of a BOM are preserved, so saving
  never silently replaces characters or changes the file's byte layout.
* Light/dark mode aware: `EditorTheme` has explicit light and dark palettes for
  text, syntax, gutter and current-line colours; preview pages use
  `color-scheme` so they follow the system appearance too.
* **App-wide editor settings** (Settings…, <kbd>Cmd</kbd>-<kbd>,</kbd>):
  System, Light or Dark appearance; System Monospaced, Menlo or Monaco font;
  10–24 pt text; and a soft-wrap toggle that is also available as
  View > Soft Wrap. Every open editor updates immediately, rendered-editing
  text uses the chosen family and scales headings from the chosen size, and the
  one versioned settings blob is restored on launch. Invalid or corrupt values
  fall back to the defaults.
* Experimental **PL/0 language workbench**: native `.pl0` documents, incremental
  UTF-16 tokenization and reference LL parsing with identity reuse, robust error
  recovery, a parser-neutral CST with source/missing/skipped terminals,
  Tokens and CST views, reuse metrics and source-editor
  visualization of diagnostics and repairs. A deterministic formatter and
  bounded bytecode VM turn the workbench into a small executable PL/0 IDE.

## iPad prototype

A native DOT editor for iPadOS 17 is available in [iPad](iPad/README.md).
It uses the existing language services and Swift-Layout graph preview with
a SwiftUI document browser and UIKit source editor.

## Requirements

* macOS 13 or newer
* Swift 6.1 / Xcode 16.3 or newer
* No third-party UI frameworks. Runtime libraries are pinned SwiftPM packages
  from the hakkabon ecosystem, plus `swift-markdown` 0.6.0 and its `swift-cmark`
  0.9.0 parser. The external pair is pinned exactly because `swift-markdown`
  0.7.x requires Swift 6.2; ModEdit builds with Swift 6.1.

## Build, run, test

```sh
swift build
swift test                      # macOS only: the module uses AppKit/SwiftUI/WebKit

scripts/make-app.sh             # builds .build/.../ModEdit.app (debug)
scripts/make-app.sh release     # release build
scripts/package-release.sh      # release .app + dist/ModEdit-<version>-macos.zip
scripts/version.sh check        # verify Version.json and generated metadata agree
scripts/verify-ecosystem-versions.sh  # check tag graph and dependency pins
scripts/verify-clean-checkout.sh      # pre-release build in a temporary copy
open "$(swift build --show-bin-path)/ModEdit.app"
```

The current source is verified with `swift build` and `swift test` (the full
editor test suite; the PL/0 language package maintains its own conformance
suite) using Swift 6.1.2 and the macOS 15.5 SDK. CI builds and tests both debug and
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
../PL0-LanguageKit/scripts/benchmark-pl0.sh
# equivalent to:
# cd ../PL0-LanguageKit && PL0_BENCHMARK=1 swift test -c release --filter PL0ParserBenchmark
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
PL0-LanguageKit package (platform-neutral library)
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
│                       └ PL0WorkbenchPane (Tokens/CST/Compare/Trace/Run)   │
│                         └ PL0WorkbenchAdapter (snapshot/result boundary)  │
│                 status bar       └ LineNumberRulerView       (WKWebView) │
│                    │                  │  ▲ edits           (WKWebView)    │
│ Model         EditorPreferences (persisted appearance/font/wrap)         │
│               EditorModel (@MainActor, @Published revision/format)       │
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
│ Preview       PreviewRenderer → RenderedHTML / LaTeXHTML → PreviewPage   │
│ Export        PreviewExport → PreviewPDFExporter (offscreen WKWebView)   │
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
   therefore does not copy the complete file for every keystroke. The document
   directory is forwarded as the web view's base URL, and a Save As reloads even
   unchanged HTML so relative resources re-resolve. Documents over 5 MB are not
   copied at all; the preview shows a size notice.
5. Selection changes update the status bar's one-based `line:column` location.
   A successful write records the exact saved generation; the document becomes
   clean only when no newer edit exists.

Navigation uses one cached UTF-16 line-start index owned by the document. Both
the status bar and the gutter query it, so they cannot disagree. The index is
updated incrementally on every edit: only the edited line window is rescanned,
later starts are shifted by the edit delta, and line/column lookup is binary
search rather than a scan from the beginning. The gutter still asks the layout
manager only for visible line fragments.

The PL/0 workbench is a visualization client. `PL0WorkbenchAdapter` is its only
language-service boundary: it sends versioned snapshots to `PL0-LanguageKit`
and projects recognition summaries for SwiftUI. Lexing, parsing, recovery,
semantic analysis, compilation, execution and engine comparison remain owned
by the language kit and parser packages; ModEdit owns no parser state machine.

### RenderedText projection

`RenderedText` is a platform-neutral library product in the same package. It
wraps swift-markdown and projects a Markdown document into display runs that
tile the source exactly: hidden markup becomes a zero-width run, and
`SourceDisplayMap` maps UTF-16 source offsets to display offsets with leading
and trailing affinity. Blocks carry content-derived IDs, so an edit can reuse
unchanged blocks; `MarkdownRenderedText` reparses the document, swaps only the
invalidated range and shifts the retained runs. The projection handles
headings, paragraphs, lists, quotes, code, tables, HTML blocks, inline markup,
entities and hard/soft breaks.

`RenderedEditorPresentation` adapts that projection to the editor. It marks the
runs intersecting the caret line as raw and every zero-width run elsewhere as
collapsed, and it moves the caret by display position outside the caret line.
`RenderedEditorStyler` keeps collapsed characters in storage but clears their
colour and applies a per-character negative kern, reducing their advance to zero
without changing line height. Text edits call `MarkdownRenderedText.apply` so
only invalidated blocks are reparsed, while selection changes restyle just the
old and new caret lines.

Display-only runs do not change storage either. The coordinator's
`NSLayoutManager` delegate replaces source glyphs with the projection's display
glyphs and marks surplus source slots as null glyphs, so `&amp;` renders as one
cell containing `&`, a bullet source marker renders as `•`, and layout width
matches the source↔display map. Unsupported glyphs, line breaks and substitutions
longer than their source range keep the source spelling. When the editor font
has no glyph for a display character, `RenderedEditorStyler` asks Core Text for
a fallback font and applies it only to that substitution; `LastResort` is
rejected so an unmapped character never becomes a blank box. The WebKit preview
consumes the same projection through `RenderedHTML`; `MarkdownHTML` is a thin
adapter that owns escaping and the preview page's safety rules, not a second
Markdown parser. When the document has a directory, the preview emits local
images as `<img>` elements and lets the web view resolve them against that
directory; otherwise images remain alt text.

Standalone Markdown images are presentation attachments rather than a second
text buffer. `RenderedEditorImageCache` resolves relative destinations against
the document directory, accepts local files and `data:image` payloads, rejects
remote schemes and files over 32 MB, and caches decoded images. The coordinator
clears the source line's colour, reserves its height with a paragraph style, and
`EditorNSTextView` paints the scaled image (at most the available width and
320 pt high) after AppKit draws the text. Moving the caret onto the line removes
the attachment so the literal `![alt](path)` source is editable again. Inline
images and standalone images that cannot be resolved keep their alt text.

### Unified language providers

`FormatRegistry.standard` is provider-first. PL/0 enters as the external
`PL0Provider` exported by its language kit, while HTML, Markdown, LaTeX, and
plain text remain permanent bundled providers backed by ModEdit's scanners and
preview renderers. The status-bar picker enumerates the same provider interface
for both categories; Uniform Type Identifier and theme mapping remain host
presentation concerns. Every provider also conforms to Language-Tooling's
consumer-facing provider/session API. Bundled scanners project their native
spans as disjoint semantic tokens, while PL/0 delegates to its language-kit
session. The neutral lifecycle lives in `LanguageToolingDocument`, so neither
parser packages nor language kits depend on ModEdit.

Permanent distribution policy lives in the parser-free
`ModEdit-Bundled-Languages` package. ModEdit validates its standard registry
against that catalog. JSON, Grammar notation, Graphviz DOT, and CSS are active,
independently owned language kits consumed through the same document lifecycle.
HTML `<style>` and JSON script bodies, plus supported Markdown fenced blocks,
are now routed to those same providers through Language-Tooling's embedded-
region compositor. ModEdit owns region discovery and presentation, not another
embedded parser.

### Grammar authoring with examples

Open a BNF or EBNF grammar and show Preview. **Grammar examples** appears
below the railroad diagrams. Load an examples JSON corpus or add examples,
choose whether each input should be accepted, and edit the grammar normally.
Checks update after editing. Select an example to inspect its outcome or
accepted parse tree. Broken grammar drafts show diagnostics instead of
results from an earlier source revision.

Grammar files use the ordinary document Save command. **Save…** in Grammar
examples saves the example corpus separately and detects external file changes.
The corpus stays available when Preview is hidden and shown again.

The [FeatureFlags trial](Examples/FeatureFlags/README.md) includes five positive
and negative examples plus two broken drafts and a cross-consumer verification
script. Grammar-LanguageKit owns the shared check, which uses Grammar's parser,
Lexer's grammar-driven scanner, and LR-Parsing's native LALR runtime with
recovery disabled. ModEdit supplies the editing controls.

### Live DOT preview

Open a `.dot` or `.gv` file and use the Preview toolbar button to show or hide
the graph. Click a node to reveal its declaration or first reference in the
source. While an edit leaves the graph incomplete, the last drawable graph
stays visible and Problems shows diagnostics for the current text.

The preview uses Swift-Layout for flat directed and undirected graphs with
standalone nodes, chained edges, loops, and plain-text node and edge labels.
It recognizes `rankdir=LR` and uses a top-to-bottom layout by default. Other
styling attributes do not affect the preview. Clusters, subgraphs, ports,
HTML-like IDs and labels, and concatenated strings are outside the preview
subset. The preview accepts up to 65,536 UTF-16 units, 200 nodes, and 400 edges.

### Cross-front-end experiment conformance

`scripts/verify-cross-frontend-experiments.sh` runs the same accepted and
recovery PL/0 corpus through three separate executables: ModEdit's headless
adapter, Grammar-REPL, and Grammar-Workbench. Each emits the shared
`PL0FrontendExperimentReport` schema. The final comparison ignores timing and
front-end labels but requires identical grammar fingerprints, engine paths,
token evidence, diagnostics, recovery edits, parse status, and syntax
fingerprints. A mismatch exits nonzero and names the first divergent case.

The same script now also runs the Phase-16 product campaign through all three
executables and compares their host-independent evidence fingerprints. Run a
single ModEdit report with:

```sh
swift run modedit-experiment product-campaign modedit-product.json
```

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
XML and YAML open as plain text. JSON uses the bundled JSON LanguageKit.

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
* Markdown is parsed by `swift-markdown` and projected once into `RenderedText`
  blocks and runs; destinations are escaped before insertion, so emphasis cannot
  rewrite a URL. Only `http`, `https` and `mailto` become links; `javascript:`,
  `data:` and `file:` link destinations stay plain text. Image sources are
  limited to `data:image` payloads and local files in documents that have a
  directory; remote and unsafe image sources keep their alt text;
* generated pages and user HTML files carry the same **Content-Security-Policy**:
  no scripts, frames, objects, forms or connections, and no remote loads.
  `data:` and local `file:` subresources are allowed for styles, images, fonts
  and media so relative document assets load. The policy is injected into a user
  document's `<head>`, after `<html>`, after a doctype, or before a fragment.

Earlier versions inserted LaTeX source into the page unescaped (so a `.tex` file
containing `<script>` would execute it) and parsed Markdown links with a regular
expression that mishandled URLs containing `*` or parentheses.

Rendering is kept off the main actor: after the debounce the pane snapshots the
document on the main actor, the format's renderer transforms it on a detached
task, and only the finished HTML returns to the main actor for the `WKWebView`
load and scroll restoration. A superseded render is cancelled, and identical
output is skipped before the web view is touched.

The page is loaded with the document's directory as the `WKWebView` base URL.
Markdown emits local images only when such a directory exists, and user HTML
files can load relative stylesheets, images and fonts next to the file. Untitled
documents keep a `nil` base URL, so relative resources stay inert. The directory
is published by `EditorModel`, so Save As both re-renders and reloads the page
even when the HTML itself is unchanged.

Markdown previews also carry one-based `data-source-line` anchors on headings,
paragraphs, lists and their items, block quotes, tables, thematic breaks and
fenced code. They are emitted only by the trusted `RenderedHTML` projection when
`MarkdownHTML.render(..., sourceAnchors: true)` is called, and only Markdown
opts into scroll synchronisation, so anchors in untrusted user HTML are never
interpreted as source positions. After each load the pane injects a small scroll
bridge (page JavaScript stays disabled; app-injected scripts still run), applies
the caret's line, and debounces user scrolling back into an editor reveal. The
preview never moves the caret, and programmatic caret-following scrolls are
suppressed so they cannot feed back as user scrolls.

## PL/0 parsing workbench

Open [`PL0-LanguageKit/Examples/squares.pl0`](../PL0-LanguageKit/Examples/squares.pl0), choose **PL/0** in the
status-bar format menu, or press the **Parsing Workbench** toolbar button from
any document. The toolbar button selects PL/0 when necessary; once PL/0 is
active it toggles the right-hand workbench.

The workbench is built around a deliberately small parser vertical slice:

* `PL0Language` is supplied by the separate, platform-neutral
  `PL0-LanguageKit` package. It does not import AppKit or know about ModEdit.
* `SourceSnapshot` carries a document version, text and optional `SourceEdit`.
  Public ranges use UTF-16, matching TextKit and LSP.
* `PL0LanguageKit` compiles the bundled authoritative `PL0.grammar` resource
  into fingerprinted lexical and production artifacts. Token declarations feed
  `PL0Lexer`; productions feed the generated SLR and Earley engines. Typed token
  and nonterminal bindings are validated at load time, so grammar drift fails
  immediately rather than silently selecting the wrong symbols.
* `PL0Lexer` recognizes classic PL/0 plus `//` and `/* ... */` comments. It emits
  significant parser tokens and a lossless source stream containing whitespace
  and comment trivia. The stateful `PL0IncrementalTokenizer` preserves identities
  in both streams for reusable prefixes and suffixes.
* `PL0Frontend` selects the compatibility recovery parser or adapters over the
  directly linked **LR-Parsing SLR(1)** and **Earley-Parser** engines.
  `PL0ParserProtocol` projects their results into ModEdit's existing immutable
  editor contract. LR emits its package-native reduction tree; Earley exports
  its package-native SPPF through `Parser.ParseForestSnapshot`.
* `PL0LanguageSession` retains lexer and parser caches for one versioned
  document. Successful blocks, statements, conditions, expressions, terms and
  factors can still be reused by the compatibility recovery path. The linked LR
  and Earley adapters currently report stable input prefixes but re-run their
  package engines; native incremental state belongs in those shared packages.
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
  It consumes the shared `PL0SemanticModel` rather than resolving names again,
  and publishes the recovered CST through Compiler's public syntax boundary.
  `PL0VirtualMachine` executes integer arithmetic, conditions, loops, nested
  procedures and recursion with checked arithmetic and an instruction limit.
* `PL0LSPAdapter` is a transport-neutral, multi-document language service. It
  accepts full or ranged LSP changes, rejects stale versions and provides
  parser plus semantic diagnostics, scope-aware completion, definition, hover,
  references, semantic tokens and their standard delta-encoded integer stream.
  Positions are zero-based UTF-16 line/character pairs.
* `GrammarWorkbenchHotReloadSession` speaks Grammar Workbench's published
  schema-1 JSON-lines protocol without linking ModEdit to Workbench packages.
  It retains one document session, sends UTF-16 edits and atomically activates
  valid grammar replacements while keeping the last good revision on failure.
* `PL0EcosystemParserSession` constructs one `Grammar` value and one positioned
  `Lexer.TokenStream`, then runs the linked LL(1), LR(0), SLR, LALR, LR(1),
  Earley, Earley-table SL/EL, CYK and RNGLR packages directly in-process.
* Parsing starts 120 ms after an edit on a detached task. A result is displayed
  only if its version still matches the document revision.

The parser menu switches the three editor-facing engines for the current
document. The **Compare** tab shows their acceptance and metrics side by side,
and can run the ten directly linked ecosystem engines without external setup.
It deliberately reports disagreements rather than coercing them
into the reference result. The **Trace** tab exposes LR shift/reduce/state-stack
events or Earley predict/scan/complete/chart events, including incremental
reuse. Tokens shows lexer locations and classifications. CST shows grammatical
nesting followed by the recovered terminal stream; Semantics shows lexical
scopes, declarations, levels and slots. The header reports snapshot
version, token count, scanned UTF-16 length, lexer reuse, parser node/token reuse
and lexer+parser time.

### Grammar Workbench hot reload

Build `grammar-workbench-service`, then launch ModEdit with these environment
variables (absolute paths are recommended):

```sh
MODEDIT_GRAMMAR_WORKBENCH_SERVICE=/path/to/grammar-workbench-service \
swift run ModEdit
```

The bundled language-kit grammar is used automatically. Set
`MODEDIT_PL0_GRAMMAR=/path/to/experimental.grammar` only when deliberately
testing a grammar override. The Grammar WB tab then reports whether the external
grammar fingerprint still matches the native parser artifact.

The **Grammar WB** tab reports connection state, grammar and document
revisions, parse status, token count and diagnostics. ModEdit polls the grammar
file's modification date twice per second. A saved change triggers
`sessionReplaceGrammar`; Grammar Workbench recompiles the grammar and reanalyzes
the retained PL/0 document. Invalid replacements are reported but do not replace
the active grammar. Editor changes are sent through `documentChange` as
revisioned UTF-16 edits. **Reload Now** is available for an explicit refresh.

### Actual ecosystem parser engines

Open the **Compare** tab and choose **Compare Engines**. Each row reports
acceptance, derivation count, available forest-node count, ambiguity and
production-identity evidence. The run is revision-bound: editing the document
clears it, and a late result for an older revision is discarded.

ModEdit uses the same compatible released dependency set as Grammar-REPL.
SwiftPM resolves one shared identity for Grammar, Parser and Lexer, while the
PL/0 adapter converts its authoritative artifact and UTF-16 token positions to
the ecosystem contracts.
See [Ecosystem Parser Integration](../PL0-LanguageKit/Docs/EcosystemParserIntegration.md).

The authoritative grammar is
[PL0.grammar](../PL0-LanguageKit/Sources/PL0Language/Resources/PL0.grammar), compiled as a SwiftPM
resource and validated as 43 productions, 29 terminals and 18 typed
nonterminals. `PL0LanguageKit.compile` can load an experimental revision; the
generated SLR and Earley parser types accept that kit directly. Parse results
retain the grammar artifact identity, and experiment export rejects a result
paired with a different grammar fingerprint.

See [PL/0 Single-Source Language Kit](../PL0-LanguageKit/Docs/PL0LanguageKit.md) for the artifact
model, validation rules, custom-kit API and lossless-token design.

The source editor projects the current result directly onto the text: errors and
warnings are underlined, missing tokens receive an orange insertion marker, and
skipped tokens are tinted and struck through. These are TextKit temporary
attributes, not document attributes, so they never affect undo, syntax colours
or saved bytes. Click the problem count in the status bar to open the Problems
pane below the editor for diagnostics and suggested fixes. Clicking a problem
or an inspector token reveals and selects its UTF-16 range in the editor.
Every visualization is tagged with its document version; edits remove the old
markers immediately and late parser results are rejected.

**Edit → Format Document** is available when the current language provider
supports formatting. It replaces the source through the live text view, so
the edit is undoable. **Run** compiles and executes on a detached task.
The **Output** tab reports global values, instruction count, maximum
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
`../PL0-LanguageKit/Sources/PL0Language/PL0ExperimentContract.swift`. It projects existing
`ParseResult` values without changing the parser API. In particular, malformed
LR or Earley input is recorded as a request for that engine whose effective
result came from reference LL recovery; recovery is not incorrectly attributed
to the requested recognizer.

```swift
import LanguageExperimentProtocol
import PL0Language

let source = SourceSnapshot(version: 1, text: "begin call p end.")
let result = PL0Frontend(engine: .generatedLR).parse(source)
let run = try result.experimentRun(
    snapshot: source,
    documentURI: "file:///experiment.pl0")
let bundle = try PL0ExperimentContract.bundle(
    id: "pl0-first-run", title: "PL/0 parser experiment", runs: [run])
let json = try bundle.json()
```

See [Language Experiment Protocol](../PL0-LanguageKit/Docs/LanguageExperimentProtocol.md) for the
field model, invariants and ecosystem adoption path.

## Unified experimental front end

PL/0 editor analysis, parser comparison, formatting, compilation, and LSP
features now share `PL0Frontend`. Its `prepare(_:)` operation creates one
immutable `PL0PreparedFrontend` containing the versioned source, tokenization,
parser input, grammar fingerprint, and lexer measurements. Local engines and
the directly linked Grammar/Parser ecosystem consume that prepared value
without independently reconstructing the input.

`PL0LanguageSession` retains the prepared value produced by incremental editor
analysis. The **Compare Engines** action reuses it when the source revision
matches, ensuring that the comparison sees the same token identities shown in
the workbench. Formatter, compiler, and LSP adapters also accept an injected
front end so a compiled or hot-reloaded language kit can be used consistently.

See [Unified experimental front ends](../PL0-LanguageKit/Docs/UnifiedExperimentalFrontends.md) for
the data flow, invariants, and next cross-repository integration boundary.

## Shared semantics, compiler, and LSP

`PL0LanguageSession.analyze(_:)` produces one `PL0Analysis` for an exact editor
revision. Its public semantic model contains stable declaration identities,
lexical scopes, resolved references, storage slots, constant values, semantic
classifications, and source-located diagnostics. Compilation and LSP features
consume this same evidence.

The bytecode lowerer therefore no longer performs a separate symbol-resolution
pass. LSP documents retain their own incremental language session, and a ranged
change preserves unchanged token and symbol identities. See
[Semantics, Compiler, and LSP](../PL0-LanguageKit/Docs/SemanticsCompilerLSP.md) for the model,
Compiler package boundary, and transport roadmap.

## Fine-grained incrementality

The reference LL parser now reuses both clean and recovered token-delimited
regions. Recovered reuse replays the cached diagnostics, expected tokens, and
repair actions at their current UTF-16 positions. Semantic analysis separately
reuses stable declaration signatures and reference bindings, invalidating a
binding only when the declaration chain capable of resolving that spelling
changes. Reuse and invalidation counts appear in the Semantics view and in
experiment bundles as the independent `semanticNodes` dimension.

Every incremental semantic result and compiled program in the edit campaign is
checked against a fresh full analysis and lowering. The exact cache invariants,
tests, and intentionally unclaimed LR/Earley/Compiler reuse are described in
[Fine-grained incrementality](../PL0-LanguageKit/Docs/FineGrainedIncrementality.md).

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
Version.json                        single version source (marketing, build, channel)
Docs/Versioning.md                  version, tag and release policy
Release/EcosystemVersions.json      current ecosystem tag snapshot
scripts/make-app.sh                 build ModEdit.app
scripts/package-release.sh          build and zip the release app
scripts/version.sh                  sync/check/bump version metadata
scripts/verify-ecosystem-versions.sh  validate tags and dependency pins
scripts/verify-clean-checkout.sh    pre-release build in a temporary copy
scripts/benchmark-large-files.sh    run the 10/50 MB benchmark
Sources/
  ModEditApp/                       @main entry point, Info.plist
  ModEditCore/
    ModEditApplication.swift        AppKit application, delegate and main menu
    Version.swift                   generated version constants (do not edit)
    Model/ModEditDocument.swift     NSDocument shell and window controller
    Formats/                        DocumentFormat, FormatRegistry, PreferenceStore, formats
    Highlighting/                   Token, Tokenizer, scanners, DirtyRange, EditorTheme, StorageHighlighter
    IO/TextIO.swift
    Export/                         preview HTML/PDF export and hardened offscreen PDF renderer
    Model/                          EditorDocument, EditorModel, LineIndex, LineNumberSource
    Preview/                        PreviewRenderer, RenderedHTML, MarkdownHTML, LaTeXHTML,
                                    escaping, page, limits, web-view security config
    Workbench/                      PL/0 parser inspector
    UI/                             root/status bar, editor/gutter, preview
  RenderedText/                     platform-neutral Markdown projection and source/display map
Tests/ModEditTests/                 Swift Testing suites
Tests/RenderedTextTests/            projection, mapping, renderer and incrementality suites
../PL0-LanguageKit/                 language, grammar, conformance corpus and tests
.github/workflows/ci.yml            truth, debug + release build, tests and packaged artifact
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
* **Settings are one versioned JSON value, applied live.** `EditorPreferences`
  publishes one normalized `EditorSettings` value and persists it as a single
  `UserDefaults` blob. Appearance is applied to `NSApp`; font family and size
  update the live text view and rendered styler, then re-highlight through the
  normal chunked or rendered path. Soft wrap changes only the text container
  and scroller, so it never touches text, selection or undo. A corrupt or
  missing blob fails closed to the defaults instead of half-applying old keys.
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
  skipped before the web view is touched. The document directory travels with
  the render request and is also the load's base URL, so local resources resolve
  without being inlined into the HTML.
* **Export renders the preview, not an approximation of it.** Both export
  commands reuse the pane's `PreviewRenderer` and document directory, so
  Markdown, LaTeX and HTML output matches what was on screen. PDF uses an
  offscreen `WKWebView` with the same no-JavaScript, non-persistent
  configuration and navigation policy; user HTML keeps the injected CSP.
  Export refuses documents above the 5 MB preview cap and rejects empty PDF
  data before replacing a file.
* **One shared incremental line index.** The document owns the UTF-16 line
  starts. A text edit rebuilds only the affected line window and shifts the
  remaining starts; the status bar and gutter both read that index instead of
  maintaining their own copies.
* **Generation-based view synchronization.** Editor-originated mutations record
  the document generation immediately. A different generation is treated as an
  external replacement and pulled into the text view, covering reload/revert.
* **Generation-based save status.** Save snapshots carry their source generation.
  A completed older autosave cannot incorrectly mark a newer edit clean.
* **Small public surface.** Only `ModEditApplication` and the generated
  `ModEditVersion` constants are public.
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
* **Rendered editing is hybrid.** The caret line always shows literal source, so
  markup is visible wherever you are editing. Display-only content uses glyph
  substitution. Standalone local files and `data:` images are drawn as
  attachments; inline images, remote URLs, unresolved paths and documents
  without a file location keep their alt text. Display strings that are longer
  than their source range or contain control characters fall back to source
  spelling. Missing glyphs are resolved through Core Text fallback fonts; a
  character with no fallback (or only `LastResort`) also keeps its source
  spelling. Collapsed characters remain in storage with zero width, so text
  selection may visually begin or end on hidden syntax, and the substitution
  slots map to source characters rather than a separate rendered-text buffer.
* **Scroll synchronisation is block-granular and Markdown-only.** The preview
  follows the caret's source line and reports the block at its viewport top;
  scrolling it reveals that line in the editor without moving the caret.
  Anchors exist for headings, paragraphs, lists and list items, block quotes,
  tables, thematic breaks and fenced code, so inline links or very short blocks
  can map to a neighbouring line. The preview does not mirror the selection,
  find results or rendered-mode caret positions, and LaTeX and HTML previews
  keep their independent scroll position.
* **Markdown preview is still a subset.** Rendered editing and the preview
  share the `RenderedText` projection, including setext headings, nested and
  task lists, tables, strikethrough and block-quote lists. Images resolve from
  `data:image` payloads or local destinations in documents with a file location;
  remote images and images in untitled documents keep their alt text. Table
  column alignment is not reproduced, and maths (KaTeX) and embedded-language
  highlighting remain roadmap work. **LaTeX subset only** (no environments,
  `\frac`, `\sqrt`, macros).
* **Preview resources are local-only.** The base URL is the document directory,
  so relative and absolute local resources load, but remote stylesheets, images,
  fonts and media stay blocked by policy. Documents without a file location
  cannot resolve relative resources.
* **Preview export is HTML/PDF and web-preview-only.** Formats without an HTML
  renderer (plain text, PL/0, JSON, CSS) and the custom DOT pane cannot be
  exported. PDF export currently produces one continuous page rather than
  paginated Letter/A4 pages. HTML export references local resources relative to
  the document directory, so it expects to stay beside the source document;
  `data:` images remain embedded.
* **Editor typography is limited and local to the editor.** Settings offer
  three monospaced families and 10–24 pt. Family and size affect source and
  rendered-editing text, not the preview stylesheet or its code blocks.
  Appearance is app-wide (System, Light or Dark), not per window, and a font
  family that is not installed falls back to the system monospaced font.
* **Live preview is capped at 5 MB and rendered editing at 512 KB.** Larger
  documents remain editable and savable in source mode; the preview pane shows a
  notice instead of copying and rendering them.
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
  memoizes clean and recovered grammar regions, including recovery evidence.
  Invalidated ancestor paths and the program root are rebuilt; individual
  production repair is not attempted.
* **The PL/0 grammatical CST is normalized.** Its terminal view contains
  significant source, missing and skipped tokens. The lexer now separately
  retains a lossless, identity-preserving stream of whitespace, comments and
  significant tokens, but trivia is not yet attached to individual CST nodes.
* **The PL/0 VM is deliberately small.** Values are checked machine integers;
  the controlled grammar has no input/output statement, so execution results
  currently expose final global variables rather than a console stream.
* **The LSP layer is transport-neutral.** It intentionally does not own stdin,
  sockets or JSON-RPC framing. `PL0LSPAdapter` can be called directly by
  ModEdit and wrapped by a small standards-facing server without coupling the
  language engine to one process model. Semantic analysis continues over a
  recovered token stream, so useful results remain available while typing.
* **Recovery remains normalized.** LR-Parsing supplies the reduction tree and
  Earley-Parser supplies the packed forest. For the existing editor recovery
  view, rejected input still falls back to the compatibility recovery parser.
  Removing that final handwritten parser requires projecting LL-Parsing's
  recovery tree and edits into the editor CST without losing source fidelity.
* **Grammar Workbench is opt-in and out-of-process.** ModEdit does not build,
  locate or launch an unspecified Workbench binary automatically. Both paths
  must be supplied through environment variables. The bundled external grammar
  currently skips whitespace and `//` comments; ModEdit's native lexer also
  supports block comments.
* **Ecosystem comparison is recognition-oriented.** All ten packages run
  directly, but the comparison rows currently show portable acceptance,
  derivation, forest and replay summaries rather than every engine-specific
  internal structure. CYK currently prints normalization warnings for nullable
  PL/0 productions; those messages originate in CYK-Parser.

## Roadmap

The first ecosystem-integration phase is complete in ModEdit: the shared
language experiment schema, deterministic bundle format, PL/0 adapter, fallback
disclosure and reuse/recovery evidence are implemented. Adoption by the sibling
repositories and embedding Parser's portable semantic/operational snapshots are
the next cross-repository steps.

The second phase is also complete locally: `PL0.grammar` is a packaged single
source for lexical declarations and generated-parser productions, results carry
its fingerprinted identity, Workbench drift is visible, and lossless trivia is
available to formatters and future refactorings. Grammar-Macros generation and
adoption by sibling repositories remain cross-repository follow-up work.

The corrected third phase now links and executes the actual package engines.
The duplicated local SLR generator, LR runtime, Earley chart and forest builder
have been deleted. Remaining migration work is deliberately visible: replace
the compatibility recovery parser with LL-Parsing recovery projection, move
the PL/0 scanner onto Lexer while retaining incremental trivia identities, and
adapt PL/0 lowering to Compiler rather than maintaining parallel infrastructure.

The fourth phase is complete inside ModEdit: editor parsing, direct engine
comparison, formatting and compilation share one prepared document input, and
the LSP/standalone consumers use the same configurable front-end abstraction.
Promoting that prepared-session boundary into a shared ecosystem package is the
next cross-repository step for Grammar-REPL and Grammar-Workbench.

The fifth phase is complete locally: semantics has one public, source-located
model shared by the compiler, workbench, and LSP adapter. Compilation lowers
resolved lexical addresses and exports Compiler-compatible syntax artifacts;
LSP analysis is incremental and provides diagnostics, completion, definition,
hover, references, and encoded semantic tokens. The next ecosystem step is to
extend Compiler's IR with explicit static-link operations so nested PL/0
procedures can move onto the shared backend without weakening their semantics.

The sixth phase is complete for the state ModEdit owns: reference-parser
regions—including recovered regions—and semantic declarations/bindings are
genuinely reused with stable-token and dependency proofs. Exact measurements
are exported through the shared experiment contract, and differential edit
campaigns compare semantics and bytecode against fresh runs. Native LR stack,
Earley chart/forest, and Compiler IR reuse remain work in their owning ecosystem
packages; ModEdit deliberately continues to identify their current adapter
evidence as stable-prefix reuse.

1. **Parser comparison laboratory.** Add stepping and forest visualization to
   the connected native traces; project the now-connected Earley-table, CYK and
   RNGLR results into recovery-cost and full-versus-incremental differential
   experiment bundles.
2. **Ecosystem-native incrementality.** Add resumable LR stacks, dependency-
   indexed Earley chart/forest invalidation, and stable Compiler IR blocks to
   their owning packages; consume those APIs here. Add mutation minimization and
   grammar-aware mutation operators to the existing differential campaigns.
3. **Standards-facing LSP transport.** Wrap the implemented, version-safe
   `PL0LSPAdapter` in JSON-RPC framing, add initialize/capability negotiation,
   cancellation and the standard delta-encoded semantic-token wire format.
4. **Rendering inside the editor.** Hybrid rendered editing is implemented:
   `RenderedEditorPresentation` collapses `RenderedText` runs outside the caret
   line, the caret moves through source/display positions, and layout-manager
   glyph substitution draws entities, escapes, list markers, thematic breaks and
   inline-code content. Standalone local and `data:` images are drawn as
   attachments, and missing display glyphs resolve through fallback fonts.
   Remaining work is inline media, attachment-aware selection geometry, and
   raising the 512 KB limit by sharing incremental parsing with the preview.
5. **Scroll and caret synchronisation** between source and preview. Markdown
   now emits one-based source-line anchors, the preview follows the caret, and
   user scrolling reveals the matching editor line without moving the caret.
   Remaining work is selection and find-result mirroring, finer-grained anchors,
   and extending synchronisation to other formats once they share a source map.
6. **Real markup parsers:** `swift-markdown` now drives the `RenderedText`
   projection, and rendered editing and the WebKit preview both render from it.
   Bundle KaTeX for typeset maths and expand stateful highlighting to embedded
   languages.
7. **Relative resources in the preview** are implemented: the pane loads with
   the document directory as its base URL, Markdown emits local images only for
   located documents, and Save As refreshes the base URL. Remote resources stay
   blocked by policy.
8. **Editor settings** are implemented: app-wide System/Light/Dark appearance,
   System Monospaced/Menlo/Monaco font families, 10–24 pt sizes, and a persisted
   soft-wrap toggle with a View menu item. Remaining work is extending the same
   controls to the preview and the iPad prototype.
9. **Preview export** is implemented: File > Export as HTML… / PDF… renders the
   same page as the live preview, with the same security policy and size cap.
   Remaining work is paginated PDF output, self-contained HTML resource copying,
   and export for the custom DOT preview.
10. **Export polish.** Add page-size and margin choices for multi-page PDFs,
    copy or embed local resources for portable HTML, and extend export to the
    DOT preview and the iPad prototype.

## Contributing

* Keep formats free of AppKit types; put visual choices in `EditorTheme`.
* Every behaviour change needs a test (`swift test` must pass).
* Escape anything inserted into HTML (`HTMLEscaping.escape`).
* Document non-obvious decisions with `///` comments, especially invariants.

## License

See [LICENSE](LICENSE).
