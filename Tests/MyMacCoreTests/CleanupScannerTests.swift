import Foundation
import Testing
@testable import MyMacCore

private struct FakeInventory: ApplicationInventory {
    let installed: Set<String>
    func isInstalled(bundleIdentifier: String) -> Bool { installed.contains(bundleIdentifier) }
}

@Suite("Cleanup scanner")
struct CleanupScannerTests {
    private func rule(_ id: String, home: URL) throws -> CleanupRule {
        try #require(CleanupCatalog.rules(home: home).first { $0.id == id })
    }

    private func scan(_ rules: [CleanupRule], home: URL,
                      inventory: any ApplicationInventory = ConservativeApplicationInventory()) async throws -> [CleanupGroup] {
        let scanner = CleanupScanner(home: home, inventory: inventory)
        return try await scanner.scan(rules: rules, progress: { _ in })
    }

    @Test func listsEachCacheFolderAsOneItem() async throws {
        let temp = try TemporaryDirectory()
        // Sizes differ by more than one allocation block: the scanner reports
        // allocated size, which is what is actually reclaimed.
        try temp.makeFile("Library/Caches/com.example.alpha/data.bin", bytes: 200_000)
        try temp.makeFile("Library/Caches/com.example.beta/data.bin", bytes: 4_000)
        try temp.makeFile("Library/Caches/CloudKit/state.db", bytes: 9_000)

        let groups = try await scan([rule("user.caches", home: temp.url)], home: temp.url)
        let group = try #require(groups.first)

        #expect(group.items.count == 2)
        #expect(group.items.map(\.name) == ["alpha", "beta"], "largest first, bundle IDs shortened")
        #expect(!group.items.contains { $0.url.lastPathComponent == "CloudKit" },
                "CloudKit holds sync state, not cache")
        #expect(group.totalSize > 0)
        #expect(group.tier == .safe)
        #expect(group.removal == .delete)
    }

    @Test func skipsSymlinksWhileScanning() async throws {
        let temp = try TemporaryDirectory()
        let documents = try temp.makeDirectory("Documents")
        try temp.makeFile("Documents/thesis.pdf", bytes: 50_000)
        try temp.makeSymlink("Library/Caches/com.example.sneaky", to: documents)
        try temp.makeFile("Library/Caches/com.example.real/data.bin", bytes: 2000)

        let groups = try await scan([rule("user.caches", home: temp.url)], home: temp.url)
        let group = try #require(groups.first)

        #expect(group.items.count == 1)
        #expect(group.items.first?.name == "real")
    }

    @Test func honoursTheMinimumAgeForLogs() async throws {
        let temp = try TemporaryDirectory()
        let old = Date().addingTimeInterval(-30 * 86_400)
        try temp.makeFile("Library/Logs/OldApp/session.log", bytes: 2000, modified: old)
        try FileManager.default.setAttributes(
            [.modificationDate: old],
            ofItemAtPath: temp.url.appendingPathComponent("Library/Logs/OldApp").path
        )
        try temp.makeFile("Library/Logs/LiveApp/session.log", bytes: 2000)

        let groups = try await scan([rule("user.logs", home: temp.url)], home: temp.url)
        let group = try #require(groups.first)

        #expect(group.items.count == 1)
        #expect(group.items.first?.name == "OldApp", "a log written today belongs to something still running")
    }

    @Test func findsLeftoversOnlyForUninstalledBundleIdentifiers() async throws {
        let temp = try TemporaryDirectory()
        try temp.makeFile("Library/Application Support/com.example.gone/db.sqlite", bytes: 2_000_000)
        try temp.makeFile("Library/Application Support/com.example.present/db.sqlite", bytes: 2_000_000)
        try temp.makeFile("Library/Application Support/Firefox/profile.db", bytes: 2_000_000)

        let groups = try await scan([rule("app.leftovers", home: temp.url)], home: temp.url,
                                    inventory: FakeInventory(installed: ["com.example.present"]))
        let group = try #require(groups.first)

        #expect(group.items.map(\.name) == ["com.example.gone"])
        #expect(group.tier == .review)
        #expect(group.removal == .trash, "leftovers go to the Trash, never straight out")
    }

    @Test func neverGuessesAtHumanNamedFolders() {
        #expect("com.example.app".looksLikeBundleIdentifier)
        #expect("com.example.app.helper".looksLikeBundleIdentifier)
        #expect(!"Firefox".looksLikeBundleIdentifier)
        #expect(!"Google Chrome".looksLikeBundleIdentifier)
        #expect(!"com.example".looksLikeBundleIdentifier)
        #expect(!".hidden.folder.thing".looksLikeBundleIdentifier)
    }

    @Test func reportsScanProgressMonotonically() async throws {
        let temp = try TemporaryDirectory()
        try temp.makeFile("Library/Caches/com.example.one/a.bin", bytes: 1000)
        let rules = try [rule("user.caches", home: temp.url), rule("user.trash", home: temp.url)]

        let recorder = ProgressRecorder()
        let scanner = CleanupScanner(home: temp.url)
        _ = try await scanner.scan(rules: rules, progress: { recorder.record($0.fraction) })

        #expect(recorder.values == recorder.values.sorted())
        #expect(recorder.values.last == 1.0)
    }

    @Test func stopsWhenTheTaskIsCancelled() async throws {
        let temp = try TemporaryDirectory()
        for index in 0..<50 {
            try temp.makeFile("Library/Caches/com.example.app\(index)/data.bin", bytes: 1000)
        }
        let rules = try [rule("user.caches", home: temp.url)]
        let home = temp.url

        let task = Task {
            let scanner = CleanupScanner(home: home)
            return try await scanner.scan(rules: rules, progress: { _ in })
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func toleratesRootsThatDoNotExist() async throws {
        let temp = try TemporaryDirectory()
        let groups = try await scan(CleanupCatalog.rules(home: temp.url).filter { !$0.isDeepScan },
                                    home: temp.url)

        #expect(groups.allSatisfy { $0.items.isEmpty })
        #expect(groups.allSatisfy { !$0.requiresFullDiskAccess },
                "a missing folder is not a permissions problem")
    }
}

