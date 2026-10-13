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
        var canRetryAsAdministrator = false
        /// The bundle that could not be removed, for "Show in Finder".
        var revealPath: String?
    }

    private(set) var items: [InstalledItem] = []
    private(set) var isLoading = false
    private(set) var isSizing = false
    private(set) var summary: Summary?
    private var retry: (item: InstalledItem, leftovers: [CleanupItem])?

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

    /// The column a click on a header asks for. `origin` is the second column,
    /// which shows a location for an application and a manager for a package.
    enum Order {
        case name
        case origin
        case size
    }

    var scope: Scope = .applications
    /// Driven by the column headers, which is where anyone on a Mac clicks
    /// first. `Table` reports the order and the model does the sorting, so
    /// `visibleItems` stays the only thing that decides what goes where.
    ///
    /// Alphabetical by default: it is the order that stays put while sizes are
    /// still being measured, and the one you can navigate by eye.
    var sortOrder = [KeyPathComparator(\InstalledItem.name, order: .forward)]
    var search = ""
    var sourceFilter: String?

    /// Maps the table's order onto the columns this list knows how to sort by.
    static func sorting(
        for order: [KeyPathComparator<InstalledItem>]
    ) -> (key: Order, ascending: Bool) {
        guard let first = order.first else { return (.name, true) }
        let ascending = first.order == .forward
        switch first.keyPath {
        case \InstalledItem.origin: return (.origin, ascending)
        case \InstalledItem.sizeSortValue: return (.size, ascending)
        default: return (.name, ascending)
        }
    }

    /// The item awaiting confirmation, with everything that would be removed.
    private(set) var pending: InstalledItem?
    private(set) var leftovers: [CleanupItem] = []
    var selectedLeftovers: Set<String> = []
    private(set) var isPreparing = false
    private(set) var isRemoving = false
    /// Worked out once when the sheet opens. Both read the disk — resolving an
    /// executable, reading a pip's shebang — and the sheet's body runs again on
    /// every toggle and every size that lands.
    private(set) var pendingCommand: String?
    private(set) var pendingRefusal: String?

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var work: Task<Void, Never>?
    /// Which measuring run owns `isSizing`. A cancelled run can be parked
    /// inside a single long `measure` call and only notice afterwards, so
    /// without this it clears the flag its replacement has already set — and
    /// the size column starts re-sorting under the pointer mid-measurement.
    private var sizingGeneration = 0

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
        let sorting = Self.sorting(for: sortOrder)
        return items
            .filter { matches(scope, $0) }
            .filter { scope == .applications || sourceFilter == nil || $0.source.title == sourceFilter }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { isOrdered($0, before: $1, by: sorting) }
    }

    /// A total order, so no row's position depends on which two rows happened
    /// to be compared: every column falls back to the name, and the name is
    /// unique enough to settle it.
    private func isOrdered(
        _ lhs: InstalledItem,
        before rhs: InstalledItem,
        by sorting: (key: Order, ascending: Bool)
    ) -> Bool {
        func byName(_ ascending: Bool = true) -> Bool {
            let result = lhs.name.localizedStandardCompare(rhs.name)
            guard result != .orderedSame else { return lhs.id < rhs.id }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }

        switch sorting.key {
        case .name:
            return byName(sorting.ascending)
        case .origin:
            let result = lhs.origin.localizedStandardCompare(rhs.origin)
            guard result != .orderedSame else { return byName() }
            return sorting.ascending ? result == .orderedAscending : result == .orderedDescending
        case .size:
            // Sorting by size waits until every size is in. Re-sorting as each
            // measurement lands would move rows out from under the pointer, and
            // every row here has a destructive button.
            guard !isSizing else { return byName() }
            // An item nobody could measure has no place in a size order, so it
            // goes last whichever way the column points.
            guard let left = lhs.size else { return rhs.size == nil ? byName() : false }
            guard let right = rhs.size else { return true }
            guard left != right else { return byName() }
            return sorting.ascending ? left < right : left > right
        }
    }

    var selectedLeftoverBytes: Int64 {
        leftovers.filter { selectedLeftovers.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    /// Read back from the list, not from the snapshot the sheet opened on:
    /// sizes land after the list does, and a sheet opened before its row was
    /// measured would otherwise offer to remove a gigabyte and call it zero.
    var pendingTotalBytes: Int64 { (currentPending?.size ?? 0) + selectedLeftoverBytes }

    /// The pending item with whatever the list knows about it now.
    private var currentPending: InstalledItem? {
        guard let pending else { return nil }
        return items.first { $0.id == pending.id } ?? pending
    }

    /// The exact command that will run, with the executable resolved on this
    /// machine: a package's own manager, or `brew uninstall --cask` for an
    /// application a cask installed. `nil` for any other application, which
    /// runs nothing, and for a manager whose tool is not installed where this
    /// app looks for it.
    func uninstallCommand(for item: InstalledItem) -> String? {
        if let cask = item.cask {
            return PackageEcosystem.homebrewCask
                .resolvedUninstallCommand(for: cask.token, home: home, near: cask.record)
        }
        guard case .package(let ecosystem) = item.source else { return nil }
        return ecosystem.resolvedUninstallCommand(for: item.name, home: home, near: item.location)
    }

    /// Why the manager will certainly refuse this package, known before
    /// anything runs. The sheet shows this instead of a command.
    func uninstallRefusal(for item: InstalledItem) -> String? {
        guard case .package(let ecosystem) = item.source else { return nil }
        return ecosystem.refusal(home: home, near: item.location)
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
        AppIconCache.forget()
        let home = home

        sizingGeneration += 1
        let generation = sizingGeneration

        work = Task(priority: .utility) {
            let applications = ApplicationCatalog.scan(home: home)
            let packages = PackageCatalog.scan(home: home)
            await MainActor.run {
                self.items = applications + packages
                self.isLoading = false
            }
            await self.measureSizes(generation: generation)
        }
    }

    /// Sizes arrive after the list does. Walking forty application bundles takes
    /// seconds, and there is no reason to make the user stare at a spinner for
    /// them when the names are already known.
    private func measureSizes(generation: Int) async {
        await MainActor.run { self.isSizing = true }
        let snapshot = await MainActor.run { self.items }
        var measured: [String: Int64] = [:]

        for (index, item) in snapshot.enumerated() {
            if Task.isCancelled { break }
            // Left unset when there is nothing to measure, so the row keeps
            // showing "…" rather than claiming a size of zero.
            if let size = UninstallService.measure(item) { measured[item.id] = size }
            // Publish in batches so the list is not rebuilt once per bundle.
            if index % 8 == 7 || index == snapshot.count - 1 {
                let batch = measured
                await MainActor.run { self.apply(sizes: batch) }
                await Task.yield()
            }
        }
        await MainActor.run {
            guard self.sizingGeneration == generation else { return }
            self.isSizing = false
        }
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
        pendingCommand = uninstallCommand(for: item)
        pendingRefusal = uninstallRefusal(for: item)
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
        pendingCommand = nil
        pendingRefusal = nil
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
        guard let item = currentPending, !isRemoving else { return }
        run(item, leftovers: leftovers.filter { selectedLeftovers.contains($0.id) },
            asAdministrator: false)
    }

    /// Runs the removal again with Finder doing the trashing, after the first
    /// attempt reported a bundle only an administrator can move.
    func retryAsAdministrator() {
        guard let retry, !isRemoving else { return }
        run(retry.item, leftovers: retry.leftovers, asAdministrator: true)
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func run(_ item: InstalledItem, leftovers chosen: [CleanupItem], asAdministrator: Bool) {
        isRemoving = true
        summary = nil
        retry = nil
        let service = UninstallService(home: home, administratorTrasher: { try FinderTrash.trash($0) })

        Task(priority: .userInitiated) {
            let outcome = await service.uninstall(item, leftovers: chosen, asAdministrator: asAdministrator)
            await MainActor.run {
                if outcome.needsAdministrator { self.retry = (item, chosen) }
                self.isRemoving = false
                self.pending = nil
                self.leftovers = []
                self.pendingCommand = nil
                self.pendingRefusal = nil
                self.summary = Summary(
                    name: item.name,
                    trashed: outcome.trashedCount,
                    reclaimed: outcome.reclaimedBytes,
                    toolOutput: outcome.toolOutput?.isEmpty == false ? outcome.toolOutput : nil,
                    failures: outcome.failures.map { "\($0.path): \($0.reason)" },
                    canRetryAsAdministrator: outcome.needsAdministrator,
                    revealPath: outcome.removedTheItemItself ? nil : item.location.path
                )
                // Keyed on the item's own fate: a support file that could not
                // be trashed does not put the application back, and leaving the
                // row behind invites a second uninstall of something gone.
                if outcome.removedTheItemItself { self.forget(item) }
            }
        }
    }

    /// Drops a removed item's row, and the other row of a cask with it: the
    /// bundle under Applications and the record under Others are one install,
    /// and whichever tab removed it, both are gone.
    func forget(_ item: InstalledItem) {
        let record = item.cask?.record.standardizedFileURL
        items.removeAll { candidate in
            candidate.id == item.id
                || (record != nil && candidate.cask?.record.standardizedFileURL == record)
        }
    }

    func dismissSummary() {
        summary = nil
        retry = nil
    }

    /// Exposed so the ordering can be tested against a fixture rather than
    /// whatever software happens to be installed on the machine.
    func replaceItemsForTesting(_ items: [InstalledItem]) {
        self.items = items
    }
}
