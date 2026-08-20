import Foundation

/// Streaming size accounting.
///
/// The enumerator is consumed one URL at a time and nothing is retained, so
/// measuring a folder with a million files costs a bounded amount of memory.
/// `FileManager`'s enumerator does not descend into symbolic links, which is
/// also what keeps a link out of `~/Library/Caches` from inflating a total.
enum DirectorySizer {
    struct Result {
        var bytes: Int64 = 0
        var fileCount: Int = 0
        var accessDenied = false
        var newestModification: Date?
    }

    private static let sizeKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey, .contentModificationDateKey,
    ]

    /// - Throws: `CancellationError` if the surrounding task is cancelled.
    static func measure(_ url: URL) throws -> Result {
        var result = Result()

        let values = try? url.resourceValues(forKeys: sizeKeys)
        if values?.isSymbolicLink == true { return result }
        if values?.isRegularFile == true {
            result.bytes = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            result.fileCount = 1
            result.newestModification = values?.contentModificationDate
            return result
        }
        result.newestModification = values?.contentModificationDate

        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(sizeKeys),
            options: [],
            errorHandler: { _, _ in
                // A file vanishing mid-walk is expected on a live system.
                // Keep going; the total is an estimate either way.
                true
            }
        )
        guard let enumerator else {
            result.accessDenied = true
            return result
        }

        var counter = 0
        for case let child as URL in enumerator {
            counter += 1
            // Check often enough that a cancelled scan stops promptly, rarely
            // enough that the check itself is not the bottleneck.
            if counter % 512 == 0 { try Task.checkCancellation() }

            guard let childValues = try? child.resourceValues(forKeys: sizeKeys) else { continue }
            guard childValues.isSymbolicLink != true, childValues.isRegularFile == true else { continue }
            result.bytes += Int64(childValues.totalFileAllocatedSize ?? childValues.fileAllocatedSize ?? 0)
            result.fileCount += 1
            if let modified = childValues.contentModificationDate {
                if let newest = result.newestModification {
                    result.newestModification = max(newest, modified)
                } else {
                    result.newestModification = modified
                }
            }
        }
        return result
    }
}
