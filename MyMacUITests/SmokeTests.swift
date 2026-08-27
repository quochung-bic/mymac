import XCTest

/// The cheapest possible check that the app comes up and renders.
///
/// It exists mostly to fail first. If the harness itself is broken — the
/// activation policy, the launch flag, the window — everything else in this
/// bundle fails too, and it is worth having one test whose failure means
/// exactly that and nothing more.
@MainActor
final class SmokeTests: XCTestCase {

    func testTheWindowOpensOnTheRequestedSection() {
        let app = UITest.launch(section: "uninstaller")
        let window = app.waitForWindow()
        XCTAssertEqual(window.title, "Uninstaller",
                       "The launch argument should choose the section")
    }

    /// The dashboard's window is titled from its `navigationTitle`, which reads
    /// "System Status" rather than repeating the sidebar's word for it.
    func testTheDashboardIsTheDefaultSection() {
        let app = UITest.launch(section: "dashboard")
        let window = app.waitForWindow()
        XCTAssertEqual(window.title, "System Status")
    }
}