@Suite("Duplicate detection")
struct DuplicateScannerTests {
    @Test func matchesOnContentNotOnName() throws {
        let temp = try TemporaryDirectory()
        let payload = Data(repeating: 0x7A, count: 12_000_000)
        let documents = try temp.makeDirectory("Documents")
        try payload.write(to: documents.appendingPathComponent("original.bin"))
        try payload.write(to: documents.appendingPathComponent("copy-with-other-name.bin"))
        // Same size, different bytes: must not be reported.
        var different = payload
        different[0] = 0x00
        try different.write(to: documents.appendingPathComponent("lookalike.bin"))

        let items = try DuplicateScanner.scan(roots: [documents], minimumSize: 10_000_000)

        #expect(items.count == 1, "one redundant copy, the original stays")
        #expect(items.first?.detail?.contains("Identical to") == true)
        #expect(items.first?.url.lastPathComponent != "lookalike.bin")
    }

    @Test func ignoresFilesBelowTheSizeThreshold() throws {
        let temp = try TemporaryDirectory()
        let documents = try temp.makeDirectory("Documents")
        let payload = Data(repeating: 0x01, count: 1000)
        try payload.write(to: documents.appendingPathComponent("a.bin"))
        try payload.write(to: documents.appendingPathComponent("b.bin"))

        #expect(try DuplicateScanner.scan(roots: [documents], minimumSize: 10_000_000).isEmpty)
    }
}

@Suite("Large file scan")
struct LargeFileScannerTests {
    @Test func findsOnlyFilesOverTheThresholdAndSkipsExcludedTrees() throws {
        let temp = try TemporaryDirectory()
        try temp.makeFile("Movies/big.mov", bytes: 3_000_000)
        try temp.makeFile("Movies/small.mov", bytes: 1_000)
        try temp.makeFile("Library/Caches/huge.bin", bytes: 5_000_000)

        let items = try LargeFileScanner.scan(
            root: temp.url,
            minimumSize: 2_000_000,
            excluded: CleanupCatalog.excludedScanDirectories(home: temp.url)
        )

        #expect(items.map(\.name) == ["big.mov"])
    }
}

