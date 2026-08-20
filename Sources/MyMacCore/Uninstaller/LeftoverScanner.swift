import Foundation

/// Finds the support files an application leaves behind.
///
/// Every location is an exact, documented place macOS puts per-app state, keyed
/// on the bundle identifier. Matching on the app's *name* is deliberately
/// limited to two folders where that is the established convention, because a
/// name match is a guess and a bundle identifier is not.
public enum LeftoverScanner {
    /// The directories searched, and therefore the only roots the uninstaller
    /// is ever allowed to delete from.
    public static func searchRoots(home: URL) -> [URL] {
        [
            "Application Support", "Caches", "Preferences", "Containers",
            "Group Containers", "Saved Application State", "HTTPStorages",
            "WebKit", "Logs", "Cookies", "LaunchAgents", "Application Scripts",
        ].map { home.appendingPathComponent("Library/\($0)") }
    }

    public static func scan(for item: InstalledItem,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [CleanupItem] {
        let library = home.appendingPathComponent("Library")
        var candidates: [URL] = []

        if let bundleIdentifier = item.bundleIdentifier, !bundleIdentifier.isEmpty {
            candidates += [
                library.appendingPathComponent("Application Support/\(bundleIdentifier)"),
                library.appendingPathComponent("Caches/\(bundleIdentifier)"),
                library.appendingPathComponent("Preferences/\(bundleIdentifier).plist"),
                library.appendingPathComponent("Containers/\(bundleIdentifier)"),
                library.appendingPathComponent("Saved Application State/\(bundleIdentifier).savedState"),
                library.appendingPathComponent("HTTPStorages/\(bundleIdentifier)"),
                library.appendingPathComponent("HTTPStorages/\(bundleIdentifier).binarycookies"),
                library.appendingPathComponent("WebKit/\(bundleIdentifier)"),
                library.appendingPathComponent("Cookies/\(bundleIdentifier).binarycookies"),
                library.appendingPathComponent("LaunchAgents/\(bundleIdentifier).plist"),
                library.appendingPathComponent("Application Scripts/\(bundleIdentifier)"),
                library.appendingPathComponent("Logs/\(bundleIdentifier)"),
            ]
            // Group containers are prefixed with a team identifier, so they can
            // only be found by looking for the bundle identifier inside a name.
            candidates += matches(in: library.appendingPathComponent("Group Containers"),
                                  containing: bundleIdentifier)
        }

        // Two folders where apps conventionally use their display name.
        candidates += [
            library.appendingPathComponent("Application Support/\(item.name)"),
            library.appendingPathComponent("Logs/\(item.name)"),
        ]

        var results: [CleanupItem] = []
        var seen = Set<String>()
        for url in candidates {
            try Task.checkCancellation()
            let path = url.standardizedFileURL.path
            guard !seen.contains(path), FileManager.default.fileExists(atPath: path) else { continue }
            seen.insert(path)

            let measured = try DirectorySizer.measure(url)
            results.append(CleanupItem(
                url: url,
                name: url.lastPathComponent,
                detail: url.deletingLastPathComponent().path,
                size: measured.bytes,
                modified: measured.newestModification
            ))
        }
        return results.sorted { $0.size > $1.size }
    }

    private static func matches(in directory: URL, containing needle: String) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.lastPathComponent.contains(needle) }
    }
}
