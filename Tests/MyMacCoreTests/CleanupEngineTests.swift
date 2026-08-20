import Foundation
import Testing
@testable import MyMacCore

@Suite("Cleanup engine")
struct CleanupEngineTests {
    private func item(_ url: URL, size: Int64 = 1024) -> CleanupItem {
        CleanupItem(url: url, name: url.lastPathComponent, size: size, modified: Date())
    }

    @Test func removesApprovedItemsAndReportsReclaimedSpace() async throws {
        let temp = try TemporaryDirectory()
        let root = try temp.makeDirectory("Library/Caches")
        let first = try temp.makeDirectory("Library/Caches/com.example.one")
        try temp.makeFile("Library/Caches/com.example.one/blob.bin", bytes: 2048)
        let second = try temp.makeFile("Library/Caches/loose.bin", bytes: 4096)

        let engine = CleanupEngine(home: temp.url)
        let outcome = await engine.perform([
            .init(items: [item(first, size: 2048), item(second, size: 4096)],
                  removal: .delete, allowedRoots: [root])
        ])

        #expect(outcome.removedCount == 2)
        #expect(outcome.reclaimedBytes == 6144)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.rejectedCount == 0)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: root.path), "the root itself must survive")
    }

    @Test func refusesItemsOutsideTheDeclaredRoots() async throws {
        let temp = try TemporaryDirectory()
        let root = try temp.makeDirectory("Library/Caches")
        let document = try temp.makeFile("Documents/thesis.pdf", bytes: 10_000)

        // A tampered or stale result claiming a path the rule never authorised.
        let engine = CleanupEngine(home: temp.url)
        let outcome = await engine.perform([
            .init(items: [item(document)], removal: .delete, allowedRoots: [root])
        ])

        #expect(outcome.removedCount == 0)
        #expect(outcome.rejectedCount == 1)
        #expect(FileManager.default.fileExists(atPath: document.path))
    }

    @Test func neverFollowsASymlinkOutOfScope() async throws {
        let temp = try TemporaryDirectory()
        let root = try temp.makeDirectory("Library/Caches")
        let photos = try temp.makeDirectory("Pictures/Album")
        let photo = try temp.makeFile("Pictures/Album/holiday.jpg", bytes: 5_000)
        let link = try temp.makeSymlink("Library/Caches/com.example.cache", to: photos)

        let engine = CleanupEngine(home: temp.url)
        let outcome = await engine.perform([
            .init(items: [item(link)], removal: .delete, allowedRoots: [root])
        ])

        #expect(outcome.rejectedCount == 1)
        #expect(FileManager.default.fileExists(atPath: photo.path))
        #expect(FileManager.default.fileExists(atPath: link.path))
    }

    @Test func treatsAVanishedItemAsAlreadyDone() async throws {
        let temp = try TemporaryDirectory()
        let root = try temp.makeDirectory("Library/Caches")
        let ghost = try temp.makeFile("Library/Caches/gone.bin")
        try FileManager.default.removeItem(at: ghost)

        let engine = CleanupEngine(home: temp.url)
        let outcome = await engine.perform([
            .init(items: [item(ghost)], removal: .delete, allowedRoots: [root])
        ])

        #expect(outcome.removedCount == 0)
        #expect(outcome.failures.isEmpty, "a file disappearing is not an error")
        #expect(outcome.rejectedCount == 0)
    }

    @Test func reportsPermissionErrorsWithoutFailingTheWholeRun() async throws {
        let temp = try TemporaryDirectory()
        let root = try temp.makeDirectory("Library/Caches")
        let locked = try temp.makeDirectory("Library/Caches/locked")
        let trapped = try temp.makeFile("Library/Caches/locked/inner.bin")
        let removable = try temp.makeFile("Library/Caches/free.bin", bytes: 2048)
        // Read+execute only: the file can be seen but not unlinked.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)

        let engine = CleanupEngine(home: temp.url)
        let outcome = await engine.perform([
            .init(items: [item(trapped), item(removable, size: 2048)],
                  removal: .delete, allowedRoots: [root])
        ])

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)

        #expect(outcome.removedCount == 1, "the accessible item is still removed")
        #expect(outcome.failures.count == 1)
        #expect(outcome.failures.first?.reason.contains("Permission") == true)
        #expect(!FileManager.default.fileExists(atPath: removable.path))
    }

    @Test func reportsProgressForEveryItem() async throws {
        let temp = try TemporaryDirectory()
        let root = try temp.makeDirectory("Library/Caches")
        let files = try (0..<5).map { try temp.makeFile("Library/Caches/file-\($0).bin") }

        let recorder = ProgressRecorder()
        let engine = CleanupEngine(home: temp.url)
        _ = await engine.perform(
            [.init(items: files.map { item($0) }, removal: .delete, allowedRoots: [root])],
            progress: { fraction, _ in recorder.record(fraction) }
        )

        #expect(recorder.values.count == 5)
        #expect(recorder.values.last == 1.0)
    }
}

/// Small thread-safe box; the progress callback is `@Sendable`.
final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func record(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        storage.append(value)
    }

    var values: [Double] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

@Suite("Nested category constraint")
struct NestedCategoryTests {
    @Test func refusesItemsThatAreNotAtTheCategorysExpectedDepth() async throws {
        let temp = try TemporaryDirectory()
        let root = try temp.makeDirectory("Library/Containers")
        let container = try temp.makeDirectory("Library/Containers/com.example.app")
        try temp.makeFile("Library/Containers/com.example.app/Data/Library/Caches/blob.bin", bytes: 4096)
        let caches = container.appendingPathComponent("Data/Library/Caches")

        let engine = CleanupEngine(home: temp.url)

        // The whole container is inside the allowed root, but is not what the
        // rule authorises.
        let bad = await engine.perform([
            .init(items: [CleanupItem(url: container, name: "container", size: 4096, modified: nil)],
                  removal: .delete, allowedRoots: [root], requiredSuffix: "Data/Library/Caches")
        ])
        #expect(bad.rejectedCount == 1)
        #expect(FileManager.default.fileExists(atPath: container.path))

        // The caches folder itself is accepted.
        let good = await engine.perform([
            .init(items: [CleanupItem(url: caches, name: "caches", size: 4096, modified: nil)],
                  removal: .delete, allowedRoots: [root], requiredSuffix: "Data/Library/Caches")
        ])
        #expect(good.removedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: caches.path))
        #expect(FileManager.default.fileExists(atPath: container.path))
    }
}
