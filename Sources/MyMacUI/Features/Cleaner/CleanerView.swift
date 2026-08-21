import MyMacCore
import SwiftUI

/// Scan → review → select → confirm → clean → report.
///
/// There is no path through this screen that deletes anything the user did not
/// tick, and the confirmation always states the exact count and size.
struct CleanerView: View {
    @Environment(CleanerModel.self) private var model
    @State private var expanded: Set<String> = []
    @State private var confirming = false

    var body: some View {
        @Bindable var model = model

        Group {
            switch model.phase {
            case .idle:
                IntroView(includeDeepScans: $model.includeDeepScans) { model.scan() }
            case .scanning(let progress):
                ScanningView(progress: progress) { model.cancel() }
            case .reviewing:
                reviewList
            case .cleaning(let fraction, let label):
                CleaningView(fraction: fraction, label: label)
            case .finished(let summary):
                SummaryView(summary: summary) { model.reset() }
            }
        }
        .navigationTitle("Cleaner")
        .confirmationDialog(
            "Clean \(model.selectedCount) item\(model.selectedCount == 1 ? "" : "s")?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Clean \(Format.bytes(model.selectedBytes))", role: .destructive) { model.clean() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items in Safe to Clean are deleted permanently. Everything in Review Before Cleaning is moved to the Trash so you can put it back.")
        }
    }

    private var reviewList: some View {
        VStack(spacing: 0) {
            List {
                ForEach(CleanupTier.allCases) { tier in
                    let tierGroups = model.groups(in: tier)
                    if !tierGroups.isEmpty {
                        Section {
                            ForEach(tierGroups) { group in
                                GroupRow(group: group, isExpanded: expanded.contains(group.id)) {
                                    if expanded.contains(group.id) {
                                        expanded.remove(group.id)
                                    } else {
                                        expanded.insert(group.id)
                                    }
                                }
                                if expanded.contains(group.id) {
                                    ForEach(group.items) { item in
                                        ItemRow(item: item, group: group)
                                    }
                                }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tier.title).font(.headline)
                                Text(tier.subtitle).font(.note).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if model.groups.allSatisfy({ $0.items.isEmpty }) {
                    ContentUnavailableView("Nothing to clean",
                                           systemImage: "checkmark.circle",
                                           description: Text("No reclaimable files were found in the locations this app is allowed to look at."))
                }
            }
            .listStyle(.inset)

            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Found \(Format.bytes(model.totalFound))")
                    .font(.callout)
                Text(model.selectedCount == 0
                     ? "Nothing selected"
                     : "\(model.selectedCount) selected · \(Format.bytes(model.selectedBytes))")
                    .font(.note)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button("Select All Safe") { model.selectAllSafe() }
            Button("Clear") { model.deselectAll() }
                .disabled(model.selectedCount == 0)
            Button("Rescan") { model.scan() }
            Button("Clean…") { confirming = true }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedCount == 0)
        }
        .padding(12)
        .background(.bar)
    }
}

private struct GroupRow: View {
    @Environment(CleanerModel.self) private var model
    let group: CleanupGroup
    let isExpanded: Bool
    let toggleExpansion: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if group.isAdvisory {
                    Image(systemName: "info.circle")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle(isOn: Binding(
                        get: { model.selectionState(for: group) ?? false },
                        set: { model.setSelection($0, for: group) }
                    )) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .disabled(group.items.isEmpty)
                }

                Button(action: toggleExpansion) {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.note)
                            .foregroundStyle(.secondary)
                        Text(group.title)
                        if group.removal == .trash, !group.isAdvisory {
                            Text("to Trash")
                                .font(.note)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(group.items.isEmpty)

                Spacer()
                Text(group.isAdvisory ? (group.issues.first?.reason ?? "—") : Format.bytes(group.totalSize))
                    .monospacedDigit()
                    .foregroundStyle(group.items.isEmpty ? .secondary : .primary)
            }

            Text(group.explanation)
                .font(.note)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let advice = group.advice {
                Text(advice)
                    .font(.note)
                    .foregroundStyle(.orange)
            }

            if group.requiresFullDiskAccess {
                Label("Needs Full Disk Access to read this location.", systemImage: "lock")
                    .font(.note)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ItemRow: View {
    @Environment(CleanerModel.self) private var model
    let item: CleanupItem
    let group: CleanupGroup

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { model.isSelected(item) },
                set: { _ in model.toggle(item) }
            )) { EmptyView() }
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                // The exact path is always visible: the user can verify every
                // claim this app makes before agreeing to it.
                Text(item.detail ?? item.url.path)
                    .font(.note)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.bytes(item.size)).monospacedDigit()
                Text(Format.relativeAge(item.modified))
                    .font(.note)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 22)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }
}

private struct IntroView: View {
    @Binding var includeDeepScans: Bool
    let start: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Find reclaimable space")
                .font(.title2.weight(.medium))
            Text("""
            This scan only reads. It looks in a fixed list of locations — caches, logs, \
            crash reports, developer build products, the Trash — and reports what it finds \
            with the exact path of every item. Nothing is deleted until you select it and \
            confirm.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)

            Toggle("Also scan for large and duplicate files", isOn: $includeDeepScans)
                .help("Walks your home folder. Slower, and only worth running when you are looking for something specific.")

            Button("Scan", action: start)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScanningView: View {
    let progress: CleanerModel.ScanProgressSnapshot
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ProgressView(value: progress.fraction)
                .frame(maxWidth: 320)
            Text(progress.title).font(.callout)
            Text(progress.examinedFiles > 0
                 ? "\(Format.bytes(progress.bytesFound)) found · \(Format.count(progress.examinedFiles)) files examined"
                 : "\(Format.bytes(progress.bytesFound)) found so far")
                .font(.note)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Cancel", action: cancel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CleaningView: View {
    let fraction: Double
    let label: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView(value: fraction)
                .frame(maxWidth: 320)
            Text(label.isEmpty ? "Cleaning…" : label)
                .font(.callout)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SummaryView: View {
    let summary: CleanerModel.CleanupSummary
    let done: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: summary.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(summary.failures.isEmpty ? Color.secondary : Color.orange)
            Text("Reclaimed \(Format.bytes(summary.reclaimed))")
                .font(.title2.weight(.medium))
            Text("\(summary.removed) deleted · \(summary.trashed) moved to Trash")
                .font(.callout)
                .foregroundStyle(.secondary)

            if summary.rejected > 0 {
                Text("\(summary.rejected) item\(summary.rejected == 1 ? "" : "s") were skipped by the safety check.")
                    .font(.note)
                    .foregroundStyle(.orange)
            }

            if !summary.failures.isEmpty {
                DisclosureGroup("\(summary.failures.count) could not be removed") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(summary.failures, id: \.self) { failure in
                                Text(failure)
                                    .font(.note)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .frame(maxWidth: 460)
            }

            Button("Done", action: done)
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
