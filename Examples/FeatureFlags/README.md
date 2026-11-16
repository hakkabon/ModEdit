# Feature flags grammar trial

The grammar accepts one or more commands such as `enable cache` and
`disable logging`. This project needs four grammar rules, three example
files, and one Workbench project descriptor. It uses the tools' built-in
grammar support with zero language-specific Swift code.

1. Copy this folder if you want to keep the original example intact. In
   Grammar Workbench choose **Open Source Project** and select
   `.grammar-workbench-source.json` in the folder.
2. Remove `| "disable"` from the `action` rule and choose **Check Draft Against
   Examples**. The enable-only example stays accepted. The disable-only and
   mixed examples fail on the unexpected `disable` token.
3. Remove the entire `action` production's right-hand side to try an invalid
   draft. Workbench reports the missing production and keeps its accepted
   grammar available. Restore the full rule, check that all examples are
   accepted, then choose **Save Grammar**.
4. Open the saved `FeatureFlags.bnf` in ModEdit. The Preview pane shows
   railroad diagrams for all four rules.

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
