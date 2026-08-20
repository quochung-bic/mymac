import Foundation
import Testing
@testable import MyMacCore

@Suite("Command safety")
struct CommandSafetyTests {
    @Test func acceptsRealPackageNames() throws {
        for name in ["typescript", "@angular/cli", "eslint-plugin-import", "ruff", "node@20", "pillow"] {
            try CommandRunner.validate(name)
        }
    }

    @Test func refusesAnythingThatCouldBeMistakenForSyntax() {
        for name in ["", "-rf", "--force", "a;rm -rf /", "a b", "a$(whoami)", "a`id`", "a&b", "a|b",
                     "a\nb", "a'b", "a\"b", "../etc", "a>b"] {
            #expect(throws: CommandRunner.Failure.self) { try CommandRunner.validate(name) }
        }
    }

    @Test func refusesOverlongNames() {
        #expect(throws: CommandRunner.Failure.self) {
            try CommandRunner.validate(String(repeating: "a", count: 300))
        }
    }

    @Test func reportsMissingExecutables() {
        #expect(CommandRunner.firstExecutable(among: [URL(fileURLWithPath: "/nowhere/nothing")]) == nil)
    }
}

@Suite("Application catalog")
struct ApplicationCatalogTests {
    @Test func readsNameVersionAndIdentifierFromABundle() throws {
        let temp = try TemporaryDirectory()
        let app = try temp.makeDirectory("Applications/Example.app/Contents")
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.app",
            "CFBundleName": "Example",
            "CFBundleShortVersionString": "2.1",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Info.plist"))

        let item = try #require(ApplicationCatalog.application(at: app.deletingLastPathComponent()))
        #expect(item.name == "Example")
        #expect(item.version == "2.1")
        #expect(item.bundleIdentifier == "com.example.app")
    }

    @Test func skipsApplesOwnApplications() {
        #expect(ApplicationCatalog.isSystemApplication(bundleIdentifier: "com.apple.Safari"))
        #expect(!ApplicationCatalog.isSystemApplication(bundleIdentifier: "com.example.app"))
        #expect(!ApplicationCatalog.isSystemApplication(bundleIdentifier: nil))
    }

    @Test func findsRealApplicationsOnThisMac() {
        let items = ApplicationCatalog.scan()
        print("APPS \(items.count): \(items.prefix(5).map { "\($0.name) \($0.version ?? "?")" })")
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.bundleIdentifier?.hasPrefix("com.apple.") != true })
    }
}

@Suite("Leftover scanner")
struct LeftoverScannerTests {
    @Test func findsSupportFilesKeyedOnTheBundleIdentifier() throws {
        let temp = try TemporaryDirectory()
        try temp.makeFile("Library/Application Support/com.example.app/state.db", bytes: 4096)
        try temp.makeFile("Library/Preferences/com.example.app.plist", bytes: 2048)
        try temp.makeFile("Library/Containers/com.example.app/Data/x.bin", bytes: 8192)
        try temp.makeFile("Library/Group Containers/ABCDE.com.example.app/shared.db", bytes: 4096)
        // Belongs to a different app and must not be picked up.
        try temp.makeFile("Library/Application Support/com.other.app/state.db", bytes: 4096)

        let item = InstalledItem(id: "x", name: "Example", version: nil, source: .application,
                                 location: temp.url.appendingPathComponent("Applications/Example.app"),
                                 bundleIdentifier: "com.example.app")
        let leftovers = try LeftoverScanner.scan(for: item, home: temp.url)
        let names = leftovers.map(\.url.lastPathComponent).sorted()

        #expect(names.contains("com.example.app"))
        #expect(names.contains("com.example.app.plist"))
        #expect(names.contains("ABCDE.com.example.app"))
        #expect(!leftovers.contains { $0.url.path.contains("com.other.app") })
    }

    @Test func reportsNothingForAnAppThatLeftNothing() throws {
        let temp = try TemporaryDirectory()
        try temp.makeDirectory("Library/Application Support")
        let item = InstalledItem(id: "x", name: "Ghost", version: nil, source: .application,
                                 location: temp.url.appendingPathComponent("Applications/Ghost.app"),
                                 bundleIdentifier: "com.example.ghost")
        #expect(try LeftoverScanner.scan(for: item, home: temp.url).isEmpty)
    }

    @Test func everySearchRootIsInsideTheUsersLibrary() {
        let home = URL(fileURLWithPath: "/Users/example")
        for root in LeftoverScanner.searchRoots(home: home) {
            #expect(root.path.hasPrefix("/Users/example/Library/"))
        }
    }
}

@Suite("Package catalog")
struct PackageCatalogTests {
    @Test func readsNodeModulesIncludingScopedPackages() throws {
        let temp = try TemporaryDirectory()
        let root = try temp.makeDirectory("lib/node_modules")
        try temp.makeDirectory("lib/node_modules/typescript")
        try Data(#"{"version":"5.4.2"}"#.utf8)
            .write(to: root.appendingPathComponent("typescript/package.json"))
        try temp.makeDirectory("lib/node_modules/@angular/cli")
        try Data(#"{"version":"17.0.0"}"#.utf8)
            .write(to: root.appendingPathComponent("@angular/cli/package.json"))

        let items = PackageCatalog.scanNodeModulesForTesting(root: root, ecosystem: .npm)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.version) })

