# Architecture

How MyMac is put together, and the places that are easy to get wrong. The
README covers what the app does and what each page shows; this covers why the
code is shaped the way it is.

## The three layers

```
Sources/MyMacCore/     no AppKit, no SwiftUI — testable on its own
Sources/MyMacUI/       the app, as a library so it can be tested
Sources/MyMac/         main.swift, one line, calls MyMacApp.main()
```

Two rules keep the split honest: **the core never imports AppKit or SwiftUI,
and the UI never calls a Mach API.** Anything AppKit-only that the core needs is
injected — running application names arrive as a `[pid_t: String]`, and "is this
app installed?" arrives as an `ApplicationInventory`.

### Why the app is a library

SwiftPM cannot link a test target against an executable. With the app in the
executable target, the whole app layer — the sampling lifecycle, the menu bar
rendering, every model — would be untestable, and that is exactly what let a
login-item message that erased itself and a timeout that could never fire both
ship.

So the executable is one line and everything lives in `MyMacUI`. `MyMacApp` is
`public` and deliberately carries **no `@main`**; the entry point is
`Sources/MyMac/main.swift`.

### Why there is an Xcode project as well

SwiftPM cannot build an XCUITest bundle. Without one, no test can click
anything, and the app layer's most user-visible behaviour — does pressing this
actually do that — has no coverage at all.

`MyMac.xcodeproj` is therefore thin and deliberately boring. Both targets use
filesystem-synchronized groups, so adding a source file needs no edit to it.
Every build setting lives in `Configs/*.xcconfig` and every `buildSettings` in
the project file is empty: build settings are source, and belong somewhere
readable and reviewable rather than inside a generated file.

The app target compiles the *same* `Sources/MyMac/main.swift` the package does
and links `MyMacUI` as a package product, so there is one entry point and no
second copy to drift. The package is referenced at `relativePath "."` — Xcode's
UI refuses to add a package folder that contains the project, but the file
format has no such rule and it resolves.

## Testing

| Layer | Tool | Covers |
|---|---|---|
| Core | `swift test` — `MyMacCoreTests` | metrics maths, collectors, `PathSafety`, the cleanup engine and catalog, the uninstaller, sampling cost |
| App | `swift test` — `MyMacUIUnitTests` | `MetricsStore` scopes, menu bar drawing, the login item, sorting, the icon cache, the launch contract |
| Interface | `MyMacUITests` (XCUITest) | that clicking a column header really re-orders the rows, and that the window opens where it was asked to |

The interface layer exists because the other two provably could not catch a real
bug. `UninstallerModel.sorting(for:)` maps each header to its column and
`visibleItems` sorts by it, both pinned by unit tests that pass — yet clicking a
header in the running app repeatedly failed to sort. A defect that survives a
correct, well-tested model lives between the click and the model, in the
`Table`'s `sortOrder` binding, and that stretch is reachable only from XCUITest.

There are deliberately few UI tests. They cost minutes where the unit tests cost
seconds, they take over the screen, and anything that can be pinned
deterministically one layer down belongs one layer down.

### How a UI test runs

`-MyMacUITesting YES` does three things, each of which the app would otherwise
do the opposite of:

1. **Keeps the window open.** `AppDelegate` normally closes every window and
   drops to `.accessory` one runloop turn after launch, which is right for a
   menu bar utility and fatal for a test runner — an accessory app with no
   window cannot be activated.
2. **Keeps the app `.regular`.** `DockPolicy.reviewAfterWindowClose()` normally
   demotes on every window close, which would pull the app out from under the
   runner mid-suite.
3. **Freezes sampling.** XCUITest waits for the app to go idle before answering
   a query, and a tree redrawing at 1 Hz never does.

`-MyMacUITestSection uninstaller` then opens the window straight onto a section.
The flag is a **pair**, not a bare flag: the `NSUserDefaults` argument domain
reads `-key value`, so a bare flag swallows the token after it — which is how a
test silently loses the section it asked for.

The window is opened from the menu bar label, through the same `handleRequest()`
a real menu bar click uses, so the test exercises the real path including the
promote-before-`openWindow` ordering.

## Sampling

Sampling is demand-driven and stops entirely when nothing is displaying metrics.
Scopes are retained and released by the views that need them; when the last one
goes, the loop stops.

All collectors run on one global actor (`MetricsActor`), off the main thread.
The main actor only ever receives immutable snapshots.

A scope joining while the loop is already sleeping samples immediately rather
than waiting for the next tick — without that, opening the Processes page sat
empty for up to three seconds.

## Safety

`PathSafety` gates every deletion, and the engine re-validates every path
immediately before touching it, using the rule's declared root as the allowlist
— never the scan result, which may be minutes old. The cleaner is an allowlist
in `CleanupCatalog`: every category names one exact directory, and no pattern
anywhere could expand to something unintended. A test fails the build on
overlapping roots unless the overlap is declared reviewed.

Nothing runs as root, there is no privileged helper, and no permission is
requested at launch — every prompt follows a button the user pressed.

## Things that have already gone wrong

These are recorded because each cost real time to find. The README carries the
rendering and measurement ones in context; the short list:

- `MenuBarExtra` must be declared before the `Window` scene.
- `DockPolicy.promote()` runs before `openWindow`, never from `onAppear`.
- `.fixedSize` inside a height-filling card blanks the entire window.
- Reading an observable property inside `App.body` invalidates the whole scene
  graph — worth ~20 % → ~3 % idle CPU.
- `proc_pid_rusage` reports mach absolute time units despite its field names:
  treating them as nanoseconds under-reported every process by 24× on Apple
  Silicon and was invisible on Intel.
- A SwiftUI `Table` is an `Outline` to XCUITest, its cells carry text as `value`
  rather than `label`, and its column headers report themselves as not hittable.
