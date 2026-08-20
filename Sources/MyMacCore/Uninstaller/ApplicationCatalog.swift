import Foundation

/// Lists installed applications by reading bundles, not Launch Services.
///
/// Deliberately fast: only each bundle's `Info.plist` is read, so the list
/// appears immediately. Sizes are measured afterwards, because walking
/// /Applications means walking every framework inside every app.
public enum ApplicationCatalog {
    public static func searchLocations(home: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
        ]
    }

    /// Apple's own apps are excluded: they are managed by macOS, several cannot
    /// be removed at all, and offering to delete them would be irresponsible.
    static func isSystemApplication(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier.hasPrefix("com.apple.")
    }

    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [InstalledItem] {
        var seen = Set<String>()
        var items: [InstalledItem] = []

        for location in searchLocations(home: home) {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: location,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for url in contents where url.pathExtension == "app" {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
                guard let item = application(at: url), !seen.contains(item.id) else { continue }
                seen.insert(item.id)
                items.append(item)
            }
        }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func application(at url: URL) -> InstalledItem? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        let info = (try? Data(contentsOf: plist)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        } ?? [:]

        let bundleIdentifier = info["CFBundleIdentifier"] as? String
        guard !isSystemApplication(bundleIdentifier: bundleIdentifier) else { return nil }

        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let version = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)

        return InstalledItem(
            id: "app:\(url.path)",
            name: name,
            version: version,
            source: .application,
            location: url,
            bundleIdentifier: bundleIdentifier
        )
    }
}
