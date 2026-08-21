import AppKit
import MyMacCore
import SwiftUI

/// The icon an installed item actually shows in the Finder.
///
/// Reading one means opening the bundle on disk, and `Table` asks for a row's
/// content again on every scroll and every click on a header. Held here so a
/// list of a hundred applications reads each icon once instead of once per
/// redraw.
@MainActor
enum AppIconCache {
    private static var icons: [String: NSImage] = [:]

    /// `nil` for anything that is not an application bundle, and for a bundle
    /// that has been removed since the list was read — `NSWorkspace` answers a
    /// generic placeholder for a path that no longer exists, and caching that
    /// would keep it around for a path that comes back.
    static func icon(for item: InstalledItem) -> NSImage? {
        guard item.source == .application else { return nil }
        let path = item.location.path
        if let cached = icons[path] { return cached }
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    /// Dropped when the list is read again: an app updated in place keeps its
    /// path and can arrive with a new icon.
    static func forget() { icons.removeAll() }
}

/// An item's own icon, falling back to the symbol for the kind of thing it is:
/// a package has no bundle to read one from, and neither does an application
/// that was uninstalled behind this app's back.
struct InstalledItemIcon: View {
    let item: InstalledItem
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let icon = AppIconCache.icon(for: item) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: item.source.symbol)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
                    .padding(size * 0.1)
            }
        }
        .frame(width: size, height: size)
        // The name is right beside it; the icon repeats what it says.
        .accessibilityHidden(true)
    }
}
