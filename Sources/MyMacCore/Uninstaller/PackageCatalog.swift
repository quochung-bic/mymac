import Foundation

/// Lists globally installed packages by reading each manager's install root.
///
/// No subprocess is involved in listing: every manager here lays its packages
/// out on disk in a documented shape, and reading that directly is faster,
/// cannot be broken by a change in CLI output, and works even when the tool
/// itself is missing from the app's `PATH`.
public enum PackageCatalog {
    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [InstalledItem] {
        PackageEcosystem.allCases.flatMap { scan($0, home: home) }
    }

    /// Reads **every** install root that exists, not just the first.
    ///
    /// Reading only the first silently halved the list on a very ordinary
    /// setup: an Apple Silicon Mac running an arm64 Homebrew in `/opt/homebrew`
    /// alongside an x86_64 one under Rosetta in `/usr/local`. Nothing said the
    /// list was partial, so a package that was never removed looked removed.
    public static func scan(_ ecosystem: PackageEcosystem,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [InstalledItem] {
        var seen = Set<String>()
        var items: [InstalledItem] = []

        for root in ecosystem.roots(home: home) where directoryExists(root) {
            let found: [InstalledItem]
            switch ecosystem.layout {
            case .versionedDirectory: found = versionedPackages(in: root, ecosystem: ecosystem)
            case .nodeModules: found = nodePackages(in: root, ecosystem: ecosystem)
            case .pythonDistInfo: found = pythonPackages(under: root, ecosystem: ecosystem)
            case .manifestDependencies: found = manifestPackages(in: root, ecosystem: ecosystem)
            }
            // Two roots can resolve to the same directory through a symlink;
            // the location is what makes an entry distinct, not the name, since
            // the same package legitimately exists under both prefixes.
            for item in found where seen.insert(item.id).inserted {
                items.append(item)
            }
        }
        return items
    }

    /// Exposed so the node-modules layout can be tested against a fixture
    /// rather than whatever happens to be installed on the machine.
    static func scanNodeModulesForTesting(root: URL, ecosystem: PackageEcosystem) -> [InstalledItem] {
        nodePackages(in: root, ecosystem: ecosystem)
    }

    // MARK: - Layouts

    private static func versionedPackages(in root: URL, ecosystem: PackageEcosystem) -> [InstalledItem] {
        children(of: root).compactMap { url in
            let versions = children(of: url).map(\.lastPathComponent).sorted()
            return item(name: url.lastPathComponent, version: versions.last,
                        location: url, ecosystem: ecosystem)
        }
    }

    private static func nodePackages(in root: URL, ecosystem: PackageEcosystem) -> [InstalledItem] {
        children(of: root).flatMap { url -> [InstalledItem] in
            let component = url.lastPathComponent
            guard !component.hasPrefix(".") else { return [] }
            // A scope directory holds packages; it is not one itself.
            guard component.hasPrefix("@") else {
                return [item(name: component, version: packageVersion(at: url),
                             location: url, ecosystem: ecosystem)]
            }
            return children(of: url).map { scoped in
                item(name: "\(component)/\(scoped.lastPathComponent)",
                     version: packageVersion(at: scoped),
                     location: scoped, ecosystem: ecosystem)
            }
        }
    }

    /// Python roots are versioned (`lib/python3.13/site-packages`), so the
    /// interpreter directories are expanded before the packages are read.
    private static func pythonPackages(under root: URL, ecosystem: PackageEcosystem) -> [InstalledItem] {
        let siteDirectories = children(of: root)
            .filter { $0.lastPathComponent.hasPrefix("python") || $0.lastPathComponent.hasPrefix("3.") }
            .flatMap { [$0.appendingPathComponent("site-packages"),
                        $0.appendingPathComponent("lib/python/site-packages")] }
            .filter(directoryExists)

        return siteDirectories.flatMap { directory in
            children(of: directory).compactMap { url -> InstalledItem? in
                guard url.pathExtension == "dist-info" else { return nil }
                let stem = url.deletingPathExtension().lastPathComponent
                let parts = stem.split(separator: "-", maxSplits: 1)
                guard let name = parts.first else { return nil }
                return item(name: String(name),
                            version: parts.count > 1 ? String(parts[1]) : nil,
                            location: url.deletingLastPathComponent().appendingPathComponent(String(name)),
                            ecosystem: ecosystem)
            }
        }
    }

    /// Top-level packages named by a manifest, with each version read from the
    /// installed copy rather than from the manifest's version range.
    private static func manifestPackages(in root: URL, ecosystem: PackageEcosystem) -> [InstalledItem] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = json["dependencies"] as? [String: Any]
        else { return [] }

        let modules = root.appendingPathComponent("node_modules")
        return dependencies.keys.sorted().map { name in
            let location = modules.appendingPathComponent(name)
            return item(name: name, version: packageVersion(at: location),
                        location: location, ecosystem: ecosystem)
        }
    }

    // MARK: - Helpers

    /// Keyed on the location, not the name: with every prefix scanned, the same
    /// package can legitimately be installed twice — an arm64 copy and an
    /// x86_64 one — and two rows sharing an identity would collide in the table.
    private static func item(name: String, version: String?, location: URL,
                             ecosystem: PackageEcosystem) -> InstalledItem {
        InstalledItem(id: "\(ecosystem.rawValue):\(location.standardizedFileURL.path)",
                      name: name, version: version,
                      source: .package(ecosystem), location: location)
    }

    private static func packageVersion(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["version"] as? String
    }

    private static func children(of url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
