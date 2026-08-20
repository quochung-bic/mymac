import Foundation

/// Walks the catalog's rules and turns them into reviewable groups.
///
/// The scan only ever *reads*. It is an actor so a second scan cannot start on
/// top of a running one, runs at utility priority so it stays out of the way,
/// and checks for cancellation continuously.
public actor CleanupScanner {
    private let home: URL
    private let inventory: any ApplicationInventory

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                inventory: any ApplicationInventory = ConservativeApplicationInventory()) {
        self.home = home
        self.inventory = inventory
    }

    public func scan(
        rules: [CleanupRule],
        progress: @Sendable @escaping (ScanProgress) -> Void
    ) async throws -> [CleanupGroup] {
        var groups: [CleanupGroup] = []
        var bytesFound: Int64 = 0

        for (index, rule) in rules.enumerated() {
            try Task.checkCancellation()
            progress(ScanProgress(completedRules: index, totalRules: rules.count,
                                  currentTitle: rule.title, bytesFound: bytesFound))

            let bytesSoFar = bytesFound
            let group = try scan(rule: rule) { count in
                progress(ScanProgress(completedRules: index, totalRules: rules.count,
                                      currentTitle: rule.title, bytesFound: bytesSoFar,
                                      examinedFiles: count))
            }
            bytesFound += group.totalSize
            groups.append(group)

            // Yield between rules so the interface can paint partial progress.
            await Task.yield()
        }

        progress(ScanProgress(completedRules: rules.count, totalRules: rules.count,
                              currentTitle: "Done", bytesFound: bytesFound))
        return groups
    }

    private func scan(rule: CleanupRule, examined: @Sendable @escaping (Int) -> Void = { _ in }) throws -> CleanupGroup {
        var items: [CleanupItem] = []
        var issues: [CleanupIssue] = []
        var denied = false

        switch rule.kind {
        case .directoryChildren:
            (items, denied) = try scanChildren(of: rule.root, rule: rule)
        case .nestedDirectories(let relativePath):
            (items, denied) = try scanNested(rule: rule, relativePath: relativePath)
        case .filesRecursive:
            (items, denied) = try scanFiles(rule: rule)
        case .applicationLeftovers:
            (items, denied) = try scanLeftovers(rule: rule)
        case .largeFiles:
            items = try LargeFileScanner.scan(root: rule.root,
                                              minimumSize: rule.minimumSize,
                                              excluded: CleanupCatalog.excludedScanDirectories(home: home),
                                              progress: examined)
        case .duplicateFiles:
            items = try DuplicateScanner.scan(roots: CleanupCatalog.duplicateScanRoots(home: home),
                                              minimumSize: rule.minimumSize)
        case .projectArtifacts(let name):
            items = try ProjectArtifactScanner.scan(root: rule.root,
                                                    named: name,
                                                    minimumSize: rule.minimumSize,
                                                    minimumAge: rule.minimumAge,
                                                    excluded: CleanupCatalog.excludedScanDirectories(home: home),
                                                    progress: examined)
        case .advisory(let guidance):
            return try advisoryGroup(rule: rule, guidance: guidance)
        }

        if denied {
            issues.append(CleanupIssue(path: rule.root.path,
                                       reason: "macOS did not grant access to this location."))
        }

        return CleanupGroup(
            id: rule.id,
            title: rule.title,
            explanation: rule.explanation,
            tier: rule.tier,
            removal: rule.removal,
            items: items.sorted { $0.size > $1.size },
            issues: issues,
            requiresFullDiskAccess: denied && rule.needsFullDiskAccess
        )
    }

    /// Reports a size without offering deletion.
    private func advisoryGroup(rule: CleanupRule, guidance: String) throws -> CleanupGroup {
        let measured = FileManager.default.fileExists(atPath: rule.root.path)
            ? try DirectorySizer.measure(rule.root)
            : DirectorySizer.Result()
        return CleanupGroup(
            id: rule.id,
            title: rule.title,
            explanation: rule.explanation,
            tier: rule.tier,
            removal: rule.removal,
            items: [],
            issues: measured.bytes > 0
                ? [CleanupIssue(path: rule.root.path, reason: "Using \(Format.bytes(measured.bytes))")]
                : [],
            requiresFullDiskAccess: false,
            advice: measured.bytes > 0 ? guidance : nil
        )
    }

    // MARK: - Kinds

    private func scanChildren(of root: URL, rule: CleanupRule) throws -> ([CleanupItem], Bool) {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .contentModificationDateKey],
            options: []
        ) else {
            return ([], FileManager.default.fileExists(atPath: root.path))
        }

        var items: [CleanupItem] = []
        for child in children {
            try Task.checkCancellation()
            guard !rule.excludedNames.contains(child.lastPathComponent) else { continue }
            // Symbolic links are skipped outright: their target lives somewhere
            // this rule never authorised.
            if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            guard let item = try measure(child, rule: rule, name: displayName(for: child)) else { continue }
            items.append(item)
        }
        return (items, false)
    }

    private func scanNested(rule: CleanupRule, relativePath: String) throws -> ([CleanupItem], Bool) {
        guard let containers = try? FileManager.default.contentsOfDirectory(
            at: rule.root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []
        ) else {
            return ([], FileManager.default.fileExists(atPath: rule.root.path))
        }

        var items: [CleanupItem] = []
        for container in containers {
            try Task.checkCancellation()
            if (try? container.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            let target = container.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            guard let item = try measure(target, rule: rule,
                                         name: displayName(for: container),
                                         detail: container.lastPathComponent) else { continue }
            items.append(item)
        }
        return (items, false)
    }

    private func scanFiles(rule: CleanupRule) throws -> ([CleanupItem], Bool) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey,
                                         .totalFileAllocatedSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rule.root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }
        ) else {
            return ([], FileManager.default.fileExists(atPath: rule.root.path))
        }

        var items: [CleanupItem] = []
        var counter = 0
        for case let url as URL in enumerator {
            counter += 1
            if counter % 256 == 0 { try Task.checkCancellation() }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let modified = values.contentModificationDate
            guard passesAgeRequirement(modified, rule: rule) else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            guard size >= rule.minimumSize else { continue }
            items.append(CleanupItem(url: url, name: url.lastPathComponent, size: size, modified: modified))
        }
        return (items, false)
    }

    private func scanLeftovers(rule: CleanupRule) throws -> ([CleanupItem], Bool) {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: rule.root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []
        ) else {
            return ([], FileManager.default.fileExists(atPath: rule.root.path))
        }

        var items: [CleanupItem] = []
        for child in children {
            try Task.checkCancellation()
            let identifier = child.lastPathComponent
            guard identifier.looksLikeBundleIdentifier,
                  !inventory.isInstalled(bundleIdentifier: identifier) else { continue }
            if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            guard let item = try measure(child, rule: rule, name: identifier,
                                         detail: "No installed app claims this identifier") else { continue }
            items.append(item)
        }
        return (items, false)
    }

    // MARK: - Helpers

    private func measure(_ url: URL, rule: CleanupRule, name: String, detail: String? = nil) throws -> CleanupItem? {
        let measured = try DirectorySizer.measure(url)
        guard measured.bytes >= max(rule.minimumSize, 1) else { return nil }
        guard passesAgeRequirement(measured.newestModification, rule: rule) else { return nil }
        return CleanupItem(url: url, name: name, detail: detail,
                           size: measured.bytes, modified: measured.newestModification)
    }

    private func passesAgeRequirement(_ modified: Date?, rule: CleanupRule) -> Bool {
        guard let minimumAge = rule.minimumAge else { return true }
        guard let modified else { return false }
        return Date().timeIntervalSince(modified) >= minimumAge
    }

    /// Cache folders are named after bundle identifiers; the last component of
    /// the identifier is a much better label than the whole string.
    private func displayName(for url: URL) -> String {
        let raw = url.lastPathComponent
        guard raw.looksLikeBundleIdentifier, let last = raw.split(separator: ".").last else { return raw }
        return String(last)
    }
}
