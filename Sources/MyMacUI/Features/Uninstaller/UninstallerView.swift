import MyMacCore
import SwiftUI

/// Removes an application or a globally installed package, and shows exactly
/// what will go before anything does.
struct UninstallerView: View {
    @Environment(UninstallerModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            if model.isLoading {
                ProgressView("Reading installed software…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker("", selection: $model.scope) {
                    ForEach(UninstallerModel.Scope.allCases) { scope in
                        Text("\(scope.title) (\(model.count(in: scope)))").tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)

                Table(model.visibleItems, sortOrder: $model.sortOrder) {
                    TableColumn("Name", value: \.name) { item in
                        HStack(spacing: 7) {
                            Image(systemName: item.source.symbol)
                                .imageScale(.small)
                                .foregroundStyle(.secondary)
                            Text(item.name).lineLimit(1)
                            if let version = item.version {
                                Text(version)
                                    .font(.note)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    TableColumn(model.scope == .applications ? "Location" : "Manager",
                                value: \.origin) { item in
                        Text(item.origin)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .width(150)
                    TableColumn("Size", value: \.sizeSortValue) { item in
                        Text(item.size.map(Format.bytes) ?? "…")
                            .monospacedDigit()
                            .foregroundStyle(item.size == nil ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(80)
                    TableColumn("") { item in
                        UninstallButton(name: item.name) { model.prepare(item) }
                    }
                    .width(34)
                }
                .searchable(text: $model.search, placement: .toolbar, prompt: "Filter by name")
            }

            footer
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.load(force: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Read installed software again")
                .disabled(model.isLoading)
            }
            // Only meaningful for packages; applications have one source.
            if model.scope == .packages {
                ToolbarItem {
                    Picker("Manager", selection: $model.sourceFilter) {
                        Text("All").tag(String?.none)
                        ForEach(model.sources, id: \.self) { source in
                            Text(source).tag(String?.some(source))
                        }
                    }
                }
            }
        }
        .navigationTitle("Uninstaller")
        .task { model.load() }
        // Real bindings, not `.constant`: a constant cannot carry a dismissal
        // back, so Escape or a click outside would close the sheet while the
        // model still believed it was open.
        .sheet(item: Binding(get: { model.pending },
                             set: { if $0 == nil { model.cancelPending() } })) { item in
            ConfirmSheet(item: item)
        }
        .sheet(isPresented: Binding(get: { model.summary != nil },
                                    set: { if !$0 { model.dismissSummary() } })) {
            if let summary = model.summary { SummarySheet(summary: summary) }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(model.visibleItems.count) items")
            if model.isSizing {
                ProgressView().controlSize(.small)
                Text("measuring sizes…")
            }
            Spacer()
            Text(model.scope == .applications
                 ? "The bundle and its support files go to the Trash."
                 : "Each package is removed by the manager that installed it.")
        }
        .font(.note)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct ConfirmSheet: View {
    @Environment(UninstallerModel.self) private var model
    let item: InstalledItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Uninstall \(item.name)?")
                    .font(.headline)
                Text(item.location.path)
                    .font(.note)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if model.isRunning(item) {
                Label("\(item.name) is running. Quit it first, or its state will be written back after removal.",
                      systemImage: "exclamationmark.triangle")
                    .font(.note)
                    .foregroundStyle(.orange)
            }

            switch item.source {
            case .application:
                applicationDetail
            case .package(let ecosystem):
                packageDetail(ecosystem)
            }

            Divider()

            HStack {
                Text("Removing \(Format.bytes(model.pendingTotalBytes))")
                    .font(.note)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Cancel") { model.cancelPending() }
                    .keyboardShortcut(.cancelAction)
                Button("Uninstall") { model.confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isRemoving || !canUninstall)
            }
        }
        .padding(16)
        .frame(width: 480)
    }

    private var applicationDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Moving to the Trash")
                .font(.sectionLabel)
                .foregroundStyle(.secondary)

            if model.isPreparing {
                ProgressView().controlSize(.small)
            } else if model.leftovers.isEmpty {
                Text("The application bundle only — it left no support files behind.")
                    .font(.note)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.leftovers) { leftover in
                            Toggle(isOn: Binding(
                                get: { model.selectedLeftovers.contains(leftover.id) },
                                set: { _ in model.toggle(leftover) }
                            )) {
                                HStack(spacing: 6) {
                                    Text(leftover.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Text(Format.bytes(leftover.size))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                .font(.note)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxHeight: 170)
            }

            // Chrome, for one, keeps its profile in ~/Library/Application
            // Support/Google — a folder shared with every other Google app.
            // Attributing a vendor folder to one app would be a guess, and the
            // user deserves to know the list is keyed on the bundle identifier
            // rather than to assume it is exhaustive.
            Text("Only files keyed to this app's identifier are listed. Some apps also store data in a folder shared with the vendor's other apps, which is not attributed to any single app.")
                .font(.note)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func packageDetail(_ ecosystem: PackageEcosystem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.uninstallCommand(for: item) == nil ? "Cannot Run" : "Running")
                .font(.sectionLabel)
                .foregroundStyle(.secondary)

            // The exact command, verbatim, with the executable resolved. A
            // package manager's own uninstall is the only way to keep its
            // bookkeeping consistent, and the user is entitled to see precisely
            // what will run — which means the real program and its real path,
            // not the name this app happens to file the manager under.
            if let command = model.uninstallCommand(for: item) {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .quaternaryLabelColor)))
            } else {
                Label("\(ecosystem.title) is not installed anywhere this app looks, so it cannot remove this package. Removing the files by hand would leave \(ecosystem.title)'s own records inconsistent.",
                      systemImage: "exclamationmark.triangle")
                    .font(.note)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// An application can always be moved to the Trash. A package can only be
    /// removed by the manager that installed it, so with the tool missing there
    /// is nothing to confirm.
    private var canUninstall: Bool {
        item.source == .application || model.uninstallCommand(for: item) != nil
    }
}

private struct SummarySheet: View {
    @Environment(UninstallerModel.self) private var model
    let summary: UninstallerModel.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(summary.failures.isEmpty ? "Removed \(summary.name)" : "Could not finish",
                  systemImage: summary.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(summary.failures.isEmpty ? Color.primary : Color.orange)

            if summary.failures.isEmpty {
                Text("\(summary.trashed) item\(summary.trashed == 1 ? "" : "s") · \(Format.bytes(summary.reclaimed))")
                    .font(.note)
                    .foregroundStyle(.secondary)
            }

            if let output = summary.toolOutput {
                outputBox(output)
            }
            ForEach(summary.failures, id: \.self) { failure in
                Text(failure)
                    .font(.note)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Done") { model.dismissSummary() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func outputBox(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140)
    }
}

/// The per-row action.
///
/// A blue "Uninstall…" link repeated down a hundred rows shouts, and the colour
/// says "link" rather than "this removes something". A quiet icon that turns red
/// under the pointer reads as an action and keeps the table calm — the row's
/// subject is its name, not its button.
private struct UninstallButton: View {
    let name: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .imageScale(.medium)
                .foregroundStyle(isHovering ? Color.red : Color.secondary)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Uninstall \(name)…")
        .accessibilityLabel("Uninstall \(name)")
    }
}
