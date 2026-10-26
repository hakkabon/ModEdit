# ModEdit

A native macOS text editor for **editing text that renders differently from its
plain-ASCII source**. You type Markdown or LaTeX on the left; a live preview on
the right shows it as headings, emphasis, symbols and mathematics.

> **Status: early development (v0.1.0).** The editor, syntax colouring, format
> switching, file open/save and the live preview work end to end for Plain Text,
> Markdown, LaTeX and HTML. Rendering *inside* the editor pane (single-pane
> "live preview" with a caret that moves through rendered text) is the next big
> milestone; see the [roadmap](#roadmap).

## Table of contents

1. [Features](#features)
2. [Requirements](#requirements)
3. [Build, run, test](#build-run-test)
4. [Architecture](#architecture)
5. [Formats](#formats)
6. [The preview](#the-preview)
7. [Adding a format](#adding-a-format)
8. [Project layout](#project-layout)
9. [Design decisions](#design-decisions)
10. [Known limitations](#known-limitations)
11. [Roadmap](#roadmap)
12. [Contributing](#contributing)
13. [License](#license)

## Features

* Document-based app (open, save, autosave, versions) built on SwiftUI
  `DocumentGroup`.
* TextKit-backed `NSTextView` editor with find bar, undo/redo and **all automatic
  text "corrections" disabled** (smart quotes, dashes, replacement), because this
  is a source editor.
* Adaptive **line-number gutter** with a distinct background, plus synchronized
  very-light-gray current-line highlighting in the gutter and editor. The bottom status bar
  shows the one-based cursor position, active text format, tab size and a
  high-contrast clean/dirty document indicator.
* **Syntax colouring** for Markdown, LaTeX and HTML: debounced, incremental
  (only the edited lines), chunked on load so large files do not freeze the UI,
  state-aware for multiline Markdown fences and HTML tags/comments, and safe
  with input methods (Japanese/Chinese/Korean composition).
* **Live preview** (WebKit) that keeps its scroll position while you type:
  * *Markdown* — headings, paragraphs, lists, block quotes, fenced code,
    `**bold**`, `*italic*`, `` `code` ``, links.
  * *LaTeX* — `\section`, `\textbf`, `\emph`, math with Greek letters and
    operators (`\alpha` → α), super/subscripts (`x^2`, `x_{i}`), comments hidden.
  * *HTML* — your page as written (scripts disabled).
* **Encoding-faithful I/O**: UTF-8 (with/without BOM), UTF-16 and detected legacy
  encodings are written back the way they were read; saving never silently
  replaces characters.
* Light/dark mode aware (dynamic system colours, `color-scheme` in the preview).

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
open "$(swift build --show-bin-path)/ModEdit.app"
```

The current source is verified with `swift build` and `swift test` (60 tests)
using Swift 6.1.2 and the macOS 15.5 SDK. CI repeats both commands on every
push and pull request.

Why a script? `swift run` starts a bare executable without an app bundle, so the
document types in `Info.plist` are not registered and Finder cannot open files
with it. `make-app.sh` wraps the binary in a minimal bundle and ad-hoc signs it.
You can also open `Package.swift` in Xcode and run the `ModEdit` scheme.

## Architecture

```
ModEditApp (executable)           thin: @main App { ModEditScene() }
        │
        ▼  only public symbol: ModEditScene
ModEditCore (library)
┌──────────────────────────────────────────────────────────────────────────┐
│ UI            EditorRootView ─ EditorTextView (NSTextView) ─ PreviewPane │
│                 status bar       └ LineNumberRulerView       (WKWebView) │
│                    │                  │  ▲ edits           (WKWebView)    │
│ Model         EditorModel (@MainActor, @Published revision/format)       │
│                    │ writes through                                       │
│               EditorDocument (locked mutable text; immutable snapshots)  │
│ IO            TextIO (decode/encode, BOM, encoding detection)            │
│                                                                          │
│ Formats       DocumentFormat ── FormatRegistry (immutable)               │
│                 • id, content types                                      │
│                 • highlightRules + optional stateful highlighting mode   │
│                 • makePreviewRenderer()                                  │
│ Highlighting  Tokenizer → Token(range, kind)   (pure, platform-neutral)  │
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
3. The storage delegate applies only the replacement range to the document's
   locked `NSMutableString`, increments a cheap published revision, and notifies
   `ReferenceFileDocument` so autosave sees the change.
4. SwiftUI re-evaluates `EditorRootView`; after a 250 ms debounce `PreviewPane`
   takes one immutable snapshot, renders it, skips identical output, and restores
   the scroll position. Fast typing therefore does not copy the complete file
   for every keystroke.
5. Selection changes update the status bar's one-based `line:column` location.
   Successful writes record the exact saved generation; the document becomes
   clean only when no newer edit exists.

Navigation uses a cached UTF-16 line-start index: line/column lookup is binary
search rather than a scan from the beginning. The gutter asks the layout manager
only for visible line fragments. The index is rebuilt only when an edit changes
the number of lines.

## Formats

| Format     | Types                         | Colouring                                      | Preview |
|------------|-------------------------------|------------------------------------------------|---------|
| Plain Text | `public.plain-text`, UTF-8    | —                                              | —       |
| Markdown   | `net.daringfireball.markdown` | headings, bold, links, quotes, lists, code     | yes     |
| LaTeX      | `org.tug.tex`                 | commands, arguments, math, comments            | yes     |
| HTML       | `public.html`                 | tags, attributes, strings, comments            | yes     |

The format is chosen from the file's type on open and can be changed from the
toolbar picker (which also lets you pick a format for a new, untitled document).
XML, JSON and YAML open as plain text.

> `UTType.markdown` only exists in the macOS 27 SDK, so Markdown is imported by
> identifier (`UTType(importedAs:)`) and declared in `Info.plist`.

## The preview

Previewed files are *untrusted input*, so the preview is hardened:

* the web view runs with **JavaScript disabled**;
* **navigation is blocked** — clicked links open in your browser, never in the
  preview;
* all text is **HTML-escaped** before markup is added; raw HTML in a Markdown or
  LaTeX file is shown as text;
* Markdown links are limited to `http`, `https` and `mailto`;
* generated pages carry a **Content-Security-Policy** forbidding scripts, remote
  loads and frames.

The previous implementation inserted LaTeX source into the page unescaped, so a
`.tex` file containing `<script>` would execute it.

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
2. Add it to `FormatRegistry.standard`.
3. Declare the type in `Info.plist` (`UTImportedTypeDeclarations` and
   `CFBundleDocumentTypes`) if the system does not know it.
4. Add tests: `FormatTests.swift` already checks that **every** shipped rule
   compiles, so a typo cannot silently disable highlighting.

A new preview is a `PreviewRenderer` returning an HTML string; wrap bodies with
`PreviewPage.wrap(body:)` and escape text with `HTMLEscaping.escape`.

## Project layout

```
Package.swift
scripts/make-app.sh                 build ModEdit.app
Sources/
  ModEditApp/                       @main, Info.plist
  ModEditCore/
    ModEditScene.swift              the only public API
    Formats/                        DocumentFormat, FormatRegistry, formats, UTTypes
    Highlighting/                   Token, Tokenizer, DirtyRange, EditorTheme, StorageHighlighter
    IO/TextIO.swift
    Model/                          EditorDocument (persisted), EditorModel (UI state)
    Preview/                        PreviewRenderer, MarkdownHTML, LaTeXHTML, escaping, page
    UI/                             root/status bar, editor/gutter, preview
Tests/ModEditTests/                 Swift Testing suites
.github/workflows/ci.yml            macOS build + test
```

## Design decisions

* **Semantic tokens, not AppKit attributes, in formats.** Formats say *what* text
  is (`TokenKind`); `EditorTheme` says how it looks. Formats become pure,
  `Sendable` and testable; theming is one file.
* **Immutable registry, not a mutable singleton.** No registration step to
  forget or race.
* **Document vs. model split.** `ReferenceFileDocument` must be `Sendable` and is
  saved off the main thread, so the persisted state is lock-protected and saved
  via a value snapshot; UI state lives in a `@MainActor` model.
* **Rules are ordered by priority** ("later wins") so comments and code spans
  reliably override anything matching inside them.
* **State machines for multiline syntax.** Markdown fences and HTML tags and
  comments are scanned with explicit state; regex rules remain useful for local
  tokens. Tokens are clipped to the dirty lines before AppKit attributes change.
* **Generation-based view synchronization.** Editor-originated mutations record
  the document generation immediately. A different generation is treated as an
  external replacement and pulled into the text view, covering reload/revert.
* **Generation-based save status.** Save snapshots carry their source generation.
  A completed older autosave cannot incorrectly mark a newer edit clean.
* **Small public surface.** Only `ModEditScene` is public.

## Known limitations

* **Partial language grammars.** The stateful scanner handles multiline Markdown
  fences and HTML tags/comments, but it is not a complete CommonMark or HTML
  parser (for example, tilde fences and embedded languages are not recognised).
* **Preview is a separate pane.** The caret and scroll position are not
  synchronised with the source.
* **Markdown subset only** (no nested lists, tables, images, setext headings).
  **LaTeX subset only** (no environments, `\frac`, `\sqrt`, macros).
* **HTML preview cannot load relative resources** (images, CSS) because
  `DocumentGroup` does not expose the document's URL.
* **Edits still move suffix bytes.** The document uses `NSMutableString`, so it
  avoids a second full-file model copy but insertion near the beginning of a very
  large file remains O(n). A piece table or rope is the next scaling step.
* **Status columns use UTF-16 offsets.** This matches AppKit and LSP position
  accounting, but a grapheme such as a composed emoji can occupy several columns.
* **macOS only.** Core depends on AppKit, SwiftUI and WebKit.

## Roadmap

1. **Rendering inside the editor.** The headline feature. Plan: introduce a
   platform-neutral `TextRenderer` that emits *runs tiling the source exactly*
   (hidden markup = zero-width run) with a two-way source↔display offset map;
   draw the rendered form for everything except the line under the caret using
   TextKit 2 layout fragments or text attachments. The offset map is what lets
   the caret move through rendered text.
2. **Scroll and caret synchronisation** between source and preview (needs the
   same source map).
3. **Real parsers:** `swift-markdown` for CommonMark/GFM and a bundled KaTeX for
   typeset maths; expand stateful highlighting to embedded languages.
4. **NSDocument-based shell** if relative resources or finer control over saving
   are needed. Note SwiftUI's new `WritableDocument` API (SDK 27) is the intended
   successor to `ReferenceFileDocument`.
5. User-selectable themes, font and size settings; line numbers; soft-wrap toggle.
6. Export (HTML/PDF) from the preview.

## Contributing

* Keep formats free of AppKit types; put visual choices in `EditorTheme`.
* Every behaviour change needs a test (`swift test` must pass).
* Escape anything inserted into HTML (`HTMLEscaping.escape`).
* Document non-obvious decisions with `///` comments, especially invariants.

## License

See [LICENSE](LICENSE).
