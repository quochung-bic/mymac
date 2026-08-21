import CryptoKit
import Foundation

/// Content-based duplicate detection.
///
/// Three passes, cheapest first: group by exact size, then by a hash of the
/// first 64 KB, then by a full streaming hash. Most candidates die in the first
/// two passes, so very few files are ever read end to end. Names are irrelevant
/// throughout — only bytes decide.
enum DuplicateScanner {
    static let headerSampleSize = 64 * 1024
    static let groupLimit = 200

    static func scan(roots: [URL], minimumSize: Int64) throws -> [CleanupItem] {
        var bySize: [Int64: [URL]] = [:]

        for root in roots {
            try collectCandidates(root: root, minimumSize: minimumSize, into: &bySize)
        }

        var candidates: [[URL]] = []
        for (_, urls) in bySize where urls.count > 1 {
            candidates.append(urls)
        }
        guard !candidates.isEmpty else { return [] }

        var items: [CleanupItem] = []
        var groupCount = 0

        for group in candidates.sorted(by: { $0.count > $1.count }) {
            try Task.checkCancellation()
            guard groupCount < groupLimit else { break }

            for identical in try refine(group) where identical.count > 1 {
                groupCount += 1
                // The oldest copy is treated as the original and is not listed,
                // so accepting every suggestion still leaves one copy behind.
                let ordered = identical.sorted { lhs, rhs in
                    (creationDate(lhs) ?? .distantFuture) < (creationDate(rhs) ?? .distantFuture)
                }
                guard let original = ordered.first else { continue }
                for duplicate in ordered.dropFirst() {
                    guard let values = try? duplicate.resourceValues(
                        forKeys: [.totalFileAllocatedSizeKey, .contentModificationDateKey]
                    ) else { continue }
                    items.append(CleanupItem(
                        url: duplicate,
                        name: duplicate.lastPathComponent,
                        detail: "Identical to \(original.path)",
                        size: Int64(values.totalFileAllocatedSize ?? 0),
                        modified: values.contentModificationDate
                    ))
                }
            }
        }
        return items
    }

    /// Groups on the **logical** size, not the allocated one.
    ///
    /// Two files can hold byte-for-byte identical content and still occupy
    /// different amounts of disk — one compressed by APFS, one cloned, one
    /// sparse. Keying the first pass on allocated size put those in separate
    /// groups, so they were never compared and the duplicate was never found.
    /// What is *reported* stays the allocated size, because that is what
    /// removing the file actually gives back.
    private static func collectCandidates(root: URL, minimumSize: Int64,
                                          into bySize: inout [Int64: [URL]]) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey,
                                         .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants], errorHandler: { _, _ in true }
        ) else { return }

        var counter = 0
        for case let url as URL in enumerator {
            counter += 1
            if counter % 512 == 0 { try Task.checkCancellation() }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            guard size >= minimumSize else { continue }
            bySize[size, default: []].append(url)
        }
    }

    /// Splits a same-size group into sets of genuinely identical files.
    private static func refine(_ urls: [URL]) throws -> [[URL]] {
        var byHeader: [String: [URL]] = [:]
        for url in urls {
            try Task.checkCancellation()
            guard let digest = try? hash(url, limit: headerSampleSize) else { continue }
            byHeader[digest, default: []].append(url)
        }

        var result: [[URL]] = []
        for (_, group) in byHeader where group.count > 1 {
            var byContent: [String: [URL]] = [:]
            for url in group {
                try Task.checkCancellation()
                guard let digest = try? hash(url, limit: nil) else { continue }
                byContent[digest, default: []].append(url)
            }
            result.append(contentsOf: byContent.values.filter { $0.count > 1 })
        }
        return result
    }

    /// Hashes in 1 MB chunks so a 40 GB video never lands in memory.
    private static func hash(_ url: URL, limit: Int?) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            let chunkSize = min(remaining, 1024 * 1024)
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func creationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}
