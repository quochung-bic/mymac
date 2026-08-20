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

    @Test func everyCatalogRootIsProtectedFromRemoval() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let protectedPaths = PathSafety.protectedDirectories(home: home)
        for rule in CleanupCatalog.rules(home: home) {
            #expect(protectedPaths.contains(rule.root.standardizedFileURL.path),
                    "rule \(rule.id) root is not protected: \(rule.root.path)")
        }
    }
}
