# Native iPad prototype

This DOT editor uses SwiftUI's document browser and a UIKit source editor.
Open a UTF-8 `.dot` or `.gv` file from Files, edit it, inspect Problems,
apply a proposed repair, and save through the native document interface.
The document browser also creates a new graph. Files are written as UTF-8.
The browser allows existing files regardless of their registered file type;
opening validates UTF-8 before treating the text as DOT.

Diagnostics and highlighting use `LanguageToolingDocument` with
`DOTProvider`. Graph projection uses `DOTProviderSession`. The preview shares
ModEdit's `DOTPreviewLayout.swift` and calls Swift-Layout's native layout engine.
The app shows the source and graph side by side at regular widths and stacks
them in narrow windows. Preview and Problems can each be hidden.

## Build

The prototype requires iPadOS 17 or newer and Xcode 16.3 or newer.

```sh
scripts/build-ipad.sh
```

The script sets iOS 17 across the dependency graph. Released DOT-LanguageKit
0.2.2 and Language-Tooling 0.10.1 omit their iOS deployment minima, so Xcode's
default iOS 12 for those packages conflicts with their iOS 14 dependencies.
Use the script until those packages publish explicit compatible iOS minima.

The UI test creates a document, types a graph, verifies the preview, removes
a closing brace, applies the suggested repair, and reopens the saved file.
Run it on an installed iPad simulator with its device identifier.

```sh
scripts/build-ipad.sh 'platform=iOS Simulator,id=YOUR-IPAD-SIMULATOR-ID' test
```

The Xcode project is `iPad/ModEdit-iPad.xcodeproj`. Dependencies resolve
from GitHub. The script builds an ad-hoc-signed Simulator app at
`iPad/DerivedData/Build/Products/Debug-iphonesimulator/ModEdit-iPad.app`.
For a physical iPad, select a signing team and build for the device with the
same deployment-target override.

The preview supports the same DOT subset and graph limits as the macOS editor.
During invalid edits the previous graph remains visible. Source links and
suggested fixes apply only to the source revision they describe.

## Verification

The app built with the iOS Simulator 18.5 SDK. The complete document creation,
editing, preview, repair, and save/reopen UI test passed on an iPad Pro
11-inch simulator running iPadOS 17. The shared layout adapter's macOS DOT
preview regression also passed. Physical-device testing remains pending.
