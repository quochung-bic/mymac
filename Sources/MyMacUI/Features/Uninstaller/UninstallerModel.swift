import AppKit
import MyMacCore
import Observation
import SwiftUI

@MainActor
@Observable
final class UninstallerModel {
    struct Summary: Equatable {
        var name: String
        var trashed: Int
        var reclaimed: Int64
        var toolOutput: String?
        var failures: [String]
    }

    private(set) var items: [InstalledItem] = []
    private(set) var isLoading = false
    private(set) var isSizing = false
    private(set) var summary: Summary?

    /// Applications and package-manager installs are different enough to
    /// deserve separate lists: one is a bundle you drag to the Trash with its
    /// support files, the other is an entry in a tool's own registry.
    enum Scope: String, CaseIterable, Identifiable {
        case applications
        case packages

        var id: String { rawValue }
        var title: String {
            switch self {
            case .applications: "Applications"
            case .packages: "Others"
            }
        }
    }

    enum Order: String, CaseIterable, Identifiable {
        case name
        case size

        var id: String { rawValue }
        var title: String {
            switch self {
            case .name: "Name"
            case .size: "Size"
            }
        }
    }

    var scope: Scope = .applications
    /// Alphabetical by default: it is the order that stays put while sizes are
    /// still being measured, and the one you can navigate by eye.
    var order: Order = .name
    var search = ""
    var sourceFilter: String?

    /// The item awaiting confirmation, with everything that would be removed.
    private(set) var pending: InstalledItem?
    private(set) var leftovers: [CleanupItem] = []
    var selectedLeftovers: Set<String> = []
    private(set) var isPreparing = false
    private(set) var isRemoving = false

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var work: Task<Void, Never>?

    /// Ecosystems present, for the filter shown alongside the package list.
    var sources: [String] {
        Array(Set(items.filter { $0.source != .application }.map(\.source.title))).sorted()
    }

    func count(in scope: Scope) -> Int {
        items.filter { matches(scope, $0) }.count
    }

    private func matches(_ scope: Scope, _ item: InstalledItem) -> Bool {
        switch scope {
        case .applications: item.source == .application
        case .packages: item.source != .application
        }
    }

    var visibleItems: [InstalledItem] {
        items
            .filter { matches(scope, $0) }
            .filter { scope == .applications || sourceFilter == nil || $0.source.title == sourceFilter }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            // Sorting by size waits until every size is in. Re-sorting as each
            // measurement lands would move rows out from under the pointer, and
            // every row here has a destructive button.
            .sorted { lhs, rhs in
                guard order == .size, !isSizing,
                      let left = lhs.size, let right = rhs.size, left != right else {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return left > right
            }
    }

    var selectedLeftoverBytes: Int64 {
        leftovers.filter { selectedLeftovers.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    var pendingTotalBytes: Int64 { (pending?.size ?? 0) + selectedLeftoverBytes }

    /// The exact command that will run for a package, with the executable
    /// resolved on this machine. `nil` for applications, which run nothing, and
    /// for a manager whose tool is not installed where this app looks for it.
    func uninstallCommand(for item: InstalledItem) -> String? {
        guard case .package(let ecosystem) = item.source else { return nil }
        return ecosystem.resolvedUninstallCommand(for: item.name, home: home, near: item.location)
    }

    /// Uninstalling an app while it is running leaves half of it in memory and
    /// its state written back out afterwards.
    func isRunning(_ item: InstalledItem) -> Bool {
        guard let bundleIdentifier = item.bundleIdentifier else { return false }
        return NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == bundleIdentifier }
    }

    // MARK: - Loading

    /// - Parameter force: re-read the disk even though a list is already held.
    ///   Without this the list was rebuilt on every visit to the tab, which
    ///   means walking /Applications and measuring every bundle again — seconds
    ///   of disk work to arrive at the same answer.
    func load(force: Bool = false) {
        guard !isLoading else { return }
        guard force || items.isEmpty else { return }
        isLoading = true
        work?.cancel()
        let home = home

        work = Task(priority: .utility) {
            let applications = ApplicationCatalog.scan(home: home)
            let packages = PackageCatalog.scan(home: home)
            await MainActor.run {
                self.items = applications + packages
                self.isLoading = false
            }
            await self.measureSizes()
        }
    }

    /// Sizes arrive after the list does. Walking forty application bundles takes
    /// seconds, and there is no reason to make the user stare at a spinner for
    /// them when the names are already known.
    private func measureSizes() async {
        await MainActor.run { self.isSizing = true }
        let snapshot = await MainActor.run { self.items }
        var measured: [String: Int64] = [:]

        for (index, item) in snapshot.enumerated() {
            if Task.isCancelled { break }
            measured[item.id] = UninstallService.measure(item)
            // Publish in batches so the list is not rebuilt once per bundle.
            if index % 8 == 7 || index == snapshot.count - 1 {
                let batch = measured
                await MainActor.run { self.apply(sizes: batch) }
                await Task.yield()
            }
        }
        await MainActor.run { self.isSizing = false }
    }

    private func apply(sizes: [String: Int64]) {
        for index in items.indices {
            if let size = sizes[items[index].id] { items[index].size = size }
        }
    }

    // MARK: - Confirmation

    func prepare(_ item: InstalledItem) {
        pending = item
        leftovers = []
        selectedLeftovers = []
        guard item.source == .application else { return }

        isPreparing = true
        let home = home
        Task(priority: .userInitiated) {
            let found = (try? LeftoverScanner.scan(for: item, home: home)) ?? []
            await MainActor.run {
                guard self.pending?.id == item.id else { return }
                self.leftovers = found
                // Pre-selected here, unlike the cleaner: the user asked to
                // uninstall this app, and its own support files are what
                // "uninstall" means. Everything still goes to the Trash.
                self.selectedLeftovers = Set(found.map(\.id))
                self.isPreparing = false
            }
        }
    }

    func cancelPending() {
        pending = nil
        leftovers = []
        selectedLeftovers = []
    }

    func toggle(_ leftover: CleanupItem) {
        if selectedLeftovers.contains(leftover.id) {
            selectedLeftovers.remove(leftover.id)
        } else {
            selectedLeftovers.insert(leftover.id)
        }
    }

    // MARK: - Removal

    func confirm() {
        guard let item = pending, !isRemoving else { return }
        isRemoving = true
        let chosen = leftovers.filter { selectedLeftovers.contains($0.id) }
        let service = UninstallService(home: home)

        Task(priority: .userInitiated) {
            let outcome = await service.uninstall(item, leftovers: chosen)
            await MainActor.run {
                self.isRemoving = false
                self.pending = nil
                self.leftovers = []
                self.summary = Summary(
                    name: item.name,
                    trashed: outcome.trashedCount,
                    reclaimed: outcome.reclaimedBytes,
                    toolOutput: outcome.toolOutput?.isEmpty == false ? outcome.toolOutput : nil,
                    failures: outcome.failures.map { "\($0.path): \($0.reason)" }
                )
                if outcome.succeeded { self.items.removeAll { $0.id == item.id } }
            }
        }
    }

    func dismissSummary() { summary = nil }
}
