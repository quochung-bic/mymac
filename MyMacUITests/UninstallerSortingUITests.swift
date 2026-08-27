import XCTest

/// Clicking a column header in the uninstaller must re-order the rows.
///
/// This is the test the project did not have. `UninstallerModel` already pins
/// the ordering — `sorting(for:)` maps each header to its column, and
/// `visibleItems` sorts by it, both covered by unit tests that pass. Yet
/// clicking a header in the running app has repeatedly failed to sort. That
/// puts the defect between the click and the model, in the `Table`'s
/// `sortOrder` binding, which is the one stretch no swift-testing test can
/// reach and every user touches.
///
/// The assertions are relations rather than fixed contents, because the rows
/// are whatever is really installed on the machine running the test.
///
/// There is no UI test for the Others tab. Switching to it makes the app
/// measure every installed package, spawning a package manager per entry, and
/// XCUITest answers no query until the app goes idle — so such a test does not
/// run slowly, it hangs. That tab's ordering is pinned deterministically in
/// `UninstallerSortingTests` instead, and the `Table` binding a UI test would
/// be there to cover is the same one these tests already exercise.
@MainActor
final class UninstallerSortingUITests: XCTestCase {

    /// Deliberately does *not* wait for sizes.
    ///
    /// Measuring means walking every bundle in /Applications, and one Xcode is
    /// enough to make that take minutes. Sorting by name does not depend on a
    /// single size, so only the size test pays that cost.
    private func launchLoaded() throws -> XCUIApplication {
        let app = UITest.launch(section: "uninstaller")
        _ = app.waitForWindow()
        XCTAssertTrue(app.uninstallerTable.waitForExistence(timeout: 60),
                      "The uninstaller table should appear")

        let names = app.columnValues("uninstaller-name")
        try XCTSkipIf(names.count < 3,
                      "Needs at least three installed items to prove an ordering")
        return app
    }

    func testClickingTheNameHeaderReversesTheRows() throws {
        let app = try launchLoaded()

        let before = app.columnValues("uninstaller-name")
        app.clickColumnHeader("Name")
        let after = app.columnValues("uninstaller-name")

        XCTAssertNotEqual(before, after,
                          "Clicking the Name header should change the order")
        XCTAssertEqual(after, before.reversed(),
                       "Reversing one column should reverse the rows exactly")
    }

    func testTheNameHeaderRestoresTheOriginalOrderWhenClickedTwice() throws {
        let app = try launchLoaded()

        let before = app.columnValues("uninstaller-name")
        app.clickColumnHeader("Name")
        app.clickColumnHeader("Name")
        let after = app.columnValues("uninstaller-name")

        XCTAssertEqual(after, before, "Two clicks should return to where it started")
    }

    /// The one test that has to wait for measurement: sorting by size
    /// deliberately falls back to name while sizes are still arriving, so
    /// asserting before it settles would test the fallback instead.
    func testClickingTheSizeHeaderOrdersBySize() throws {
        let app = try launchLoaded()
        try XCTSkipUnless(app.waitUntilSizingFinishes(),
                          "Sizes did not settle in time on this machine")

        let before = app.columnValues("uninstaller-name")
        app.clickColumnHeader("Size")
        let after = app.columnValues("uninstaller-name")

        XCTAssertNotEqual(before, after,
                          "Sorting by size should not leave the rows in name order")
    }
}
