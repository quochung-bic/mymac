import AppKit
import Testing
@testable import MyMacUI

/// The status item is drawn rather than composed, and the README makes two
/// promises about that drawing: the item keeps a constant width as the numbers
/// change, and two readouts stack instead of sitting side by side.
@MainActor
@Suite("Menu bar icon")
struct MenuBarIconTests {
    private func segment(_ text: String) -> MenuBarIcon.Segment {
        MenuBarIcon.Segment(symbol: "cpu", text: text)
    }

    /// "the item keeps a constant width without padding the string" — numbers
    /// are right-aligned in a slot sized for the widest value instead.
    @Test func widthDoesNotChangeWithTheValue() {
        let widths = ["0%", "7%", "42%", "100%"].map { MenuBarIcon.render([segment($0)]).size.width }
        #expect(Set(widths).count == 1, "a status item that reflows on every sample is jitter, got \(widths)")
    }

    @Test func twoReadoutsStackRatherThanSitSideBySide() {
        let single = MenuBarIcon.render([segment("100%")]).size
        let double = MenuBarIcon.render([segment("100%"),
                                         MenuBarIcon.Segment(symbol: "memorychip", text: "100%")]).size

        #expect(double.height == single.height, "the menu bar has one height to work with")
        #expect(double.width < single.width * 1.6,
                "stacked, not side by side: \(double.width) against \(single.width)")
    }

    /// With both readouts off the item is a single icon and nothing is sampled,
    /// so it must not still reserve room for a number.
    @Test func anIconWithNoTextIsNarrowerThanOneWithText() {
        let bare = MenuBarIcon.render([segment("")]).size.width
        let withText = MenuBarIcon.render([segment("42%")]).size.width
        #expect(bare < withText)
        #expect(bare > 0)
    }

    /// Template rendering is what lets macOS tint the item correctly in light
    /// mode, dark mode and while the menu is highlighted.
    @Test func theImageIsATemplateSoMacOSCanTintIt() {
        #expect(MenuBarIcon.render([segment("42%")]).isTemplate)
    }

    @Test func aThirdSegmentIsIgnoredRatherThanOverflowing() {
        let two = MenuBarIcon.render([segment("10%"), segment("20%")]).size
        let three = MenuBarIcon.render([segment("10%"), segment("20%"), segment("30%")]).size
        #expect(three == two, "the layout has room for two lines, so only two are drawn")
    }
}
