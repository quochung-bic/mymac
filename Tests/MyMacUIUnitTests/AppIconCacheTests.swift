import AppKit
import Foundation
import MyMacCore
import Testing
@testable import MyMacUI

/// The list shows each application's own icon. What is worth pinning is when it
/// must not: a package has no bundle to read one from, and a path that is gone
/// answers a generic placeholder that would be wrong to keep.
@MainActor
@Suite("Application icons")
struct AppIconCacheTests {
    private func item(at path: String, source: InstalledSource = .application) -> InstalledItem {
        InstalledItem(id: path, name: URL(fileURLWithPath: path).lastPathComponent,
                      version: nil, source: source,
                      location: URL(fileURLWithPath: path), bundleIdentifier: "test.icon")
    }

    /// Ships with every macOS install, so the test does not depend on what this
    /// particular Mac has in /Applications.
    private let systemApp = "/System/Applications/Calculator.app"

    @Test func readsTheIconOfAnApplicationOnDisk() throws {
        try #require(FileManager.default.fileExists(atPath: systemApp))
        AppIconCache.forget()

        let icon = AppIconCache.icon(for: item(at: systemApp))
        #expect(icon != nil)
        #expect(icon?.size.width ?? 0 > 0)
    }

    @Test func packagesHaveNoBundleAndSoNoIcon() {
        AppIconCache.forget()
        let package = item(at: "/opt/homebrew/Cellar/wget", source: .package(.homebrew))
        #expect(AppIconCache.icon(for: package) == nil)
    }

    /// An app removed since the list was read answers `nil` rather than the
    /// generic document placeholder `NSWorkspace` hands back for any path.
    @Test func aBundleThatIsGoneGetsTheSymbolInstead() {
        AppIconCache.forget()
        #expect(AppIconCache.icon(for: item(at: "/Applications/NoSuchApp.app")) == nil)
    }

    @Test func theSameBundleIsReadOnce() throws {
        try #require(FileManager.default.fileExists(atPath: systemApp))
        AppIconCache.forget()

        let first = AppIconCache.icon(for: item(at: systemApp))
        let second = AppIconCache.icon(for: item(at: systemApp))
        #expect(first === second, "a second look must come from the cache")
    }

    @Test func refreshingDropsWhatWasCached() throws {
        try #require(FileManager.default.fileExists(atPath: systemApp))
        AppIconCache.forget()

        let first = AppIconCache.icon(for: item(at: systemApp))
        AppIconCache.forget()
        let afterRefresh = AppIconCache.icon(for: item(at: systemApp))
        #expect(first !== afterRefresh, "a refresh must read the bundle again")
    }
}
