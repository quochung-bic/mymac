import Foundation
import MyMacCore
import Testing
@testable import MyMacUI

/// The uninstaller's column headers did nothing: sorting lived in a toolbar
/// picker, so clicking "Name", "Size" or the location header left the list
/// exactly as it was. The headers now drive the order, and these pin both the
/// mapping and the two orderings that are easy to get wrong — an item whose
/// size is still being measured, and one that could not be measured at all.
@MainActor
@Suite("Uninstaller table sorting")
struct UninstallerSortingTests {
    private func item(_ name: String, location: String = "/Applications",
                      size: Int64? = nil) -> InstalledItem {
        InstalledItem(id: "\(location)/\(name)", name: name, version: nil,
                      source: .application,
                      location: URL(fileURLWithPath: "\(location)/\(name).app"),
                      bundleIdentifier: "test.\(name)", size: size)
    }

    private func mapped(_ order: [KeyPathComparator<InstalledItem>]) -> (key: UninstallerModel.Order, ascending: Bool) {
        UninstallerModel.sorting(for: order)
    }

    @Test func headersMapToTheColumnTheyLabel() {
        #expect(mapped([KeyPathComparator(\.name, order: .forward)]).key == .name)
        #expect(mapped([KeyPathComparator(\.origin, order: .forward)]).key == .origin)
        #expect(mapped([KeyPathComparator(\.sizeSortValue, order: .reverse)]).key == .size)
    }

    @Test func directionFollowsTheHeader() {
        #expect(mapped([KeyPathComparator(\.name, order: .forward)]).ascending)
        #expect(mapped([KeyPathComparator(\.name, order: .reverse)]).ascending == false)
    }

    @Test func noOrderAtAllFallsBackToAlphabetical() {
        let result = mapped([])
        #expect(result.key == .name)
        #expect(result.ascending)
    }

    @Test func clickingTheNameHeaderReversesTheList() {
        let model = UninstallerModel()
        model.replaceItemsForTesting([item("Bravo"), item("Alpha"), item("Charlie")])

        #expect(model.visibleItems.map(\.name) == ["Alpha", "Bravo", "Charlie"])
        model.sortOrder = [KeyPathComparator(\InstalledItem.name, order: .reverse)]
        #expect(model.visibleItems.map(\.name) == ["Charlie", "Bravo", "Alpha"])
    }

    @Test func sizeHeaderOrdersBySizeInBothDirections() {
        let model = UninstallerModel()
        model.replaceItemsForTesting([item("Alpha", size: 10), item("Bravo", size: 300),
                                      item("Charlie", size: 200)])

        model.sortOrder = [KeyPathComparator(\InstalledItem.sizeSortValue, order: .reverse)]
        #expect(model.visibleItems.map(\.name) == ["Bravo", "Charlie", "Alpha"])
        model.sortOrder = [KeyPathComparator(\InstalledItem.sizeSortValue, order: .forward)]
        #expect(model.visibleItems.map(\.name) == ["Alpha", "Charlie", "Bravo"])
    }

    /// An unmeasured row shows "…" instead of a figure. It belongs at the
    /// bottom of a size order whichever way the column points, rather than
    /// leading an ascending sort because nothing is smaller than nothing.
    @Test func unmeasuredItemsStayLastWhicheverWayTheColumnPoints() {
        let model = UninstallerModel()
        model.replaceItemsForTesting([item("Alpha"), item("Bravo", size: 300),
                                      item("Charlie", size: 10)])

        for order: SortOrder in [.forward, .reverse] {
            model.sortOrder = [KeyPathComparator(\InstalledItem.sizeSortValue, order: order)]
            #expect(model.visibleItems.last?.name == "Alpha",
                    "unmeasured must sort last with order \(order)")
        }
    }

    /// The location column shows a path for applications; sorting it groups
    /// everything that lives in the same folder, with names settling ties.
    @Test func locationHeaderGroupsByFolderThenName() {
        let model = UninstallerModel()
        model.replaceItemsForTesting([
            item("Zulu", location: "/Applications"),
            item("Alpha", location: "/Applications/Utilities"),
            item("Bravo", location: "/Applications"),
        ])

        model.sortOrder = [KeyPathComparator(\InstalledItem.origin, order: .forward)]
        #expect(model.visibleItems.map(\.name) == ["Bravo", "Zulu", "Alpha"])
    }

    private func package(_ name: String, _ ecosystem: PackageEcosystem = .homebrew,
                         size: Int64? = nil) -> InstalledItem {
        InstalledItem(id: "\(ecosystem.rawValue)/\(name)", name: name, version: nil,
                      source: .package(ecosystem),
                      location: URL(fileURLWithPath: "/opt/homebrew/\(name)"),
                      bundleIdentifier: nil, size: size)
    }

    /// The Others tab sorts the same way Applications does.
    ///
    /// This is pinned here rather than in a UI test on purpose. Switching to
    /// that tab makes the app measure every installed package, spawning a
    /// package manager per entry, and XCUITest answers no query until the app
    /// goes idle — so a UI test for it does not run slowly, it hangs. The
    /// `Table` binding those tests exist to cover is the same one the
    /// Applications tab already proves.
    @Test func theOthersScopeSortsLikeApplications() {
        let model = UninstallerModel()
        model.replaceItemsForTesting([
            item("Zed application"),
            package("bravo"),
            package("alpha"),
            package("charlie"),
        ])
        model.scope = .packages

        #expect(model.visibleItems.map(\.name) == ["alpha", "bravo", "charlie"])
        model.sortOrder = [KeyPathComparator(\InstalledItem.name, order: .reverse)]
        #expect(model.visibleItems.map(\.name) == ["charlie", "bravo", "alpha"])
    }

    /// Each tab shows only its own kind, so a sort in one cannot pull rows in
    /// from the other.
    @Test func eachScopeShowsOnlyItsOwnKind() {
        let model = UninstallerModel()
        model.replaceItemsForTesting([item("An app"), package("a-package")])

        model.scope = .applications
        #expect(model.visibleItems.map(\.name) == ["An app"])
        model.scope = .packages
        #expect(model.visibleItems.map(\.name) == ["a-package"])
    }

}
