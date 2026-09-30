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

    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            caskrooms: [URL]? = nil) -> [InstalledItem] {
        var seen = Set<String>()
        var items: [InstalledItem] = []
        let casks = casksByBundle(in: caskrooms ?? PackageEcosystem.homebrewCask.roots(home: home))

        for location in searchLocations(home: home) {
            for url in bundles(in: location) {
                let cask = casks[PathSafety.canonicalPath(url.path)]
                guard let item = application(at: url, cask: cask), !seen.contains(item.id) else { continue }
                seen.insert(item.id)
                items.append(item)
            }
        }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Bundles directly inside `directory`, and one folder further down —
    /// Python.org and Adobe install into a product folder, not straight into
    /// /Applications. The extra level never enters a bundle: a helper shipped
    /// inside an application is part of it, and removing one guts the app.
    private static func bundles(in directory: URL) -> [URL] {
        func children(of url: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []).filter {
                (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
            }
        }

        var found: [URL] = []
        for url in children(of: directory) {
            if url.pathExtension == "app" {
                found.append(url)
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                found += children(of: url).filter { $0.pathExtension == "app" }
            }
        }
        return found
    }

    /// Which bundles a Homebrew cask put in place, keyed on the bundle's
    /// resolved path. A cask keeps a symlink to its artifact inside
    /// `Caskroom/<token>/<version>/`, so the link is followed rather than the
    /// names compared — a name match is a guess, a link is not.
    static func casksByBundle(in caskrooms: [URL]) -> [String: InstalledItem.Cask] {
        let manager = FileManager.default
        var casks: [String: InstalledItem.Cask] = [:]
        for caskroom in caskrooms {
            let tokens = (try? manager.contentsOfDirectory(
                at: caskroom, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            for record in tokens {
                let versions = (try? manager.contentsOfDirectory(
                    at: record, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                )) ?? []
                for version in versions {
                    let artifacts = (try? manager.contentsOfDirectory(
                        at: version, includingPropertiesForKeys: [.isSymbolicLinkKey],
                        options: [.skipsHiddenFiles]
                    )) ?? []
                    for artifact in artifacts where artifact.pathExtension == "app" {
                        guard (try? artifact.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                            .isSymbolicLink == true else { continue }
                        casks[PathSafety.canonicalPath(artifact.path)] =
                            .init(token: record.lastPathComponent, record: record)
                    }
                }
            }
        }
        return casks
    }

    static func application(at url: URL, cask: InstalledItem.Cask? = nil) -> InstalledItem? {
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
            bundleIdentifier: bundleIdentifier,
            cask: cask
        )
    }
}
