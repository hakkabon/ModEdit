# Versioning and releases

ModEdit keeps one version source and one release tag per public state. This
document describes where the version lives, what is generated from it, how the
ecosystem tag graph is checked, and what must happen before a release is called
truthful.

## Source of truth

[`Version.json`](../Version.json) is the only place a ModEdit version is chosen.

```json
{
  "marketingVersion": "0.41.0",
  "buildNumber": 4100,
  "channel": "development"
}
```

`marketingVersion` must be `MAJOR.MINOR.PATCH` and must match the git tag when a
release is tagged. `channel` is `development`, `beta`, or `release`.

The build number is derived from the marketing version:

```
build = major * 10000 + minor * 100 + patch
```

So `0.41.0` is build `4100`, `0.41.1` is `4101`, and `0.42.0` is `4200`. The
formula keeps the bundle version monotonic without a second counter to maintain.
A minor or patch component above 99 would collide; that is intentionally
rejected.

## Generated artifacts

`scripts/version.sh sync` mirrors `Version.json` into:

| Artifact | Field |
|---|---|
| `Sources/ModEditCore/Version.swift` | `ModEditVersion.marketing`, `.build`, `.channel` |
| `Sources/ModEditApp/Resources/Info.plist` | `CFBundleShortVersionString`, `CFBundleVersion` |
| `iPad/Info.plist` | `CFBundleShortVersionString`, `CFBundleVersion` |
| `README.md` | the `<!-- VERSION -->…<!-- /VERSION -->` marker |

The generated files are committed. `scripts/version.sh check` fails if any of
them is stale, and CI runs it on every push and pull request. The app's standard
About panel reads the bundle plist; `modedit-experiment --version` reads the
Swift constant.

## Commands

```sh
scripts/version.sh                  # 0.41.0 (build 4100, development)
scripts/version.sh show --marketing # 0.41.0
scripts/version.sh show --json      # machine-readable
scripts/version.sh check            # verify generated metadata
scripts/version.sh sync             # regenerate generated metadata
scripts/version.sh bump patch       # 0.41.0 -> 0.41.1, then sync
scripts/version.sh set 0.42.0       # explicit version, then sync
scripts/version.sh verify-tag       # HEAD tag must equal Version.json
scripts/version.sh tag              # create an annotated release tag
```

`version.sh tag` refuses to run on a dirty tree, refuses to overwrite an existing
tag, and re-runs the consistency check first. It does not push; that remains an
explicit `git push origin <tag>`.

## Release tagging

Tags are bare annotated versions (`0.41.0`, not `v0.41.0`), matching the existing
history. A release follows the ecosystem order:

1. foundations (Grammar, Lexer, Parser, Incremental-Parsing);
2. parser engines;
3. tooling and Compiler;
4. language kits;
5. products (ModEdit, Grammar-REPL, Grammar-Workbench).

The tag must point at a commit whose tree is exactly the released state. Tagging
a dirty working tree, or tagging a commit that differs from the built artifact,
is not a release.

## Ecosystem tag graph

[`Release/EcosystemVersions.json`](../Release/EcosystemVersions.json) records the
current published tag for 29 ecosystem components: the 24 components in
Incremental-Parsing's release manifest, plus Railroad, Swift-Layout,
GrammarDiagram, TerminalColors, and Grammar-DiagramKit, which ModEdit or
Grammar-Workbench consume directly or transitively. It also records the exact
pins for external packages that are not part of the hakkabon tag graph.

The snapshot is a **tag graph**, not a compatibility guarantee. It answers "what
was published?" Grammar-Workbench's `Packaging/EcosystemCompatibility.json` is
the downstream compatibility lock and answers "what has been tested together?"

Check the graph without sibling checkouts (this is what CI runs):

```sh
scripts/verify-ecosystem-versions.sh
```

Check every sibling checkout is exactly at its recorded tag:

```sh
scripts/verify-ecosystem-versions.sh --root /path/to/sibling/checkouts
```

Regenerate the snapshot from the sibling checkouts after a coordinated release:

