import MyMacCore
import SwiftUI

struct ProcessListView: View {
    @Environment(MetricsStore.self) private var store
    @Environment(ProcessActionModel.self) private var actions
    /// Driven by the column headers, which is where anyone on a Mac clicks
    /// first. `Table` reports the order and this view does the sorting, so
    /// `ProcessSorter` stays the only thing that decides what goes where.
    @State private var sortOrder = [KeyPathComparator(\ProcessSample.cpuSortValue, order: .reverse)]
    @State private var search = ""

    private var visible: [ProcessSample] {
        let filtered = search.isEmpty
            ? store.processes
            : store.processes.filter { $0.name.localizedCaseInsensitiveContains(search) }
        let sorting = Self.sorting(for: sortOrder)
        return ProcessSorter.sort(filtered, by: sorting.key, reversed: sorting.reversed)
    }

    /// Maps the table's order onto `ProcessSorter`'s.
    ///
    /// Each key has a natural direction — biggest offender first for CPU and
    /// memory, alphabetical for a name — and `reversed` flips it, so which of
    /// the two the header is asking for depends on the column.
    static func sorting(
        for order: [KeyPathComparator<ProcessSample>]
    ) -> (key: ProcessSortKey, reversed: Bool) {
        guard let first = order.first else { return (.cpu, false) }
        let ascending = first.order == .forward
        switch first.keyPath {
        case \ProcessSample.cpuSortValue: return (.cpu, ascending)
        case \ProcessSample.memorySortValue: return (.memory, ascending)
        case \ProcessSample.name: return (.name, !ascending)
        case \ProcessSample.id: return (.pid, !ascending)
        default: return (.cpu, ascending)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ProcessAttentionBanner()
            table
        }
        .sheet(item: Binding(get: { actions.pending },
                             set: { if $0 == nil { actions.cancel() } })) { pending in
            QuitConfirmationSheet(pending: pending)
        }
        .sheet(isPresented: Binding(get: { actions.message != nil },
                                    set: { if !$0 { actions.dismissMessage() } })) {
            if let message = actions.message {
                QuitOutcomeSheet(message: message, canForce: actions.awaitingForce != nil)
            }
        }
    }

    private var table: some View {
        Table(visible, sortOrder: $sortOrder) {
            TableColumn("Process", value: \.name) { process in
                HStack(spacing: 6) {
                    Text(process.name).lineLimit(1)
                    if process.kind == .system {
                        Text("system")
                            .font(.note)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            // Numbers are right-aligned so their digits line up down the
            // column; a PID is an identifier, so it carries no separators.
            TableColumn("PID", value: \.id) { process in
                Text(verbatim: "\(process.pid)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(62)
            TableColumn("CPU", value: \.cpuSortValue) { process in
                Text(process.cpuUsage.map(Format.processCPU) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(process.cpuUsage == nil ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(66)
            TableColumn("Memory", value: \.memorySortValue) { process in
                Text(process.memoryFootprint.map(Format.bytes) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(process.memoryFootprint == nil ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(92)
            TableColumn("Type") { process in
                Text(process.kind.rawValue).foregroundStyle(.secondary)
            }
            .width(90)
            TableColumn("") { process in
                QuitButton(name: process.name) { actions.confirm(process) }
            }
            .width(34)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter processes")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(visible.count) processes")
                Spacer()
                // Stated plainly rather than hidden: the numbers are incomplete
                // and the user deserves to know why.
                if store.processes.contains(where: { $0.cpuUsage == nil }) {
                    Text("Processes owned by other users report no statistics without elevated privileges.")
                }
            }
            .font(.note)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle("Processes")
        .metricsScope(.processes, store: store)
    }
}

/// Per-row quit action. Quiet until the pointer is over it, and red then —
/// ending a process is not something to invite with a permanently bright button.
private struct QuitButton: View {
    let name: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle")
                .imageScale(.medium)
                .foregroundStyle(isHovering ? Color.red : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Quit \(name)…")
        .accessibilityLabel("Quit \(name)")
    }
}
