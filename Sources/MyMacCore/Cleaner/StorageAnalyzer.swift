import Foundation

public struct StorageCategory: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let url: URL?
    public let bytes: Int64

    public init(id: String, name: String, url: URL?, bytes: Int64) {
        self.id = id
        self.name = name
        self.url = url
        self.bytes = bytes
    }
}

public struct StorageBreakdown: Sendable, Equatable {
    public let categories: [StorageCategory]
    public let volumeUsed: Int64

    public var measured: Int64 { categories.reduce(0) { $0 + $1.bytes } }

    public init(categories: [StorageCategory], volumeUsed: Int64) {
        self.categories = categories
        self.volumeUsed = volumeUsed
    }
}

public struct StorageProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public let currentName: String

    public var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }

    public init(completed: Int, total: Int, currentName: String) {
        self.completed = completed
        self.total = total
        self.currentName = currentName
    }
}

/// Works out where the space on the boot volume has gone.
///
/// This walks large trees and takes real time, which is why it only ever runs
/// when the user asks for it. Every folder measured is disjoint from the others,
/// so the totals add up and nothing is counted twice; whatever is left over —
/// the system itself, other users, anything outside the home folder — is
/// reported honestly as one remainder rather than silently dropped.
public actor StorageAnalyzer {
    /// Folders inside `~/Library` worth naming on their own. Library is almost
    /// always the largest thing in a home folder and the least understood.
    private static let libraryHighlights = [
        "Caches", "Containers", "Application Support", "Developer",
        "Group Containers", "Mobile Documents", "Mail", "Messages",
    ]

    /// Enough parallelism to keep an SSD busy without thrashing the walk.
    private static let concurrency = 4

    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func analyze(volumeUsed: Int64,
                        progress: @Sendable @escaping (StorageProgress) -> Void) async throws -> StorageBreakdown {
        let targets = try scanTargets()
        var measured: [StorageCategory] = []
        var completed = 0

        try await withThrowingTaskGroup(of: StorageCategory?.self) { group in
            var next = targets.startIndex

            func addTask(_ index: Int) {
                let target = targets[index]
                group.addTask {
                    try Task.checkCancellation()
                    let bytes = (try? DirectorySizer.measure(target.url))?.bytes ?? 0
                    guard bytes > 0 else { return nil }
                    return StorageCategory(id: target.url.path, name: target.name,
                                           url: target.url, bytes: bytes)
                }
            }

            while next < targets.endIndex, next < Self.concurrency {
                addTask(next)
                next += 1
            }

            while let category = try await group.next() {
                completed += 1
                progress(StorageProgress(completed: completed, total: targets.count,
                                         currentName: category?.name ?? ""))
                if let category { measured.append(category) }
                if next < targets.endIndex {
                    addTask(next)
                    next += 1
                }
            }
        }

        let remainder = volumeUsed - measured.reduce(0) { $0 + $1.bytes }
        if remainder > 0 {
            measured.append(StorageCategory(id: "system", name: "System & other files",
                                            url: nil, bytes: remainder))
        }
        return StorageBreakdown(categories: measured.sorted { $0.bytes > $1.bytes },
                                volumeUsed: volumeUsed)
    }

    private struct Target {
        let name: String
        let url: URL
    }

    /// Top-level entries of the home folder plus /Applications, with `~/Library`
    /// expanded one level so its big rooms are named rather than lumped together.
    private func scanTargets() throws -> [Target] {
        var targets: [Target] = [
            Target(name: "Applications", url: URL(fileURLWithPath: "/Applications")),
        ]
        let library = home.appendingPathComponent("Library")

        for url in children(of: home) {
            let name = url.lastPathComponent
            if url.standardizedFileURL == library.standardizedFileURL {
                let highlighted = Set(Self.libraryHighlights)
                for child in children(of: library) where highlighted.contains(child.lastPathComponent) {
                    targets.append(Target(name: "Library / \(child.lastPathComponent)", url: child))
                }
                for child in children(of: library) where !highlighted.contains(child.lastPathComponent) {
                    targets.append(Target(name: "Library / \(child.lastPathComponent)", url: child))
                }
                continue
            }
            targets.append(Target(name: name == ".Trash" ? "Trash" : name, url: url))
        }
        return targets
    }

    private func children(of url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []
        )) ?? []
        return contents.filter { child in
            let values = try? child.resourceValues(forKeys: [.isSymbolicLinkKey])
            return values?.isSymbolicLink != true
        }
    }
}
