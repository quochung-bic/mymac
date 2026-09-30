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
    /// The Homebrew cask behind this row: on an application, the cask that put
    /// the bundle there; on a Caskroom row, the cask itself.
    public let cask: Cask?
    /// `nil` until measured — sizes are computed after the list appears, so a
    /// folder like /Applications does not have to be walked before anything can
    /// be shown.
    public var size: Int64?

    public init(id: String, name: String, version: String?, source: InstalledSource,
                location: URL, bundleIdentifier: String? = nil, size: Int64? = nil,
                cask: Cask? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.source = source
        self.location = location
        self.bundleIdentifier = bundleIdentifier
        self.size = size
        self.cask = cask
    }

    /// A bundle Homebrew put in place. Trashing it by hand leaves brew sure it
    /// is still installed, so removal goes through `brew uninstall --cask`.
    public struct Cask: Sendable, Hashable {
        public let token: String
        /// `Caskroom/<token>`: where brew keeps its record, and what picks the
        /// right `brew` when an arm64 and an x86_64 Homebrew both exist.
        public let record: URL

        public init(token: String, record: URL) {
            self.token = token
            self.record = record
        }
    }

    /// What the second column shows: where an application lives, or which
    /// manager installed a package. Held here so the column can be sorted by
    /// the very string it displays.
    public var origin: String {
        source == .application ? location.deletingLastPathComponent().path : source.title
    }

    /// Stands in for `size` where a column needs a non-optional key path. The
    /// list does not sort on this value — an unmeasured item belongs at the
    /// bottom whichever way the column points, and no number expresses that.
    public var sizeSortValue: Int64 { size ?? -1 }
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
    ///
    /// - Parameter near: where the package being removed actually lives. A tool
    ///   has to come from the same prefix as the package it manages: an Intel
    ///   Homebrew in `/usr/local` cannot uninstall an Apple Silicon formula in
    ///   `/opt/homebrew`, and plenty of Macs have both installed side by side.
    ///   Candidates under the package's own prefix are therefore tried first.
    public func executables(home: URL, near location: URL? = nil) -> [URL] {
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

        // A stable partition rather than a sort: `sorted(by:)` is not
        // guaranteed stable, and the existing order is the likelihood order.
        let ordered: [String]
        if let path = location?.standardizedFileURL.path {
            let sharesPrefix = { (directory: String) in
                path.hasPrefix(URL(fileURLWithPath: directory).deletingLastPathComponent().path + "/")
            }
            ordered = directories.filter(sharesPrefix) + directories.filter { !sharesPrefix($0) }
        } else {
            ordered = directories
        }

        return ordered.flatMap { directory in
            names.map { URL(fileURLWithPath: directory).appendingPathComponent($0) }
        }
    }

    /// The command that will actually run on this machine, executable resolved.
    ///
    /// The confirmation sheet shows this verbatim, so it has to be the real
    /// thing: `brew`, not the name of the enum case, and the full path so an
    /// Apple Silicon Homebrew can be told apart from an Intel one. `nil` when
    /// the tool is not installed where this app looks for it — the interface
    /// says so rather than displaying a command that cannot run.
    public func resolvedUninstallCommand(for package: String, home: URL,
                                         near location: URL? = nil) -> String? {
        guard let executable = CommandRunner.firstExecutable(
            among: executables(home: home, near: location)
        ) else { return nil }
        return ([executable.path] + uninstallArguments(for: package)).joined(separator: " ")
    }

    /// Why this manager's tool will certainly refuse, found without running
    /// it. `nil` when there is no such reason and the tool should be asked.
    ///
    /// Only an externally managed Python qualifies today: its pip refuses every
    /// uninstall, and what it prints is advice about installing into a virtual
    /// environment — nothing that helps someone trying to remove a package.
    public func refusal(home: URL, near location: URL? = nil) -> String? {
        guard self == .python,
              let pip = CommandRunner.firstExecutable(among: executables(home: home, near: location))
        else { return nil }

        // A pip for another Python cannot see this package at all, whatever
        // that other Python allows — so the mismatch is the reason to give.
        if let theirs = PythonEnvironment.version(ofPip: pip),
           let ours = location.flatMap(PythonEnvironment.version(ofSitePackagesAt:)),
           theirs != ours {
            return "The only pip this app found runs Python \(theirs), and this package belongs to Python \(ours), so it cannot remove it."
        }

        guard PythonEnvironment.isExternallyManaged(pip: pip) else { return nil }
        return "This Python is marked as externally managed (PEP 668), so pip refuses to remove anything from it. Packages here were installed by Homebrew or with --break-system-packages, and have to be removed the same way."
    }

    /// The tool's own uninstall command. Removing a package's files by hand
    /// would leave the manager's own bookkeeping inconsistent, so this is the
    /// one place the app runs an external program.
    public func uninstallArguments(for package: String) -> [String] {
        switch self {
        // `--force` is brew's spelling of "every installed version". Without
        // it only the linked keg goes, brew exits 0 with "… is still
        // installed", and the row the user removed is still there.
        case .homebrew: ["uninstall", "--formula", "--force", package]
        case .homebrewCask: ["uninstall", "--cask", package]
        case .npm: ["uninstall", "--global", package]
        case .pnpm: ["remove", "--global", package]
        case .yarn: ["global", "remove", package]
        case .bun: ["remove", "--global", package]
        case .python: ["uninstall", "--yes", package]
        }
    }
}
