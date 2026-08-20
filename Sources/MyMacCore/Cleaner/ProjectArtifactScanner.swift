import Foundation

/// Finds regenerable build artefacts inside project trees — `node_modules` and
/// friends.
///
/// These are the largest reclaimable directories on most developer machines,
/// but they are also project state, so they are only ever reported for review.
/// The scan never descends into a match: the interesting number is the size of
/// the whole folder, and walking its interior twice would double the cost.
enum ProjectArtifactScanner {
    static let resultLimit = 100
    /// Project trees are rarely deeper than this, and the cap keeps a stray
    /// symlinked or generated tree from turning the scan into a full crawl.
    static let maximumDepth = 7

    static func scan(root: URL, named name: String, minimumSize: Int64,
                     minimumAge: TimeInterval?, excluded: Set<String>,
                     progress: @Sendable (Int) -> Void = { _ in }) throws -> [CleanupItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants, .skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var items: [CleanupItem] = []
        var counter = 0

        for case let url as URL in enumerator {
            counter += 1
            if counter % 256 == 0 {
                try Task.checkCancellation()
                progress(counter)
            }

            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }

            if enumerator.level > maximumDepth
                || excluded.contains(url.standardizedFileURL.path)
                || (url.lastPathComponent != name
                    && LargeFileScanner.skippedDirectoryNames.contains(url.lastPathComponent)) {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent == name else { continue }
            enumerator.skipDescendants()

            let measured = try DirectorySizer.measure(url)
            guard measured.bytes >= minimumSize else { continue }
            if let minimumAge, let modified = measured.newestModification,
               Date().timeIntervalSince(modified) < minimumAge { continue }

            items.append(CleanupItem(
                url: url,
                name: url.deletingLastPathComponent().lastPathComponent,
                detail: url.deletingLastPathComponent().path,
                size: measured.bytes,
                modified: measured.newestModification
            ))
            if items.count >= resultLimit { break }
        }

        return items.sorted { $0.size > $1.size }
    }
}
