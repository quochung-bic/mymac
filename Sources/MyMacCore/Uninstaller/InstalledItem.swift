import Foundation

/// Where something was installed from.
public enum InstalledSource: Sendable, Hashable, Identifiable {
    case application
    case package(PackageEcosystem)

    public var id: String {
        switch self {
        case .application: "application"
        case .package(let ecosystem): ecosystem.rawValue
        }
    }

    public var title: String {
        switch self {
        case .application: "Applications"
        case .package(let ecosystem): ecosystem.title
        }
    }

    public var symbol: String {
        switch self {
        case .application: "app.badge"
        case .package(let ecosystem): ecosystem.symbol
        }
    }
}

public struct InstalledItem: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let version: String?
    public let source: InstalledSource
    /// The bundle or package directory on disk.
    public let location: URL
    /// Applications only; the key every leftover is found by.
    public let bundleIdentifier: String?
    /// `nil` until measured — sizes are computed after the list appears, so a
    /// folder like /Applications does not have to be walked before anything can
    /// be shown.
    public var size: Int64?

    public init(id: String, name: String, version: String?, source: InstalledSource,
                location: URL, bundleIdentifier: String? = nil, size: Int64? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.source = source
        self.location = location
        self.bundleIdentifier = bundleIdentifier
        self.size = size
    }
}

/// The package managers this app knows how to read and to drive.
public enum PackageEcosystem: String, Sendable, CaseIterable, Identifiable {
    case homebrew
    case homebrewCask
    case npm
    case pnpm
    case yarn
    case bun
    case python

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .homebrew: "Homebrew"
        case .homebrewCask: "Homebrew Casks"
        case .npm: "npm"
        case .pnpm: "pnpm"
        case .yarn: "Yarn"
        case .bun: "Bun"
        case .python: "Python"
        }
    }

    public var symbol: String {
        switch self {
        case .homebrew, .homebrewCask: "shippingbox"
        case .npm, .pnpm, .yarn, .bun: "cube.box"
        case .python: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// How packages are laid out inside a root directory.
    enum Layout {
        /// `<root>/<name>/<version>/…`
        case versionedDirectory
        /// `<root>/<name>` and `<root>/@scope/<name>`, version from package.json.
        case nodeModules
        /// `<root>/<Name>-<Version>.dist-info`
        case pythonDistInfo
        /// The names listed in `<root>/package.json`. Yarn v1 hoists every
        /// transitive dependency into one flat `node_modules`, so reading that
        /// directory would report hundreds of packages the user never asked
        /// for — and uninstalling one would break the package that needs it.
        case manifestDependencies
    }

    var layout: Layout {
        switch self {
        case .homebrew, .homebrewCask: .versionedDirectory
        case .npm, .pnpm, .bun: .nodeModules
        case .yarn: .manifestDependencies
        case .python: .pythonDistInfo
        }
    }

    /// Candidate install roots, most likely first. Directories that do not
    /// exist are skipped, which is also how an absent tool is detected.
    func roots(home: URL) -> [URL] {
        let brewPrefixes = ["/opt/homebrew", "/usr/local"].map(URL.init(fileURLWithPath:))
        switch self {
        case .homebrew:
            return brewPrefixes.map { $0.appendingPathComponent("Cellar") }
        case .homebrewCask:
            return brewPrefixes.map { $0.appendingPathComponent("Caskroom") }
        case .npm:
            return brewPrefixes.map { $0.appendingPathComponent("lib/node_modules") }
                + [home.appendingPathComponent(".npm-global/lib/node_modules")]
        case .pnpm:
            return [home.appendingPathComponent("Library/pnpm/global/5/node_modules"),
                    home.appendingPathComponent(".local/share/pnpm/global/5/node_modules")]
        case .yarn:
            return [home.appendingPathComponent(".config/yarn/global"),
                    home.appendingPathComponent(".yarn/global")]
        case .bun:
            return [home.appendingPathComponent(".bun/install/global/node_modules")]
        case .python:
            return brewPrefixes.map { $0.appendingPathComponent("lib") }
                + [home.appendingPathComponent("Library/Python")]
        }
    }

    /// Executables that can perform the uninstall, most likely first.
    public func executables(home: URL) -> [URL] {
        let names: [String]
        switch self {
        case .homebrew, .homebrewCask: names = ["brew"]
        case .npm: names = ["npm"]
        case .pnpm: names = ["pnpm"]
        case .yarn: names = ["yarn"]
        case .bun: names = ["bun"]
        case .python: names = ["pip3", "pip"]
        }
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                           home.appendingPathComponent(".bun/bin").path,
                           home.appendingPathComponent("Library/pnpm").path,
                           home.appendingPathComponent(".local/bin").path]
        return directories.flatMap { directory in
            names.map { URL(fileURLWithPath: directory).appendingPathComponent($0) }
        }
    }

    /// The tool's own uninstall command. Removing a package's files by hand
    /// would leave the manager's own bookkeeping inconsistent, so this is the
    /// one place the app runs an external program.
    public func uninstallArguments(for package: String) -> [String] {
        switch self {
        case .homebrew: ["uninstall", "--formula", package]
        case .homebrewCask: ["uninstall", "--cask", package]
        case .npm: ["uninstall", "--global", package]
        case .pnpm: ["remove", "--global", package]
        case .yarn: ["global", "remove", package]
        case .bun: ["remove", "--global", package]
        case .python: ["uninstall", "--yes", package]
        }
    }
}