```sh
scripts/verify-ecosystem-versions.sh --root /path/to/sibling/checkouts --update
```

The script also rejects local filesystem package dependencies and requires every
ecosystem package or external dependency that appears in `Package.resolved` to
resolve to the recorded tag. A direct dependency with no pin is an error; a
transitive package that is not in the current resolution is simply absent from
the check.

### External dependencies

`externalDependencies` records packages that are not part of the hakkabon tag
graph but are required to build ModEdit. Each entry names the SwiftPM identity,
repository URL, exact tag, whether ModEdit declares it directly, and why it is
recorded. The validator:

* requires a direct external dependency to be declared in `Package.swift` as
  `.package(url: ..., exact: ...)`;
* requires every recorded external dependency that appears in
  `Package.resolved` to resolve to the recorded tag and URL;
* fails if the exact pin and the snapshot disagree.

The current entries are:

* **swift-markdown 0.6.0** — the CommonMark/GFM parser behind `RenderedText`.
  It is pinned exactly because 0.7.x raises the minimum Swift tools version to
  6.2, while ModEdit builds with Swift 6.1.
* **swift-cmark 0.9.0** — swift-markdown's C parser dependency. It is recorded
  so that a transitive resolution change is visible instead of implicit.

Upgrading either package means changing `Package.swift`, resolving
`Package.resolved`, updating this snapshot, and running the projection tests in
the same change.

### Known drift

Known, deliberate mismatches are recorded in `knownModEditDrift` with a reason
and the resolved version. CI warns about them but does not fail; any new
mismatch fails. The current entry is:

* **Incremental-Parsing 0.35.0 vs ModEdit 0.33.0.** The PL/0, CSS, JSON, DOT,
  and Grammar language kits all require `0.33.x`. The `0.33.0` to `0.35.0` diff
  is documentation-only, but SwiftPM cannot resolve the newer tag until those
  kits publish compatible patch releases. Removing this entry is the proof that
  the ecosystem is aligned again.

Other cross-repository drift that this snapshot intentionally exposes:

* Grammar-Workbench's compatibility lock still records LL-Parsing `0.1.2`,
  Compiler `0.3.0`, Earley-TableParser `0.2.1`, Grammar-REPL `0.9.0`, and
  Workbench `1.0.30`, while the current tags are `0.5.1`, `0.10.1`, `0.3.1`,
  `0.17.1`, and `1.10.1`. Updating that lock belongs to Workbench and requires
  its own conformance run.
* Incremental-Parsing's `Docs/ReleaseConsolidation.md` describes 19 components,
  but `Release/EcosystemRelease.json` contains 24. The manifest is authoritative;
  the prose needs a correction in that repository.
* The release manifest records compatibility floors (`minimumVersion`), not exact
  tags. A distribution must add exact revisions, as its own documentation says.

## Clean-checkout verification

CI checks out the repository fresh and builds from the committed manifests; there
are no sibling paths in `Package.swift`. For a local pre-release check that copies
the working tree, excludes build artifacts, and resolves dependencies from a
fresh scratch directory:

```sh
scripts/verify-clean-checkout.sh
```

This is slower than `swift test` because it resolves and builds in a temporary
directory. Run it before a release, not on every edit.

## Release checklist

1. `scripts/version.sh bump patch` (or `set`).
2. Review and commit the version change.
3. Wait for CI: truth, debug tests, release tests, packaged artifact.
4. `scripts/version.sh tag` if the tag does not exist yet; push it explicitly.
5. `scripts/version.sh verify-tag` to confirm the tag matches `Version.json`.
6. Update `Release/EcosystemVersions.json` if the ecosystem tag graph or an
   external exact pin moved.
7. Run `scripts/verify-ecosystem-versions.sh --root ...` against sibling
   checkouts.
8. Run `scripts/verify-clean-checkout.sh`.
9. Publish release notes that name the exact tags and the known drift, if any.

The goal is not ceremony. It is that a user, contributor, or packager can answer
"what version is this, what does it depend on, and was that combination tested?"
from the repository alone.
