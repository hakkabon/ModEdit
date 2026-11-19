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

DOT-LanguageKit 0.2.3 and Language-Tooling 0.10.2 declare iOS 14 support.
The app targets iPadOS 17. Xcode and the build script now build the package
graph using its declared deployment minima.

The UI test creates a document, types a graph, verifies the preview, removes
a closing brace, applies the suggested repair, and reopens the saved file.
Run it on an installed iPad simulator with its device identifier.

```sh
scripts/build-ipad.sh 'platform=iOS Simulator,id=YOUR-IPAD-SIMULATOR-ID' test
```

The Xcode project is `iPad/ModEdit-iPad.xcodeproj`. Dependencies resolve
from GitHub. The script builds an ad-hoc-signed Simulator app at
`iPad/DerivedData/Build/Products/Debug-iphonesimulator/ModEdit-iPad.app`.
For a physical iPad, use your development team identifier and the device
identifier shown by Xcode. The script selects the device SDK and automatic
development signing.

```sh
MODEDIT_SIGNING_TEAM=YOUR_TEAM_ID scripts/build-ipad.sh \
    'platform=iOS,id=YOUR_IPAD_DEVICE_ID' test
```

Use `build` as the second argument to build without running the test.
The device must be paired with Xcode, unlocked, and have Developer Mode
enabled. Automatic signing requires an Apple development account configured
in Xcode. In Xcode's Signing & Capabilities pane, select the same team when
building directly from the project.

Set `MODEDIT_DERIVED_DATA` to reuse a build directory at a different path.

The preview supports the same DOT subset and graph limits as the macOS editor.
During invalid edits the previous graph remains visible. Source links and
suggested fixes apply only to the source revision they describe.

## Verification

The app built with the iOS 18.5 SDK using published dependency tags and their
declared platform minima. No deployment-target override is required.

The complete create, edit, preview, repair, save, and reopen UI test passed on
an iPad Air (4th generation) running iPadOS 27.0.1 and an iPad Pro 11-inch
simulator running iPadOS 17. The test handles both document launch screens.

Language-Tooling's 19 tests, DOT-LanguageKit's 4 tests, and ModEdit's macOS DOT
layout regression passed with the compatibility patches.
