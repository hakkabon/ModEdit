# Feature flags grammar trial

The grammar accepts one or more commands such as `enable cache` and
`disable logging`. This project needs four grammar rules, three example
files, and one Workbench project descriptor. It uses the tools' built-in
grammar support with zero language-specific Swift code.

1. Open `FeatureFlags.bnf` in ModEdit and show Preview. The railroad diagrams
   and **Grammar examples** pane appear together.
2. In **Grammar examples**, choose **Open…** and select `Examples.json`.
   The corpus contains accepted and rejected inputs. Checks run automatically
   after changes, with parser recovery disabled.
3. Remove `| "disable"` from the `action` rule. The disable example fails while
   the other examples keep their declared outcomes. Select it in the example
   picker to inspect the result. Accepted examples also expose their parse tree.
4. Try the incomplete rule from `Drafts/IncompleteAction.bnf`. The pane reports
   the grammar diagnostics instead of showing results from the preceding valid
   grammar. Restore the rule and check that all five examples pass.
5. Save the grammar through ModEdit's ordinary **Save** command. If you change
   the inputs, names, or expected outcomes, use **Save…** in Grammar examples
   to save that corpus separately in this folder.

In Grammar Workbench, use **Open Source Project** to open
`.grammar-workbench-source.json`. The **Grammar draft** section checks edits
against the input files. Use **Open Examples…** to load `Examples.json` as well.
These declared outcomes participate in checking and gate **Save Grammar**.

Both command-line tools expose the same shared check. With this folder as
your working directory:

```sh
grammar-repl-experiment authoring-check FeatureFlags.bnf Examples.json
grammar-workbench authoring-check FeatureFlags.bnf Examples.json
```

They emit a JSON report and exit successfully only when the grammar is valid
and every example has its declared outcome. Unknown input characters count as
rejection. Parser conflicts and step-limit failures fail either expectation.
These checks use Grammar's BNF/EBNF definitions and the native LALR runtime.
Without lexical declarations, whitespace separates literal tokens. A
`lexical { ... }` block makes its trivia policy explicit.

The repeatable cross-consumer trial is available from the ModEdit repository.

```sh
python3 scripts/verify-grammar-authoring.py \
  --repl /path/to/grammar-repl-experiment \
  --workbench /path/to/grammar-workbench
```

With the example folder as your working directory, the Workbench CLI can
repeat the comparison:

```sh
grammar-workbench source-project-check .grammar-workbench-source.json
grammar-workbench source-project-impact .grammar-workbench-source.json Drafts/RemoveDisable.bnf
grammar-workbench source-project-impact .grammar-workbench-source.json Drafts/IncompleteAction.bnf
grammar-workbench source-project-impact .grammar-workbench-source.json FeatureFlags.bnf
```

The two draft checks should exit with status 1, and the baseline and restored
grammar checks should succeed. The draft files are outside the input glob.

Workbench identifies the failing example and unexpected token. Its whitespace
input mode currently omits the line and column for the failure. The descriptor
requires authors to choose a notation, parser algorithm, and file association
before opening the project.

Workbench rejects the incomplete draft during grammar compilation. ModEdit's
railroad renderer can still draw the available rules from that same draft,
because preview rendering uses the grammar syntax tree without Workbench's
production validation. A visible diagram alone cannot confirm that the grammar
will compile.
