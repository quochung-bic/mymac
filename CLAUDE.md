# CLAUDE.md

Notes for Claude Code working in this repository.

## Language

Source, comments and documentation are **written in English**. Keep it that way.

**Commit messages are English too** — natural imperative mood, first line under
60 characters, no `feat:`/`fix:` prefixes. The body explains *why*, not *what*.

## Common commands

```bash
# command-line build — Release, verifies the universal binary, outputs ./build/MyMac.app
./Scripts/build.sh            # --debug is faster, --test runs tests first, --help for all options

# build and install into /Applications (quits the running copy, replaces the bundle, reopens)
./Scripts/install.sh          # --test, --destination DIR, --no-build, --help

# unit tests — fast, no GUI needed. Run these first.
./Scripts/build.sh --unit-only

# the UI tests — slow, takes over the screen
./Scripts/build.sh --ui-only

# both layers
./Scripts/build.sh --test-only

# a runnable app without installing Xcode — SwiftPM only, this Mac only
./Scripts/build.sh --no-xcode

# one suite or one test
./Scripts/build.sh -u -f 'PathSafety'
./Scripts/build.sh -U -f 'SmokeTests'

# the same thing without the wrapper, when you need the raw tool
swift test --filter 'PathSafety'
xcodebuild -project MyMac.xcodeproj -scheme MyMac \
           -destination 'platform=macOS' \
           -only-testing:MyMacUITests/SmokeTests test

# redraw the whole app icon
swift Scripts/GenerateAppIcon.swift

# verify a Release build really is a universal binary
lipo -info build/MyMac.app/Contents/MacOS/MyMac
```

The finish line is always green: **188 unit tests + 5 UI tests, and no
warnings**.

Local `./Scripts/build.sh --test-only` is authoritative. The UI job in CI is
advisory — a hosted runner has no physical display and nobody to dismiss a
system prompt.

Warnings are promoted to errors **in CI only**, where the toolchain is pinned.
`Configs/*.xcconfig` deliberately does not set `-Werror`: a newer Xcode must not
break someone's build over code they never touched.

## Layout

| Path | Contents |
|---|---|
| `Sources/MyMacCore/` | All the logic. No AppKit, no SwiftUI. Testable on its own. |
| `Sources/MyMacUI/` | The app, as a *library* so it can be unit-tested. |
| `Sources/MyMac/` | `main.swift`, one line. Compiled by both SwiftPM and the app target. |
| `MyMacUITests/` | XCUITest bundle. Drives the real window. |
| `Configs/` | Build settings (`.xcconfig`) and entitlements. Change build settings here, never in the pbxproj. |
| `Scripts/` | `build.sh`, `install.sh`, `GenerateAppIcon.swift` — the icon is source code, not a hand-copied binary. |

`project.pbxproj` is hand-written and deliberately minimal. Avoid opening the
project in Xcode and saving — Xcode will rewrite it and bloat the file. Both
targets use filesystem-synchronized groups, so **adding a source file needs no
pbxproj edit**.

## Invariants — do not break these

1. **Layering.** `MyMacCore` imports neither AppKit nor SwiftUI, and the UI
   never calls a Mach API. Anything AppKit-only that the core needs is injected:
   running application names arrive as a `[pid_t: String]`, "is this installed?"
   as an `ApplicationInventory`.

2. **The executable is one line.** `Sources/MyMac/main.swift` calls
   `MyMacApp.main()`, and `MyMacApp` deliberately has no `@main`. The app lives
   in a library because SwiftPM cannot link a test target against an executable,
   and leaving the app layer untested is what let a login-item message that
   erased itself and a timeout that could never fire both ship.

3. **One sampling actor.** Every collector runs on `MetricsActor`, off the main
   thread. The main actor only ever receives immutable snapshots.

4. **No subprocess for metrics.** No `top`, `ps`, `vm_stat`, `df`, `iostat` or
   `system_profiler` is spawned, at any point, for anything.

5. **Every deletion goes through `PathSafety`**, and the engine re-validates
   immediately before touching a path — using the rule's declared root as the
   allowlist, never the scan result, which may be minutes old.

6. **The cleaner is an allowlist.** `CleanupCatalog` names exact directories;
   no pattern anywhere could expand to something unintended. A test fails the
   build on overlapping roots unless the overlap is declared reviewed.

7. **Nothing runs as root, and nothing is requested at launch.** No privileged
   helper, no `sudo`; every permission prompt follows a button the user pressed.

