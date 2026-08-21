import Foundation

/// Finds unusually large files so the user can decide about them.
///
/// This is the only scan that walks a broad tree, which is exactly why it is
/// opt-in, skips package contents, and never descends through symbolic links.
enum LargeFileScanner {
    /// Enough to be useful, few enough that the list stays reviewable and the
    /// result set stays small in memory.
    static let resultLimit = 200

    /// Trees that are never worth walking for a multi-gigabyte single file:
    /// dependency and build directories hold many small files, and a repository
    /// database is not something to offer for deletion. Skipping them turns a
    /// multi-minute crawl of a developer's home folder into seconds.
    /// Two reasons a directory is here: it holds many small files and cannot
    /// contain a single multi-gigabyte one, or a dedicated cleanup rule already
    /// owns it — and a folder reported by two rules invites the user to
    /// "reclaim" the same gigabyte twice.
    ///
    /// `CatalogCoverageTests` enforces the second half: every developer-cache
    /// rule must be unreachable from a deep scan.
    static let skippedDirectoryNames: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", "Pods", ".venv", "venv",
        ".gradle", ".cargo", ".rustup", ".terraform", "vendor",
        ".m2", ".npm", ".bun",
    ]

    static func scan(root: URL, minimumSize: Int64, excluded: Set<String>,
                     progress: @Sendable (Int) -> Void = { _ in }) throws -> [CleanupItem] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                         .isPackageKey, .totalFileAllocatedSizeKey,
                                         .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var items: [CleanupItem] = []
        var counter = 0
        for case let url as URL in enumerator {
            counter += 1
            if counter % 512 == 0 {
                try Task.checkCancellation()
                progress(counter)
            }

            guard let values = try? url.resourceValues(forKeys: keys) else { continue }

            if values.isDirectory == true {
                if excluded.contains(url.standardizedFileURL.path)
                    || skippedDirectoryNames.contains(url.lastPathComponent)
                    || values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            guard size >= minimumSize else { continue }

            items.append(CleanupItem(
                url: url,
                name: url.lastPathComponent,
                detail: url.deletingLastPathComponent().path,
                size: size,
                modified: values.contentModificationDate
            ))

            // Keep only the biggest results rather than growing without bound.
            if items.count > resultLimit * 2 {
                items.sort { $0.size > $1.size }
                items.removeLast(items.count - resultLimit)
            }
        }

        items.sort { $0.size > $1.size }
        return Array(items.prefix(resultLimit))
    }
}