@Suite("Catalog coverage")
struct CatalogCoverageTests {
    @Test func developerEcosystemsAreCovered() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let ids = Set(CleanupCatalog.rules(home: home).map(\.id))
        for expected in ["dev.npm", "dev.pnpm", "dev.bun", "dev.gradle",
                         "dev.maven", "dev.cargo", "dev.cache.dir",
                         "project.node_modules", "docker.data"] {
            #expect(ids.contains(expected), "missing rule \(expected)")
        }
    }

    /// Overlaps that were reviewed and are safe, each because the outer rule
    /// provably never enumerates the inner path. Anything not on this list is a
    /// bug: two rules reporting the same bytes would let a user "reclaim" the
    /// same gigabyte twice.
    private static let reviewedOverlaps: [(inner: String, outer: String, reason: String)] = [
        ("Library/Logs/DiagnosticReports", "Library/Logs",
         "the logs rule excludes DiagnosticReports by name"),
        ("Library/Application Support/MobileSync/Backup", "Library/Application Support",
         "the leftovers rule only lists folders named like a bundle identifier"),
        ("Library/Containers/com.docker.docker/Data/vms", "Library/Containers",
         "the container rule only measures Data/Library/Caches"),
    ]

    /// Deep scans legitimately share the home folder as a starting point — a
    /// large file can also be a duplicate. Every other rule owns its location.
    @Test func noDeletionRuleOverlapsAnother() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = CleanupCatalog.rules(home: home)
            .filter { !$0.isDeepScan }
            .map(\.root.standardizedFileURL.path)

        #expect(Set(roots).count == roots.count, "two rules point at the same folder")

        let allowed = Set(Self.reviewedOverlaps.map {
            "\(home.appendingPathComponent($0.inner).path)|\(home.appendingPathComponent($0.outer).path)"
        })
        for root in roots {
            for other in roots where other != root && PathSafety.isDescendant(root, of: other) {
                #expect(allowed.contains("\(root)|\(other)"),
                        "\(root) is inside \(other) and has not been reviewed")
            }
        }
    }

    @Test func noDeveloperCacheSitsInsideTheApplicationCachesRule() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let caches = home.appendingPathComponent("Library/Caches").path
        for rule in CleanupCatalog.rules(home: home) where rule.id.hasPrefix("dev.") {
            #expect(!PathSafety.isDescendant(rule.root.path, of: caches),
                    "\(rule.id) is already covered by the Application Caches rule")
        }
    }

    @Test func theDockerRuleReportsWithoutOfferingDeletion() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let rule = try #require(CleanupCatalog.rules(home: home).first { $0.id == "docker.data" })
        guard case .advisory = rule.kind else {
            Issue.record("Docker must be advisory, never deletable")
            return
        }
        let scanner = CleanupScanner(home: home)
        let groups = try await scanner.scan(rules: [rule], progress: { _ in })
        let group = try #require(groups.first)
        print("DOCKER advisory=\(group.advice != nil) size=\(group.issues.first?.reason ?? "none")")
        #expect(group.items.isEmpty, "an advisory group must never offer anything to delete")
    }

    /// Deliberately reads the machine it runs on: the point is that the
    /// catalog's paths match where these tools really put their caches, which a
    /// fixture cannot tell you. A clean CI runner has none of them, so there it
    /// would only ever assert that the runner is clean.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                   "needs a developer machine's real caches"))
    func realDeveloperCachesAreFoundOnThisMac() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let rules = CleanupCatalog.rules(home: home).filter { $0.id.hasPrefix("dev.") }
        let scanner = CleanupScanner(home: home)
        let groups = try await scanner.scan(rules: rules, progress: { _ in })
        for group in groups where group.totalSize > 0 {
            print("DEVCACHE \(group.title): \(Format.bytes(group.totalSize)) in \(group.items.count) items")
        }
        #expect(groups.contains { $0.totalSize > 0 })
    }
}
