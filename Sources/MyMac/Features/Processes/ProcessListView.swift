import MyMacCore
import SwiftUI

struct ProcessListView: View {
    @Environment(MetricsStore.self) private var store
    @Environment(ProcessActionModel.self) private var actions
    @State private var sortKey: ProcessSortKey = .cpu
    @State private var reversed = false
    @State private var search = ""

    private var visible: [ProcessSample] {
        let filtered = search.isEmpty
            ? store.processes
            : store.processes.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return ProcessSorter.sort(filtered, by: sortKey, reversed: reversed)
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
        Table(visible) {
            TableColumn("Process") { process in
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
            TableColumn("PID") { process in
                Text(verbatim: "\(process.pid)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(62)
            TableColumn("CPU") { process in
                Text(process.cpuUsage.map(Format.processCPU) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(process.cpuUsage == nil ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(66)
            TableColumn("Memory") { process in
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
        .toolbar {
            ToolbarItem {
                Picker("Sort by", selection: $sortKey) {
                    ForEach(ProcessSortKey.allCases) { key in
                        Text(key.label).tag(key)
                    }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button {
                    reversed.toggle()
                } label: {
                    Label("Reverse", systemImage: reversed ? "arrow.up" : "arrow.down")
                }
                .help("Reverse the sort order")
            }
        }
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