        #expect(byName["typescript"] == "5.4.2")
        #expect(byName["@angular/cli"] == "17.0.0")
        #expect(items.count == 2, "the @angular scope directory is not a package")
    }

    /// Only the first existing root used to be read. On an Apple Silicon Mac
    /// running both an arm64 Homebrew in /opt/homebrew and an x86_64 one under
    /// Rosetta in /usr/local, that silently halved the list — with nothing
    /// saying it was partial, so a package that was never removed looked gone.
    ///
    /// pnpm is the ecosystem whose two candidate roots are both under the home
    /// folder, so the case can be built without touching the real machine.
    @Test func readsEveryInstallRootNotJustTheFirst() throws {
        let temp = try TemporaryDirectory()
        let first = try temp.makeDirectory("Library/pnpm/global/5/node_modules/alpha")
        try Data(#"{"version":"1.0.0"}"#.utf8).write(to: first.appendingPathComponent("package.json"))
        let second = try temp.makeDirectory(".local/share/pnpm/global/5/node_modules/beta")
        try Data(#"{"version":"2.0.0"}"#.utf8).write(to: second.appendingPathComponent("package.json"))

        let items = PackageCatalog.scan(.pnpm, home: temp.url)
        let names = Set(items.map(\.name))

        #expect(names == ["alpha", "beta"], "both roots must be read, got \(names)")
    }

    /// The same package can legitimately exist under two prefixes, so a row's
    /// identity has to be its location — two rows sharing an id collide in the
    /// table and one of them disappears.
    @Test func packagesInDifferentRootsKeepDistinctIdentities() throws {
        let temp = try TemporaryDirectory()
        for root in ["Library/pnpm/global/5/node_modules", ".local/share/pnpm/global/5/node_modules"] {
            let directory = try temp.makeDirectory("\(root)/shared")
            try Data(#"{"version":"1.0.0"}"#.utf8).write(to: directory.appendingPathComponent("package.json"))
        }

        let items = PackageCatalog.scan(.pnpm, home: temp.url)

        #expect(items.count == 2)
        #expect(Set(items.map(\.id)).count == 2, "two installs of one package need two identities")
    }

    @Test func findsRealPackagesOnThisMac() {
        let items = PackageCatalog.scan()
        let grouped = Dictionary(grouping: items, by: \.source.title).mapValues(\.count)
        print("PACKAGES \(grouped)")
        for item in items.prefix(4) { print("  \(item.source.title): \(item.name) \(item.version ?? "?")") }
        #expect(items.allSatisfy { !$0.name.isEmpty })
    }
}

@Suite("Uninstall safety")
struct UninstallSafetyTests {
    /// Populates a fake home with an app bundle and one support folder.
    /// `TemporaryDirectory` is noncopyable, so it stays owned by the test.
    private func populate(_ temp: borrowing TemporaryDirectory) throws -> InstalledItem {
        let bundle = try temp.makeDirectory("Applications/Example.app")
        try temp.makeFile("Applications/Example.app/Contents/MacOS/Example", bytes: 4096)
        try temp.makeFile("Library/Application Support/com.example.app/state.db", bytes: 8192)
        return InstalledItem(id: "app", name: "Example", version: "1.0", source: .application,
                             location: bundle, bundleIdentifier: "com.example.app", size: 4096)
    }

    @Test func refusesAnApplicationOutsideTheApplicationsFolders() async throws {
        let temp = try TemporaryDirectory()
        let document = try temp.makeFile("Documents/thesis.pdf", bytes: 10_000)
        let item = InstalledItem(id: "x", name: "Not An App", version: nil, source: .application,
                                 location: document, bundleIdentifier: "com.example.fake", size: 10_000)

        let outcome = await UninstallService(home: temp.url).uninstall(item, leftovers: [])

        #expect(outcome.trashedCount == 0)
        #expect(!outcome.succeeded)
        #expect(FileManager.default.fileExists(atPath: document.path))
    }

    @Test func refusesALeftoverOutsideTheLibraryFoldersItSearches() async throws {
        let temp = try TemporaryDirectory()
        let item = try populate(temp)
        let photo = try temp.makeFile("Pictures/holiday.jpg", bytes: 5_000)
        let forged = CleanupItem(url: photo, name: "holiday.jpg", size: 5_000, modified: nil)

        let outcome = await UninstallService(home: temp.url).uninstall(item, leftovers: [forged])

        #expect(outcome.failures.contains { $0.path == photo.path })
        #expect(FileManager.default.fileExists(atPath: photo.path),
                "a path the leftover scanner could never have produced is refused")
    }

    @Test func refusesAPackageNameThatIsNotAPackageName() async throws {
        let temp = try TemporaryDirectory()
        let item = InstalledItem(id: "p", name: "--force", version: nil,
                                 source: .package(.npm), location: temp.url, size: 0)

        let outcome = await UninstallService(home: temp.url).uninstall(item, leftovers: [])

        #expect(!outcome.succeeded)
        #expect(outcome.trashedCount == 0)
    }

    @Test func everyEcosystemBuildsAnUninstallCommandThatEndsInThePackageName() throws {
        for ecosystem in PackageEcosystem.allCases {
            let arguments = ecosystem.uninstallArguments(for: "example-package")
            #expect(arguments.last == "example-package")
            #expect(arguments.allSatisfy { !$0.contains(" ") }, "\(ecosystem) built a joined argument")
        }
    }
}

/// Regression cover for the confirmation-sheet fault found in the 2026-08-20
/// audit: the sheet showed `ecosystem.rawValue` — the name of the enum case —
/// where the README promises "the exact command … before it runs".
@Suite("Resolved uninstall command")
struct ResolvedUninstallCommandTests {
    private var emptyHome: URL {
        URL(fileURLWithPath: "/nonexistent-home-\(UUID().uuidString)")
    }

    @Test func reportsNilWhenTheToolIsNotInstalled() {
        // No executable can resolve under a home that does not exist, and the
        // shared /usr/bin candidates hold none of these tools.
        for ecosystem in [PackageEcosystem.pnpm, .bun, .yarn] {
            #expect(ecosystem.resolvedUninstallCommand(for: "example", home: emptyHome) == nil,
                    "\(ecosystem.rawValue) is not installed in /usr/bin")
        }
    }

    @Test func namesTheRealProgramRatherThanTheEnumCase() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var checked = 0

        for ecosystem in PackageEcosystem.allCases {
            guard let command = ecosystem.resolvedUninstallCommand(for: "example-package", home: home) else {
                continue
            }
            checked += 1

            let program = try #require(command.split(separator: " ").first.map(String.init))
            #expect(program.hasPrefix("/"), "must be an absolute path, got \(program)")
            #expect(FileManager.default.isExecutableFile(atPath: program),
                    "\(program) must actually be executable")
            #expect(program != ecosystem.rawValue,
                    "the enum case name is not a program")
            #expect(command.hasSuffix(" example-package"),
                    "the package name must survive intact: \(command)")
        }

        #expect(checked > 0, "no package manager found on this machine to check against")
    }

    /// `python` was the clearest symptom: the sheet said `python uninstall …`
    /// while `pip3` is what runs.
    @Test func pythonResolvesToPipNotPython() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let command = PackageEcosystem.python.resolvedUninstallCommand(for: "requests", home: home) else {
            return  // pip is not installed here; nothing to assert.
        }
        let program = try #require(command.split(separator: " ").first.map(String.init))
        #expect(URL(fileURLWithPath: program).lastPathComponent.hasPrefix("pip"),
                "expected pip, got \(program)")
    }

    /// An Intel Homebrew in /usr/local cannot uninstall an Apple Silicon
    /// formula in /opt/homebrew. The tool has to come from the same prefix as
    /// the package, so candidates under that prefix are tried first.
    @Test func theToolIsChosenFromThePackagesOwnPrefix() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let intel = URL(fileURLWithPath: "/usr/local/Cellar/wget/1.25.0")
        let appleSilicon = URL(fileURLWithPath: "/opt/homebrew/Cellar/wget/1.25.0")

        let forIntel = PackageEcosystem.homebrew.executables(home: home, near: intel)
        #expect(forIntel.first?.path == "/usr/local/bin/brew")

        let forAppleSilicon = PackageEcosystem.homebrew.executables(home: home, near: appleSilicon)
        #expect(forAppleSilicon.first?.path == "/opt/homebrew/bin/brew")
    }

    @Test func withoutALocationTheLikelihoodOrderIsKept() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = PackageEcosystem.homebrew.executables(home: home)
        #expect(candidates.first?.path == "/opt/homebrew/bin/brew")
        #expect(candidates.map(\.path) == PackageEcosystem.homebrew
            .executables(home: home, near: nil).map(\.path))
    }

    @Test func everyCandidateStaysInTheListWhenOneIsPromoted() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plain = PackageEcosystem.homebrew.executables(home: home)
        let promoted = PackageEcosystem.homebrew.executables(
            home: home, near: URL(fileURLWithPath: "/usr/local/Cellar/wget/1.25.0"))
        #expect(Set(plain.map(\.path)) == Set(promoted.map(\.path)),
                "promoting a prefix must reorder the candidates, never drop any")
    }

    @Test func homebrewResolvesToBrew() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let command = PackageEcosystem.homebrewCask.resolvedUninstallCommand(for: "example", home: home) else {
            return  // Homebrew is not installed here.
        }
        #expect(command.contains("/brew "), "expected the brew executable, got \(command)")
        #expect(command.contains("--cask"))
    }
}