## Things that are easy to get wrong

- **`MenuBarExtra` must be declared before the `Window` scene**, or SwiftUI
  opens the window at launch and a menu bar utility silently runs a full
  dashboard nobody asked for.

- **`DockPolicy.promote()` runs before `openWindow`, never from the window's
  `onAppear`.** Changing the activation policy while a window is appearing makes
  AppKit tear that window straight back down a few seconds later.

- **`.fixedSize(horizontal: false, vertical: true)` inside a card that fills its
  row's height blanks the *entire window*** — sidebar included — while the
  accessibility tree still reports every element as present. Text wraps without
  it, so no height-filling card uses it.

- **Reading an observable property inside `App.body` invalidates the whole scene
  graph.** The menu bar readouts are stored properties, assigned only when the
  rendered string changes and read inside the label view. Worth ~20 % → ~3 %
  idle CPU.

- **`proc_pid_rusage` reports mach absolute time units** despite the field names
  `ri_user_time` / `ri_system_time`. On Intel a tick is 1 ns and the mistake is
  invisible; on Apple Silicon a tick is 41.67 ns, so treating ticks as
  nanoseconds under-reports every process by **24×**.

- **The status item's view is not a reliable lifetime.** macOS destroys and
  recreates it on menu bar auto-hide, full-screen cover and notch overflow. The
  sampling scope is owned by the app and released only when the user turns the
  readout off.

- **`Text("\(Image(systemName:)) 43%")` does not paint the symbol inside a
  `MenuBarExtra` label.** It reports it to accessibility and draws a blank gap.
  `MenuBarIcon` renders the whole readout into one template `NSImage`.

- **TCC grants are tied to the code signature, and the build signs ad-hoc.** Full
  Disk Access must be re-granted after every install and `SMAppService` refuses
  Open at Login. Neither is a bug; do not "fix" either. The signature genuinely
  differs between builds — two builds of one commit gave CDHash `3000f49c…` and
  `95f21efc…` — so this is not something a second build path made worse.

- **`--no-xcode` is a second bundle shape, deliberately.** It is assembled by
  hand around a SwiftPM binary: one architecture, no hardened runtime, no
  entitlements. It exists so nobody needs 4 GB of Xcode to run a 6 MB app. Do
  not hand its output to anyone else, and do not try to make it the release
  path. The SwiftPM product is named `mymac` in lower case so it cannot collide
  with the Xcode application target — two `MyMac` products in one build graph is
  what made `TEST_TARGET_NAME` resolve to the wrong one and broke every UI test.

### Things that are easy to get wrong *in the UI tests*

- **A SwiftUI `Table` is an `Outline`, not a `Table`.** `app.tables[...]` finds
  nothing. Its cells carry their text as `value`, not `label` — reading `label`
  returns a list of empty strings, which compares equal to itself and makes an
  ordering assertion pass while testing nothing.

- **Column headers are buttons that report themselves as not hittable**, so
  `click()` refuses. Click the centre coordinate instead.

- **`app.activate()` after `launch()`.** Without it the whole element tree comes
  back `Disabled` and nothing can be clicked.

- **Sampling has to stay frozen.** XCUITest waits for the app to go idle before
  answering a query, and a tree that redraws once a second never does. The
  readout, the sparklines and the process table each keep it busy on their own.

- **Do not write a UI test that presses a permission button.** A system prompt
  with nobody to dismiss it hangs the run until the job timeout.

- **Do not write a UI test for the uninstaller's Others tab.** Switching to it
  measures every installed package, spawning a package manager per entry, and
  XCUITest answers no query until the app goes idle — the test does not run
  slowly, it hangs, including the wait that was meant to let it settle. Cover
  that tab in `UninstallerSortingTests`, where it costs milliseconds.

- **Scope every query.** `descendants(matching: .any)` from the application
  walks the whole accessibility tree on every snapshot; against a few dozen rows
  that alone is enough to make a test unusable. Query inside the table, and by
  a concrete element type.

- **The launch flag is a pair, `-MyMacUITesting YES`.** The `NSUserDefaults`
  argument domain reads `-key value`, so a bare flag swallows the token after
  it — which is how a test silently loses the section it asked for.

## Code conventions

- Comments explain **why**, not **what**. Wherever there is a trade-off or a trap
  that has already been hit, write it down, at length if needed.
- Test names describe behaviour, not the function being called.
- No third-party dependencies. The project deliberately uses system frameworks
  only.
