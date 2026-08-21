import AppKit
import MyMacCore
import Observation
import SwiftUI

/// Launch Services' view of what is installed, used to spot leftovers.
struct WorkspaceApplicationInventory: ApplicationInventory {
    func isInstalled(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }
}

@MainActor
@Observable
final class CleanerModel {
    enum Phase: Equatable {
        case idle
        case scanning(ScanProgressSnapshot)
        case reviewing
        case cleaning(fraction: Double, label: String)
        case finished(CleanupSummary)
    }

    struct ScanProgressSnapshot: Equatable {
        var fraction: Double
        var title: String
        var bytesFound: Int64
        var examinedFiles: Int = 0
    }

    struct CleanupSummary: Equatable {
        var removed: Int
        var trashed: Int
        var reclaimed: Int64
        var failures: [String]
        var rejected: Int
    }

    private(set) var phase: Phase = .idle
    private(set) var groups: [CleanupGroup] = []
    /// Never pre-populated. The user selects; the app does not decide for them.
    var selection: Set<String> = []
    var includeDeepScans = false

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var rulesByID: [String: CleanupRule] = [:]
    private var work: Task<Void, Never>?

    var isBusy: Bool {
        switch phase {
        case .scanning, .cleaning: true
        default: false
        }
    }

    var selectedBytes: Int64 {
        groups.reduce(0) { total, group in
            total + group.items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size }
        }
    }

    var selectedCount: Int {
        groups.reduce(0) { $0 + $1.items.filter { selection.contains($0.id) }.count }
    }

    var totalFound: Int64 { groups.reduce(0) { $0 + $1.totalSize } }

    func groups(in tier: CleanupTier) -> [CleanupGroup] {
        groups.filter { group in
            guard group.tier == tier else { return false }
            // Advisory groups carry no items by design, and a group blocked by
            // permissions has none either — both still need to be shown.
            return !group.items.isEmpty || group.requiresFullDiskAccess || group.isAdvisory
        }
    }

    // MARK: - Scanning

    func scan() {
        work?.cancel()
        selection.removeAll()
        groups = []
        phase = .scanning(.init(fraction: 0, title: "Starting…", bytesFound: 0))

        let rules = CleanupCatalog.rules(home: home)
            .filter { includeDeepScans || !$0.isDeepScan }
        rulesByID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })

        let scanner = CleanupScanner(home: home, inventory: WorkspaceApplicationInventory())
        work = Task(priority: .utility) {
            do {
                let results = try await scanner.scan(rules: rules) { progress in
                    Task { @MainActor in
                        self.phase = .scanning(.init(fraction: progress.fraction,
                                                     title: progress.currentTitle,
                                                     bytesFound: progress.bytesFound,
                                                     examinedFiles: progress.examinedFiles))
                    }
                }
                await MainActor.run {
                    self.groups = results
                    self.phase = .reviewing
                }
            } catch is CancellationError {
                await MainActor.run { self.phase = .idle }
            } catch {
                Log.cleaner.error("scan failed: \(error.localizedDescription)")
                await MainActor.run { self.phase = .idle }
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        phase = groups.isEmpty ? .idle : .reviewing
    }

    // MARK: - Selection

    func isSelected(_ item: CleanupItem) -> Bool { selection.contains(item.id) }

    func toggle(_ item: CleanupItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func selectionState(for group: CleanupGroup) -> Bool? {
        let selected = group.items.filter { selection.contains($0.id) }.count
        if selected == 0 { return false }
        if selected == group.items.count { return true }
        return nil
    }

    func setSelection(_ selected: Bool, for group: CleanupGroup) {
        for item in group.items {
            if selected { selection.insert(item.id) } else { selection.remove(item.id) }
        }
    }

    /// Only ever offered for the "safe to clean" tier, and only when the user
    /// asks for it explicitly.
    func selectAllSafe() {
        for group in groups where group.tier == .safe {
            setSelection(true, for: group)
        }
    }

    func deselectAll() { selection.removeAll() }

    // MARK: - Cleaning

    func clean() {
        let requests: [CleanupEngine.Request] = groups.compactMap { group in
            let items = group.items.filter { selection.contains($0.id) }
            guard !items.isEmpty, let rule = rulesByID[group.id] else { return nil }
            // The allowlist comes from the rule, never from the scan result.
            var suffix: String?
            if case .nestedDirectories(let relativePath) = rule.kind { suffix = relativePath }
            return CleanupEngine.Request(items: items, removal: group.removal,
                                         allowedRoots: [rule.root], requiredSuffix: suffix)
        }
        guard !requests.isEmpty else { return }

        phase = .cleaning(fraction: 0, label: "")
        let engine = CleanupEngine(home: home)
        work = Task(priority: .userInitiated) {
            let outcome = await engine.perform(requests) { fraction, label in
                Task { @MainActor in
                    self.phase = .cleaning(fraction: fraction, label: label)
                }
            }
            await MainActor.run {
                self.phase = .finished(CleanupSummary(
                    removed: outcome.removedCount,
                    trashed: outcome.trashedCount,
                    reclaimed: outcome.reclaimedBytes,
                    failures: outcome.failures.map { "\($0.path): \($0.reason)" },
                    rejected: outcome.rejectedCount
                ))
                self.selection.removeAll()
                self.groups = []
            }
        }
    }

    func reset() {
        phase = .idle
        groups = []
        selection.removeAll()
    }
}
