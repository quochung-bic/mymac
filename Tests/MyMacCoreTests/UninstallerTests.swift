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

    /// Python.org, Adobe and a few others install into a product folder rather
    /// than straight into /Applications, and those apps were simply absent.
    @Test func findsAnApplicationInsideAProductFolder() throws {
        let temp = try TemporaryDirectory()
        try temp.makeDirectory("Applications/Python 3.11/IDLE.app/Contents")

        let items = ApplicationCatalog.scan(home: temp.url)

        #expect(items.contains { $0.location.path.hasSuffix("Applications/Python 3.11/IDLE.app") })
    }

    /// Removing a helper bundle guts the application that ships it, so the
    /// extra level stops at any directory that is itself an application.
    @Test func neverListsAHelperInsideAnotherApplication() throws {
        let temp = try TemporaryDirectory()
        try temp.makeDirectory("Applications/Host.app/Contents/Helper.app/Contents")
        try temp.makeDirectory("Applications/Host.app/Helper.app")

        let items = ApplicationCatalog.scan(home: temp.url)

        #expect(items.contains { $0.location.path.hasSuffix("Applications/Host.app") })
        #expect(!items.contains { $0.location.path.contains("Host.app/") })
    }

    /// A cask puts its bundle in /Applications and keeps a symlink back to it
    /// in its Caskroom record, so the bundle can be tied to its cask exactly —
    /// no matching on names.
    @Test func recognisesABundleThatAHomebrewCaskInstalled() throws {
        // The scan reads the real /Applications as well, so these names must
        // not collide with anything actually installed.
        let temp = try TemporaryDirectory()
        let bundle = try temp.makeDirectory("Applications/MyMac Probe Studio.app")
        try temp.makeDirectory("Applications/MyMac Probe Unrelated.app")
        let record = try temp.makeDirectory("Caskroom/mymac-probe-studio")
        try temp.makeSymlink("Caskroom/mymac-probe-studio/2026.1/MyMac Probe Studio.app", to: bundle)

        let items = ApplicationCatalog.scan(home: temp.url,
                                            caskrooms: [temp.url.appendingPathComponent("Caskroom")])

        let studio = try #require(items.first { $0.location.lastPathComponent == "MyMac Probe Studio.app" })
        #expect(studio.cask?.token == "mymac-probe-studio")
        #expect(studio.cask?.record.standardizedFileURL == record.standardizedFileURL)
        let unrelated = try #require(items.first { $0.location.lastPathComponent == "MyMac Probe Unrelated.app" })
        #expect(unrelated.cask == nil)
    }

    @Test func findsRealApplicationsOnThisMac() {
        let items = ApplicationCatalog.scan()
        print("APPS \(items.count): \(items.prefix(5).map { "\($0.name) \($0.version ?? "?")" })")
        print("CASK APPS: \(items.compactMap { item in item.cask.map { "\(item.name) ← \($0.token)" } })")
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

    /// The Cellar holds every dependency Homebrew ever pulled in: 84 formulae
    /// on the machine this was written on, 65 of them needed by something else,
    /// so uninstalling most rows could only end in "required by …". Each keg's
    /// receipt says whether it was asked for and what it needs, so the list is
    /// narrowed from disk without running `brew`.
    @Test func listsOnlyFormulaeAskedForThatNothingElseNeeds() throws {
        let temp = try TemporaryDirectory()
        let cellar = try temp.makeDirectory("Cellar")
        try receipt(in: temp, "node", "22.0", onRequest: true, needs: ["brotli", "homebrew/core/icu4c"])
        try receipt(in: temp, "brotli", "1.2", onRequest: false)
        try receipt(in: temp, "icu4c", "76", onRequest: true)
        // A third-party tap: `brew leaves` leaves these out, but nothing needs
        // it and it uninstalls cleanly, so it belongs in the list.
        try receipt(in: temp, "k9s", "0.50", onRequest: true)

        let items = PackageCatalog.scanVersionedForTesting(root: cellar, ecosystem: .homebrew)

        #expect(Set(items.map(\.name)) == ["node", "k9s"])
    }

    /// The newest keg speaks for the formula: an older one may have been
    /// pulled in as a dependency before the user asked for it by name. Newest
    /// is numeric — spelled out, "3.14.10" sorts before "3.14.7".
    @Test func judgesAFormulaByItsNewestInstalledVersion() throws {
        let temp = try TemporaryDirectory()
        let cellar = try temp.makeDirectory("Cellar")
        try receipt(in: temp, "python@3.14", "3.14.7", onRequest: false)
        try receipt(in: temp, "python@3.14", "3.14.10", onRequest: true)

        let items = PackageCatalog.scanVersionedForTesting(root: cellar, ecosystem: .homebrew)

        #expect(items.map(\.name) == ["python@3.14"])
        #expect(items.first?.version == "3.14.10")
    }

    /// Receipts that predate the `installed_on_request` key cannot say either
    /// way, so they are kept, as an unreadable one is.
    @Test func keepsAFormulaWhoseReceiptDoesNotSayWhyItWasInstalled() throws {
        let temp = try TemporaryDirectory()
        let cellar = try temp.makeDirectory("Cellar")
        let keg = try temp.makeDirectory("Cellar/vintage/1.0")
        try JSONSerialization.data(withJSONObject: ["runtime_dependencies": [] as [Any]])
            .write(to: keg.appendingPathComponent("INSTALL_RECEIPT.json"))

        let items = PackageCatalog.scanVersionedForTesting(root: cellar, ecosystem: .homebrew)

        #expect(items.map(\.name) == ["vintage"])
    }

    /// Hiding what cannot be judged would make an installed formula look gone.
    @Test func keepsAFormulaWhoseReceiptCannotBeRead() throws {
        let temp = try TemporaryDirectory()
        let cellar = try temp.makeDirectory("Cellar")
        try temp.makeDirectory("Cellar/mystery/1.0")

        let items = PackageCatalog.scanVersionedForTesting(root: cellar, ecosystem: .homebrew)

        #expect(items.map(\.name) == ["mystery"])
    }

    @Test func listsEveryCaskRegardlessOfFormulaReceipts() throws {
        let temp = try TemporaryDirectory()
        let caskroom = try temp.makeDirectory("Caskroom")
        try temp.makeDirectory("Caskroom/libreoffice/26.8.0")

        let items = PackageCatalog.scanVersionedForTesting(root: caskroom, ecosystem: .homebrewCask)

        #expect(items.map(\.name) == ["libreoffice"])
        #expect(items.first?.cask?.token == "libreoffice",
                "a cask row names its cask the way an application row does")
    }

    private func receipt(in temp: borrowing TemporaryDirectory, _ name: String, _ version: String,
                         onRequest: Bool, needs: [String] = []) throws {
        let keg = try temp.makeDirectory("Cellar/\(name)/\(version)")
        let json: [String: Any] = [
            "installed_on_request": onRequest,
            "runtime_dependencies": needs.map { ["full_name": $0] },
        ]
        try JSONSerialization.data(withJSONObject: json)
            .write(to: keg.appendingPathComponent("INSTALL_RECEIPT.json"))
    }

    @Test func findsRealPackagesOnThisMac() {
        let items = PackageCatalog.scan()
        let grouped = Dictionary(grouping: items, by: \.source.title).mapValues(\.count)
        print("PACKAGES \(grouped)")
        let home = FileManager.default.homeDirectoryForCurrentUser
        print("PYTHON REFUSED: \(PackageEcosystem.python.refusal(home: home, near: URL(fileURLWithPath: "/opt/homebrew/lib/python3.14/site-packages/numpy")) != nil)")
        for item in items.prefix(4) { print("  \(item.source.title): \(item.name) \(item.version ?? "?")") }
        #expect(items.allSatisfy { !$0.name.isEmpty })
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var paths: [String] { lock.withLock { stored } }
    func add(_ path: String) { lock.withLock { stored.append(path) } }
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

    @Test func flagsABundleOnlyAnAdministratorCanTrash() async throws {
        let temp = try TemporaryDirectory()
        let item = try populate(temp)
        let service = UninstallService(home: temp.url,
                                       trasher: { _ in throw CocoaError(.fileWriteNoPermission) })

        let outcome = await service.uninstall(item, leftovers: [])

        #expect(outcome.needsAdministrator)
        #expect(!outcome.removedTheItemItself)
        #expect(outcome.failures.first?.reason.contains("administrator password") == true)
    }

    @Test func doesNotAskForAdministratorOverAnotherKindOfFailure() async throws {
        let temp = try TemporaryDirectory()
        let item = try populate(temp)
        let service = UninstallService(home: temp.url,
                                       trasher: { _ in throw CocoaError(.fileWriteVolumeReadOnly) })

        let outcome = await service.uninstall(item, leftovers: [])

        #expect(!outcome.needsAdministrator)
    }

    @Test func handsTheValidatedBundlePathToTheAdministratorTrasher() async throws {
        let temp = try TemporaryDirectory()
        let item = try populate(temp)
        let received = Received()
        let service = UninstallService(home: temp.url,
                                       trasher: { _ in throw CocoaError(.fileWriteNoPermission) },
                                       administratorTrasher: { received.add($0) })

        let outcome = await service.uninstall(item, leftovers: [], asAdministrator: true)

        #expect(received.paths.count == 1)
        #expect(received.paths.first.map { PathSafety.canonicalPath($0) } == PathSafety.canonicalPath(item.location.path))
        #expect(outcome.removedTheItemItself)
        #expect(outcome.succeeded)
    }

    @Test func neverHandsAPathOutsideTheApplicationsFoldersToTheAdministratorTrasher() async throws {
        let temp = try TemporaryDirectory()
        let document = try temp.makeFile("Documents/thesis.pdf", bytes: 10_000)
        let item = InstalledItem(id: "x", name: "Not An App", version: nil, source: .application,
                                 location: document, bundleIdentifier: "com.example.fake", size: 10_000)
        let received = Received()
        let service = UninstallService(home: temp.url, administratorTrasher: { received.add($0) })

        let outcome = await service.uninstall(item, leftovers: [], asAdministrator: true)

        #expect(received.paths.isEmpty)
        #expect(!outcome.succeeded)
    }

    @Test func reportsAMissingAdministratorTrasherInsteadOfPretendingToRemove() async throws {
        let temp = try TemporaryDirectory()
        let item = try populate(temp)

        let outcome = await UninstallService(home: temp.url)
            .uninstall(item, leftovers: [], asAdministrator: true)

        #expect(!outcome.removedTheItemItself)
        #expect(!outcome.succeeded)
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
        #expect(outcome.removedTheItemItself,
                "the bundle went to the Trash; a refused leftover does not undo that")
    }

    /// Two folders are matched on the app's display name, which comes from the
    /// bundle's own Info.plist. A name carrying a path separator expands into a
    /// nested folder that is still inside an allowed root, so nothing further
    /// down would refuse it.
    @Test func refusesADisplayNameThatReachesIntoAnotherFolder() throws {
        let temp = try TemporaryDirectory()
        try temp.makeFile("Library/Application Support/Google/Chrome/History", bytes: 2048)
        let item = InstalledItem(id: "app", name: "Google/Chrome", version: nil,
                                 source: .application,
                                 location: temp.url.appendingPathComponent("Applications/Odd.app"),
                                 bundleIdentifier: "com.example.odd")

        let found = try LeftoverScanner.scan(for: item, home: temp.url)

        #expect(!found.contains { $0.url.path.hasSuffix("Google/Chrome") },
                "found: \(found.map(\.url.path))")
    }

    /// The bundle identifier is read from the same Info.plist and pasted into
    /// the same kind of path, so it needs the same guard.
    @Test func refusesABundleIdentifierThatReachesIntoAnotherFolder() throws {
        let temp = try TemporaryDirectory()
        try temp.makeFile("Library/Application Support/Google/Chrome/History", bytes: 2048)
        let item = InstalledItem(id: "app", name: "Odd", version: nil, source: .application,
                                 location: temp.url.appendingPathComponent("Applications/Odd.app"),
                                 bundleIdentifier: "Google/Chrome")

        let found = try LeftoverScanner.scan(for: item, home: temp.url)

        #expect(!found.contains { $0.url.path.hasSuffix("Google/Chrome") },
                "found: \(found.map(\.url.path))")
    }

    @Test func refusesAPackageNameThatIsNotAPackageName() async throws {
        let temp = try TemporaryDirectory()
        let item = InstalledItem(id: "p", name: "--force", version: nil,
                                 source: .package(.npm), location: temp.url, size: 0)

        let outcome = await UninstallService(home: temp.url).uninstall(item, leftovers: [])

        #expect(!outcome.succeeded)
        #expect(outcome.trashedCount == 0)
    }

    /// `/Applications/Foo.app` is two components below the volume root, and
    /// the shared depth floor demanded three — so every application in
    /// /Applications failed with "path is too close to the volume root".
    /// The bundle here does not exist, which must be the only complaint.
    @Test func doesNotRefuseAnApplicationForSittingDirectlyInApplications() async {
        let ghost = URL(fileURLWithPath: "/Applications/MyMac Uninstall Probe.app")
        let item = InstalledItem(id: "app", name: "Probe", version: nil, source: .application,
                                 location: ghost, bundleIdentifier: "com.example.probe", size: 0)

        let outcome = await UninstallService().uninstall(item, leftovers: [])

        #expect(outcome.failures.isEmpty,
                "refused a bundle for its depth: \(outcome.failures.map(\.reason))")
    }

    /// A package manager that exits 0 has not necessarily removed anything.
    /// `npm uninstall --global` answers "up to date" and `pip uninstall`
    /// answers "Skipping … as it is not installed" — both with status 0 — when
    /// the tool resolved is not the one that owns the prefix the row came from.
    @Test func reportsAFailureWhenTheToolExitsZeroWithoutRemovingThePackage() async throws {
        let temp = try TemporaryDirectory()
        let location = try temp.makeDirectory(".bun/install/global/node_modules/left-pad")
        try temp.makeExecutable(".bun/bin/bun", script: "echo 'up to date'; exit 0")
        let item = InstalledItem(id: "bun:\(location.path)", name: "left-pad", version: nil,
                                 source: .package(.bun), location: location)

        let outcome = await UninstallService(home: temp.url).uninstall(item, leftovers: [])

        #expect(!outcome.succeeded, "the package is still on disk; status 0 is not proof")
        #expect(outcome.trashedCount == 0)
        #expect(FileManager.default.fileExists(atPath: location.path))
    }

    @Test func reportsSuccessWhenTheToolActuallyRemovesThePackage() async throws {
        let temp = try TemporaryDirectory()
        let location = try temp.makeDirectory(".bun/install/global/node_modules/left-pad")
        try temp.makeExecutable(".bun/bin/bun", script: "rm -rf '\(location.path)'")
        let item = InstalledItem(id: "bun:\(location.path)", name: "left-pad", version: nil,
                                 source: .package(.bun), location: location)

        let outcome = await UninstallService(home: temp.url).uninstall(item, leftovers: [])

        #expect(outcome.succeeded, "failures: \(outcome.failures.map(\.reason))")
        #expect(outcome.trashedCount == 1)
    }

    /// Without `--force`, `brew uninstall` removes only the linked keg and exits
    /// 0 with "foo 1.0 is still installed" — ten formulae on the machine this
    /// was written on held more than one keg. The row stands for the formula,
    /// so every version goes. The stand-in behaves as brew does.
    @Test func removesEveryInstalledVersionOfAFormula() async throws {
        let temp = try TemporaryDirectory()
        let formula = try temp.makeDirectory(".local/Cellar/mymac-test-formula")
        try temp.makeDirectory(".local/Cellar/mymac-test-formula/1.0")
        try temp.makeDirectory(".local/Cellar/mymac-test-formula/1.1")
        try temp.makeExecutable(".local/bin/brew", script: """
            case " $* " in
              *" --force "*) rm -rf '\(formula.path)' ;;
              *) rm -rf '\(formula.path)/1.1'; echo 'mymac-test-formula 1.0 is still installed' ;;
            esac
            """)
        let item = InstalledItem(id: "homebrew:\(formula.path)", name: "mymac-test-formula",
                                 version: "1.1", source: .package(.homebrew), location: formula)

        let outcome = await UninstallService(home: temp.url).uninstall(item, leftovers: [])

        #expect(outcome.succeeded, "failures: \(outcome.failures.map(\.reason))")
        #expect(!FileManager.default.fileExists(atPath: formula.path))
    }

    /// A package whose location was never there cannot be checked either way,
    /// and inventing a failure for it would refuse a removal that worked.
    @Test func doesNotInventAFailureForAPackageThatWasNeverOnDisk() async throws {
        let temp = try TemporaryDirectory()
        try temp.makeExecutable(".bun/bin/bun", script: "exit 0")
        let ghost = temp.url.appendingPathComponent(".bun/install/global/node_modules/pillow")
        let item = InstalledItem(id: "bun:\(ghost.path)", name: "pillow", version: nil,
                                 source: .package(.bun), location: ghost)

        let outcome = await UninstallService(home: temp.url).uninstall(item, leftovers: [])

        #expect(outcome.succeeded, "failures: \(outcome.failures.map(\.reason))")
    }

    /// Trashing a cask's bundle leaves Homebrew convinced it is still
    /// installed. The bundle goes through `brew uninstall --cask`; the support
    /// files brew does not touch still go to the Trash.
    ///
    /// The Caskroom record sits under `.local` so the stand-in `brew` in
    /// `.local/bin` is the one resolved, and the token names no real cask in
    /// case a real brew were ever picked up instead.
    @Test func handsACaskBundleToHomebrewAndTrashesItsSupportFiles() async throws {
        let temp = try TemporaryDirectory()
        let bundle = try temp.makeDirectory("Applications/Example.app/Contents")
            .deletingLastPathComponent()
        let support = try temp.makeDirectory("Library/Application Support/com.example.cask")
        let record = try temp.makeDirectory(".local/Caskroom/mymac-test-cask")
        let arguments = temp.url.appendingPathComponent("brew-arguments")
        try temp.makeExecutable(".local/bin/brew",
                                script: "echo \"$@\" > '\(arguments.path)'; rm -rf '\(bundle.path)'")
        let item = InstalledItem(id: "app", name: "Example", version: nil, source: .application,
                                 location: bundle, bundleIdentifier: "com.example.cask", size: 4096,
                                 cask: .init(token: "mymac-test-cask", record: record))
        let leftover = CleanupItem(url: support, name: support.lastPathComponent, size: 10, modified: nil)

        let outcome = await UninstallService(home: temp.url).uninstall(item, leftovers: [leftover])

        #expect(outcome.succeeded, "failures: \(outcome.failures.map(\.reason))")
        #expect(outcome.removedTheItemItself)
        let ran = try String(contentsOf: arguments, encoding: .utf8)
        #expect(ran.trimmingCharacters(in: .whitespacesAndNewlines) == "uninstall --cask mymac-test-cask")
        #expect(!FileManager.default.fileExists(atPath: support.path), "support files still go to the Trash")
    }

    /// An application that is still installed keeps its settings. Trashing
    /// them after the bundle refused to go leaves the app running on defaults.
    @Test func leavesSupportFilesAloneWhenTheApplicationCouldNotBeRemoved() async throws {
        let temp = try TemporaryDirectory()
        let bundle = try temp.makeDirectory("Applications/Example.app/Contents")
            .deletingLastPathComponent()
        let support = try temp.makeDirectory("Library/Application Support/com.example.cask")
        let record = try temp.makeDirectory(".local/Caskroom/mymac-test-cask")
        try temp.makeExecutable(".local/bin/brew", script: "echo 'Error: sudo: a password is required'; exit 1")
        let item = InstalledItem(id: "app", name: "Example", version: nil, source: .application,
                                 location: bundle, bundleIdentifier: "com.example.cask",
                                 cask: .init(token: "mymac-test-cask", record: record))
        let leftover = CleanupItem(url: support, name: support.lastPathComponent, size: 10, modified: nil)

        let outcome = await UninstallService(home: temp.url).uninstall(item, leftovers: [leftover])

        #expect(!outcome.removedTheItemItself)
        #expect(FileManager.default.fileExists(atPath: support.path))
        #expect(outcome.failures.contains { $0.reason.contains("left in place") },
                "the support files the user ticked must not vanish from the report: \(outcome.failures.map(\.reason))")
    }

    @Test func reportsACaskBundleThatHomebrewLeftBehind() async throws {
        let temp = try TemporaryDirectory()
        let bundle = try temp.makeDirectory("Applications/Example.app/Contents")
            .deletingLastPathComponent()
        let record = try temp.makeDirectory(".local/Caskroom/mymac-test-cask")
        try temp.makeExecutable(".local/bin/brew", script: "exit 0")
        let item = InstalledItem(id: "app", name: "Example", version: nil, source: .application,
                                 location: bundle, bundleIdentifier: "com.example.cask",
                                 cask: .init(token: "mymac-test-cask", record: record))

        let outcome = await UninstallService(home: temp.url).uninstall(item, leftovers: [])

        #expect(!outcome.succeeded)
        #expect(!outcome.removedTheItemItself)
        #expect(FileManager.default.fileExists(atPath: bundle.path))
    }

    /// The size column shows "…" for anything unmeasured. Turning a path that
    /// is not there into the number 0 puts a wrong figure in that column:
    /// `pillow`'s dist-info names no directory called `pillow`.
    @Test func measuringAPathThatIsNotThereReportsNothingRatherThanZero() throws {
        let temp = try TemporaryDirectory()
        let item = InstalledItem(id: "p", name: "pillow", version: nil, source: .package(.python),
                                 location: temp.url.appendingPathComponent("site-packages/pillow"))

        #expect(UninstallService.measure(item) == nil)
    }

    /// Homebrew's Python carries PEP 668's `EXTERNALLY-MANAGED` marker, and its
    /// pip then refuses every uninstall with a page of advice about virtual
    /// environments. Knowing that from disk means not running a command that
    /// can only fail.
    @Test func refusesToRunPipAgainstAnExternallyManagedPython() async throws {
        let temp = try TemporaryDirectory()
        // A link to a real shell, so the stand-in pip really runs if it is
        // invoked — an empty file would fail to start and hide the difference.
        let interpreter = try temp.makeSymlink("python/bin/python3.14", to: URL(fileURLWithPath: "/bin/sh"))
        try temp.makeFile("python/lib/python3.14/EXTERNALLY-MANAGED", bytes: 0)
        let ran = temp.url.appendingPathComponent("pip-ran")
        try temp.makeExecutable(".local/bin/pip3", script: "touch '\(ran.path)'",
                                interpreter: interpreter.path)
        let location = try temp.makeDirectory(".local/lib/python3.14/site-packages/numpy")
        let item = InstalledItem(id: "python:\(location.path)", name: "numpy", version: nil,
                                 source: .package(.python), location: location)

        let outcome = await UninstallService(home: temp.url).uninstall(item, leftovers: [])

        #expect(!outcome.succeeded)
        #expect(outcome.failures.first?.reason.contains("externally managed") == true,
                "reason: \(outcome.failures.map(\.reason))")
        #expect(!FileManager.default.fileExists(atPath: ran.path), "pip must not have been run")
    }

    /// The only pip found can belong to a different Python from the row's —
    /// the machine this was written on has rows in python3.12 and python3.13
    /// site-packages and only a 3.14 pip. That pip cannot remove them, and the
    /// reason is the mismatch, not how the package was installed.
    @Test func namesAPipForAnotherPythonAsTheReasonRatherThanPEP668() async throws {
        let temp = try TemporaryDirectory()
        let interpreter = try temp.makeSymlink("python/bin/python3.14", to: URL(fileURLWithPath: "/bin/sh"))
        try temp.makeFile("python/lib/python3.14/EXTERNALLY-MANAGED", bytes: 0)
        let ran = temp.url.appendingPathComponent("pip-ran")
        try temp.makeExecutable(".local/bin/pip3", script: "touch '\(ran.path)'",
                                interpreter: interpreter.path)
        let location = try temp.makeDirectory(".local/lib/python3.13/site-packages/numpy")
        let item = InstalledItem(id: "python:\(location.path)", name: "numpy", version: nil,
                                 source: .package(.python), location: location)

        let outcome = await UninstallService(home: temp.url).uninstall(item, leftovers: [])
        let reason = outcome.failures.first?.reason ?? ""

        #expect(reason.contains("3.14") && reason.contains("3.13"), "reason: \(reason)")
        #expect(!reason.contains("PEP 668"), "reason: \(reason)")
        #expect(!FileManager.default.fileExists(atPath: ran.path), "pip must not have been run")
    }

    @Test func runsPipAgainstAPythonThatIsNotExternallyManaged() throws {
        let temp = try TemporaryDirectory()
        let interpreter = try temp.makeSymlink("python/bin/python3.14", to: URL(fileURLWithPath: "/bin/sh"))
        try temp.makeDirectory("python/lib/python3.14")
        let pip = try temp.makeExecutable("bin/pip3", script: "", interpreter: interpreter.path)

        #expect(!PythonEnvironment.isExternallyManaged(pip: pip))
    }

    /// `#!/usr/bin/env python3` names no interpreter this can follow without
    /// searching a PATH, so the tool is run and allowed to answer for itself.
    @Test func doesNotGuessThroughAnEnvShebang() throws {
        let temp = try TemporaryDirectory()
        let pip = try temp.makeExecutable("bin/pip3", script: "", interpreter: "/usr/bin/env python3")

        #expect(!PythonEnvironment.isExternallyManaged(pip: pip))
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
