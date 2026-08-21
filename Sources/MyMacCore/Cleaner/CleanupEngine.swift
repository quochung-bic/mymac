import Foundation

/// Performs the removals the user confirmed.
///
/// The engine re-validates every path against `PathSafety` immediately before
/// touching it, using the rule roots as the allowlist. The scan results are
/// treated as untrusted input: minutes may have passed, and a path that was
/// safe then may be a symlink now.
public actor CleanupEngine {
    public struct Request: Sendable {
        public let items: [CleanupItem]
        public let removal: RemovalMode
        /// The roots the items were discovered under. Nothing outside these can
        /// be removed, whatever the item claims its path is.
        public let allowedRoots: [URL]
        /// Extra constraint for rules whose targets sit at a known depth below
        /// the root. `~/Library/Containers` as a bare root would authorise
        /// deleting a whole app container; requiring the path to end in
        /// `Data/Library/Caches` narrows it back to what the rule meant.
        public let requiredSuffix: String?

        public init(items: [CleanupItem], removal: RemovalMode,
                    allowedRoots: [URL], requiredSuffix: String? = nil) {
            self.items = items
            self.removal = removal
            self.allowedRoots = allowedRoots
            self.requiredSuffix = requiredSuffix
        }
    }

    private let home: URL
    private let fileManager: FileManager

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                fileManager: FileManager = .default) {
        self.home = home
        self.fileManager = fileManager
    }

    public func perform(
        _ requests: [Request],
        progress: @Sendable @escaping (Double, String) -> Void = { _, _ in }
    ) async -> CleanupOutcome {
        let total = requests.reduce(0) { $0 + $1.items.count }
        guard total > 0 else {
            return CleanupOutcome(removedCount: 0, reclaimedBytes: 0, trashedCount: 0,
                                  failures: [], rejectedCount: 0)
        }

        var removed = 0
        var trashed = 0
        var reclaimed: Int64 = 0
        var rejected = 0
        var failures: [CleanupOutcome.Failure] = []
        var completed = 0
        // Resolved once for the whole run rather than per item.
        let context = PathSafety.Context(home: home)

        // Labelled: breaking only the inner loop left the outer one walking
        // every remaining request to break out of each in turn.
        requests: for request in requests {
            for item in request.items {
                if Task.isCancelled { break requests }
                completed += 1
                progress(Double(completed) / Double(total), item.name)

                let canonicalPath: String
                do {
                    canonicalPath = try PathSafety.canonicalPathForRemoval(
                        of: item.url, allowedRoots: request.allowedRoots, context: context
                    )
                } catch let violation as PathSafety.Violation {
                    if violation == .doesNotExist {
                        // Something else already removed it. Not a failure.
                        Log.cleaner.debug("skipping vanished path \(item.url.path, privacy: .private)")
                        continue
                    }
                    rejected += 1
                    Log.cleaner.error("refused \(item.url.path, privacy: .private): \(violation.reason)")
                    failures.append(.init(path: item.url.path, reason: violation.reason))
                    continue
                } catch {
                    rejected += 1
                    failures.append(.init(path: item.url.path, reason: error.localizedDescription))
                    continue
                }

                if let suffix = request.requiredSuffix,
                   !canonicalPath.hasSuffix("/" + suffix) {
                    rejected += 1
                    Log.cleaner.error("refused \(item.url.path, privacy: .private): unexpected location for this category")
                    failures.append(.init(path: item.url.path,
                                          reason: "path is not where this category's items live"))
                    continue
                }

                let target = URL(fileURLWithPath: canonicalPath)
                do {
                    switch request.removal {
                    case .delete:
                        try fileManager.removeItem(at: target)
                        removed += 1
                    case .trash:
                        try fileManager.trashItem(at: target, resultingItemURL: nil)
                        trashed += 1
                    }
                    reclaimed += item.size
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    continue
                } catch {
                    Log.cleaner.error("failed to remove \(target.path, privacy: .private): \(error.localizedDescription)")
                    failures.append(.init(path: target.path, reason: Self.describe(error)))
                }
            }
        }

        return CleanupOutcome(removedCount: removed, reclaimedBytes: reclaimed,
                              trashedCount: trashed, failures: failures, rejectedCount: rejected)
    }

    /// Turns Cocoa's error codes into something a person can act on.
    private nonisolated static func describe(_ error: Error) -> String {
        guard let cocoa = error as? CocoaError else { return error.localizedDescription }
        switch cocoa.code {
        case .fileReadNoPermission, .fileWriteNoPermission:
            return "Permission denied. Grant Full Disk Access in System Settings if you want this location cleaned."
        case .fileWriteFileExists:
            return "An item with the same name already exists in the Trash."
        case .fileNoSuchFile:
            return "The item no longer exists."
        case .fileWriteVolumeReadOnly:
            return "The volume is read-only."
        default:
            return cocoa.localizedDescription
        }
    }
}
