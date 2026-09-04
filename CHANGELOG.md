# Changelog

All notable changes to this project are documented here, in the style of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Nothing has been released yet, so everything so far sits under Unreleased.

## [Unreleased]

### Added

- **`--no-xcode`**, on both `build.sh` and `install.sh`. Builds a runnable
  `MyMac.app` through SwiftPM alone, which the Command Line Tools can do without
  Xcode — 4 GB of toolchain was a lot to ask for a 6 MB bundle. The result is
  for the machine that built it: one architecture, no hardened runtime, no
  entitlements, and it cannot run the UI tests. Build without the flag for a
  copy meant for anyone else.

- **UI tests.** `MyMacUITests` drives the real window through XCUITest, which
  is the only layer that can catch a defect between a click and the model.
  `-MyMacUITesting YES` promotes the app from `LSUIElement` to `.regular`,
  keeps the window open, and freezes sampling so the app goes idle where
  XCUITest can query it; `-MyMacUITestSection <name>` opens it on a section.
- **An Xcode project**, `MyMac.xcodeproj`. Thin on purpose: filesystem-
  synchronized groups mean adding a source file needs no edit to it, and every
  build setting lives in `Configs/*.xcconfig` with an empty `buildSettings` in
  the project file.
- **`Scripts/build.sh`** with `--debug`, `--test`, `--test-only`, `--unit-only`,
  `--ui-only`, `--filter`, `--clean`, `--output`, `--quiet` and `--help`. Its
  body is byte-identical with the Caffeinate repository's, so the two projects
  answer "how do I build, how do I test" the same way.
- **`CLAUDE.md`** and **`docs/ARCHITECTURE.md`**, carrying the invariants and the
  traps that had been living only in the README.
- **Application icons in the uninstaller**, cached, and column header sorting
  for both of its lists.
- **A one-command install** for a fresh clone, and an app icon generated from
  source rather than checked in as an opaque binary.

### Changed

- **`Scripts/build.sh` replaces `Scripts/build-app.sh`**, and the app is built
  by `xcodebuild` rather than assembled by hand around a SwiftPM executable.
  There is now exactly one way to produce `MyMac.app`. Two ways would have
  produced two different bundles: the hand-assembled one had no hardened
  runtime and no entitlements, and a different signature means a different TCC
  identity, so Full Disk Access would have to be granted separately to each.
- **`MYMAC_UNIVERSAL=0` becomes `--debug`**, and `MYMAC_DEST` becomes
  `--destination`. `MYMAC_DEST` still works, with a deprecation warning, because
  the README published it.
- **`Scripts/make-icon.swift` is now `Scripts/GenerateAppIcon.swift`**, matching
  the other repository.
- **The SwiftPM test target `MyMacUITests` is now `MyMacUIUnitTests`.** It holds
  unit tests of the `MyMacUI` library and never contained a UI test; the name
  now belongs to the XCUITest bundle, where Xcode expects it.
- **Building requires full Xcode**, not just the command line tools, because the
  app and its UI tests are built with `xcodebuild`.

### Fixed

- **CI never ran on push.** The workflow triggered on `main`; the branch is
  `master`, and had been for the repository's whole life.
- **A newly retained sampling scope waited for the next tick.** Opening the
  Processes page could sit empty for up to three seconds before its first row
  appeared.
- **Uninstaller column headers now sort**, and a UI test now proves it by
  clicking them rather than the model's unit tests implying it.
- **The sorting-cost budget no longer fails on a busy machine.** It is a
  wall-clock measurement, so a build or a UI test run in the background made it
  report five times slower and the suite went red over nothing. It now runs
  only where the number means something.
