import XCTest

/// Shared launch helpers for the UI tests.
///
/// The constants below are duplicated from `LaunchEnvironment` in `MyMacUI` on
/// purpose: a UI test bundle runs out of process and cannot import the app, so
/// there is no way to share them. Changing one means changing both.
enum UITest {
    static let testingArgument = "-MyMacUITesting"
    static let sectionArgument = "-MyMacUITestSection"

    /// Launches the app straight onto one section.
    ///
    /// The two menu bar readouts are switched off through the real preference
    /// keys. They are the one part of the interface that keeps redrawing even
    /// with sampling frozen, and a busy application is one XCUITest never sees
    /// go idle.
    @MainActor
    static func launch(section: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            testingArgument, "YES",
            sectionArgument, section,
            "-menuBarShowsCPU", "NO",
            "-menuBarShowsMemory", "NO",
        ]
        app.launch()
        return app
    }
}

@MainActor
extension XCUIApplication {
    /// The app's own window. Waiting for it before querying anything inside is
    /// not optional: the first accessibility snapshot can land before any
    /// window exists, and it does not retry on its own.
    func waitForWindow(timeout: TimeInterval = 30, file: StaticString = #filePath,
                       line: UInt = #line) -> XCUIElement {
        let window = windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: timeout),
                      "The main window should appear", file: file, line: line)
        // Activate only once the window is up. The app starts as an
        // `LSUIElement` in "Running Background" and promotes itself to
        // `.regular` when the menu bar label appears; calling `activate()`
        // before that races the promotion and fails outright. Activating
        // matters because an app that is not frontmost reports its whole
        // element tree as Disabled, and nothing in it can be clicked.
        activate()
        return window
    }

    /// The uninstaller's list.
    ///
    /// A SwiftUI `Table` surfaces as an `Outline` on macOS, not a `Table` —
    /// checked against the real accessibility tree, not assumed.
    var uninstallerTable: XCUIElement {
        outlines["uninstaller-table"]
    }

    /// The on-screen order of one column, top to bottom.
    ///
    /// Two things here are load-bearing, both learned the hard way:
    ///
    /// The cells carry their text as `value`, not `label`. Reading `label`
    /// returns a list of empty strings, which compares equal to itself and
    /// makes every ordering assertion pass while testing nothing.
    ///
    /// The query is scoped to the table and to `staticTexts`. Going through
    /// `descendants(matching: .any)` from the application walks the whole
    /// accessibility tree for every snapshot; against the Others tab's ~90 rows
    /// that does not finish in any useful time.
    func columnValues(_ identifier: String) -> [String] {
        uninstallerTable
            .staticTexts
            .matching(identifier: identifier)
            .allElementsBoundByIndex
            .compactMap { $0.value as? String }
    }

    /// Clicks a column header.
    ///
    /// The header cells surface as plain buttons carrying the column title, but
    /// they report themselves as not hittable, so `click()` refuses. Clicking
    /// the centre coordinate goes through: the button is on screen and visible,
    /// only AppKit's hit-testing of a table header disagrees. Verified against
    /// the real accessibility tree.
    func clickColumnHeader(_ title: String, file: StaticString = #filePath,
                           line: UInt = #line) {
        let header = buttons[title].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10),
                      "A '\(title)' column header should exist",
                      file: file, line: line)
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    /// Waits until the uninstaller has finished measuring sizes, and reports
    /// whether it actually settled.
    ///
    /// Two reasons this has to be waited out rather than queried through.
    /// Sorting by size deliberately falls back to name while measurements are
    /// still arriving, so asserting early tests the wrong thing. And measuring
    /// spawns a package manager per entry, which keeps the app busy — XCUITest
    /// answers no query until the app goes idle, so querying during the storm
    /// blocks until the query's own timeout rather than returning something
    /// wrong. On a machine with a lot of installed packages this genuinely
    /// takes minutes, so the caller is told rather than left to hang.
    @discardableResult
    func waitUntilSizingFinishes(timeout: TimeInterval = 240) -> Bool {
        let sizing = staticTexts["uninstaller-sizing"]
        guard sizing.exists else { return true }
        let gone = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: gone, object: sizing)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
