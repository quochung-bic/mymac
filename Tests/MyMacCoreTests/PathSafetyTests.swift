import Foundation
import Testing
@testable import MyMacCore

@Suite("Path safety")
struct PathSafetyTests {
    @Test func acceptsItemInsideAnAllowedRoot() throws {
        let temp = try TemporaryDirectory()
        let root = try temp.makeDirectory("Library/Caches")
        let item = try temp.makeDirectory("Library/Caches/com.example.app")

        let canonical = try PathSafety.canonicalPathForRemoval(of: item, allowedRoots: [root], home: temp.url)
        #expect(canonical.hasSuffix("Library/Caches/com.example.app"))
    }

    @Test func rejectsPathOutsideEveryRoot() throws {
        let temp = try TemporaryDirectory()
        let root = try temp.makeDirectory("Library/Caches")
        let outsider = try temp.makeDirectory("Library/Application Support/Something")

        #expect(throws: PathSafety.Violation.outsideAllowedRoot) {
            try PathSafety.canonicalPathForRemoval(of: outsider, allowedRoots: [root], home: temp.url)
        }
    }

    @Test func rejectsTheRootItself() throws {
        let temp = try TemporaryDirectory()
        let root = try temp.makeDirectory("Library/Caches")

        // Containment is strict, so emptying a root can never delete the root.
        #expect(throws: PathSafety.Violation.self) {
            try PathSafety.canonicalPathForRemoval(of: root, allowedRoots: [root], home: temp.url)
        }
    }

    @Test func rejectsSymbolicLinks() throws {
        let temp = try TemporaryDirectory()
        let root = try temp.makeDirectory("Library/Caches")
        let secret = try temp.makeDirectory("Documents/Important")
        let link = try temp.makeSymlink("Library/Caches/looks-like-a-cache", to: secret)

        #expect(throws: PathSafety.Violation.isSymbolicLink) {
            try PathSafety.canonicalPathForRemoval(of: link, allowedRoots: [root], home: temp.url)
        }
        #expect(FileManager.default.fileExists(atPath: secret.path))
    }

    @Test func rejectsEscapeThroughASymlinkedParent() throws {
        let temp = try TemporaryDirectory()
        let root = try temp.makeDirectory("Library/Caches")
        let outside = try temp.makeDirectory("Documents/Payroll")
        try temp.makeFile("Documents/Payroll/ledger.txt")
        try temp.makeSymlink("Library/Caches/bridge", to: outside)

        // The path spells out something under the allowed root, but the parent
        // resolves elsewhere. Resolving the parent is what catches this.
        let disguised = root.appendingPathComponent("bridge/ledger.txt")
        #expect(throws: PathSafety.Violation.outsideAllowedRoot) {
            try PathSafety.canonicalPathForRemoval(of: disguised, allowedRoots: [root], home: temp.url)
        }
    }

    @Test func rejectsParentDirectoryTraversal() throws {
        let temp = try TemporaryDirectory()
        let root = try temp.makeDirectory("Library/Caches")
        try temp.makeDirectory("Documents/Photos")

        // URL(fileURLWithPath:) keeps ".." literal until standardized.
        let traversal = URL(fileURLWithPath: root.path + "/../../Documents/Photos")
        #expect(throws: PathSafety.Violation.self) {
            try PathSafety.canonicalPathForRemoval(of: traversal, allowedRoots: [root], home: temp.url)
        }
    }

    @Test func rejectsProtectedDirectories() throws {
        let temp = try TemporaryDirectory()
        let documents = try temp.makeDirectory("Documents")

        #expect(throws: PathSafety.Violation.isProtectedDirectory) {
            try PathSafety.canonicalPathForRemoval(of: documents, allowedRoots: [temp.url], home: temp.url)
        }
    }

    @Test func rejectsAnythingBelowAProtectedAncestor() throws {
        let temp = try TemporaryDirectory()
        let key = try temp.makeFile(".ssh/id_ed25519")

        #expect(throws: PathSafety.Violation.hasProtectedAncestor) {
            try PathSafety.canonicalPathForRemoval(of: key, allowedRoots: [temp.url], home: temp.url)
        }
    }

    @Test func rejectsShallowPaths() {
        #expect(throws: PathSafety.Violation.tooShallow) {
            try PathSafety.canonicalPathForRemoval(
                of: URL(fileURLWithPath: "/tmp"),
                allowedRoots: [URL(fileURLWithPath: "/")],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
        }
    }

    @Test func rejectsVanishedPaths() throws {
        let temp = try TemporaryDirectory()
        let root = try temp.makeDirectory("Library/Caches")

        #expect(throws: PathSafety.Violation.doesNotExist) {
            try PathSafety.canonicalPathForRemoval(
                of: root.appendingPathComponent("gone"), allowedRoots: [root], home: temp.url
            )
        }
    }

    @Test func containmentComparesWholePathComponents() {
        #expect(PathSafety.isDescendant("/a/b/c", of: "/a/b"))
        #expect(!PathSafety.isDescendant("/a/bc", of: "/a/b"))
        #expect(!PathSafety.isDescendant("/a/b", of: "/a/b"))
        #expect(PathSafety.isDescendant("/a/b/c", of: "/a/b/"))
    }

    /// An application bundle sits two components below the volume root, so the
    /// cleaner's floor of three refused every single one of them.
    @Test func acceptsAnApplicationBundleDirectlyInsideApplications() throws {
        let applications = URL(fileURLWithPath: "/Applications")
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: applications, includingPropertiesForKeys: [.isSymbolicLinkKey]
        )) ?? []
        guard let bundle = contents.first(where: {
            $0.pathExtension == "app"
                && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
        }) else { return }

        let canonical = try PathSafety.canonicalPathForRemoval(
            of: bundle,
            allowedRoots: [applications],
            minimumDepth: PathSafety.minimumApplicationDepth
        )
        #expect(canonical == bundle.path)
    }

    /// The floor of two exists for `/Applications/Xcode.app`. A product folder
    /// such as `/Applications/Python 3.11` sits at the same depth and is not a
    /// bundle; nor is `/Library/Fonts`, which exists on every Mac.
    @Test func lowersTheDepthFloorForApplicationBundlesOnly() {
        #expect(throws: PathSafety.Violation.tooShallow) {
            try PathSafety.canonicalPathForRemoval(
                of: URL(fileURLWithPath: "/Library/Fonts"),
                allowedRoots: [URL(fileURLWithPath: "/Library")],
                minimumDepth: PathSafety.minimumApplicationDepth,
                home: FileManager.default.homeDirectoryForCurrentUser
            )
        }
    }

    /// Refused twice over — it is not a bundle, and it is protected — and
    /// which rule answers first does not matter, only that it never passes.
    @Test func refusesAProtectedDirectoryAtTheApplicationDepth() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(throws: PathSafety.Violation.self) {
            try PathSafety.canonicalPathForRemoval(
                of: home,
                allowedRoots: [home.deletingLastPathComponent()],
                minimumDepth: PathSafety.minimumApplicationDepth,
                home: home
            )
        }
    }

    /// The only direct child of an uninstaller root that is not itself an
    /// application bundle. With the bundle depth floor at two, nothing but the
    /// protected set stands between it and a removal.
    @Test func theUtilitiesFolderIsProtectedFromRemoval() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(PathSafety.protectedDirectories(home: home).contains("/Applications/Utilities"))
    }

    @Test func everyCatalogRootIsProtectedFromRemoval() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let protectedPaths = PathSafety.protectedDirectories(home: home)
        for rule in CleanupCatalog.rules(home: home) {
            #expect(protectedPaths.contains(rule.root.standardizedFileURL.path),
                    "rule \(rule.id) root is not protected: \(rule.root.path)")
        }
    }
}
