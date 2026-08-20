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

    public static func scan(_ ecosystem: PackageEcosystem,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [InstalledItem] {
        guard let root = ecosystem.roots(home: home).first(where: directoryExists) else { return [] }
        switch ecosystem.layout {
        case .versionedDirectory: return versionedPackages(in: root, ecosystem: ecosystem)
        case .nodeModules: return nodePackages(in: root, ecosystem: ecosystem)
        case .pythonDistInfo: return pythonPackages(under: root, ecosystem: ecosystem)
        case .manifestDependencies: return manifestPackages(in: root, ecosystem: ecosystem)
        }
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

    private static func item(name: String, version: String?, location: URL,
                             ecosystem: PackageEcosystem) -> InstalledItem {
        InstalledItem(id: "\(ecosystem.rawValue):\(name)", name: name, version: version,
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
