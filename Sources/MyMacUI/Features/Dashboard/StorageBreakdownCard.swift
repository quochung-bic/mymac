import MyMacCore
import Observation
import SwiftUI

/// Drives the on-demand storage analysis.
///
/// Kept out of `MetricsStore` on purpose: this is expensive, user-initiated work
/// with its own lifecycle, and it must never start just because a tab was opened.
@MainActor
@Observable
final class StorageBreakdownModel {
    enum Phase: Equatable {
        case idle
        case running(StorageProgress)
        case done(StorageBreakdown)
        case failed
    }

    private(set) var phase: Phase = .idle
    private var work: Task<Void, Never>?

    var isRunning: Bool { if case .running = phase { return true } else { return false } }

    func analyze(volumeUsed: Int64) {
        guard !isRunning else { return }
        phase = .running(StorageProgress(completed: 0, total: 1, currentName: "Starting…"))

        let analyzer = StorageAnalyzer()
        work = Task(priority: .utility) {
            do {
                let breakdown = try await analyzer.analyze(volumeUsed: volumeUsed) { progress in
                    Task { @MainActor in
                        if case .running = self.phase { self.phase = .running(progress) }
                    }
                }
                await MainActor.run { self.phase = .done(breakdown) }
            } catch is CancellationError {
                await MainActor.run { self.phase = .idle }
            } catch {
                Log.cleaner.error("storage analysis failed: \(error.localizedDescription)")
                await MainActor.run { self.phase = .failed }
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        phase = .idle
    }
}

struct StorageBreakdownCard: View {
    @Environment(MetricsStore.self) private var store
    @State private var model = StorageBreakdownModel()

    /// Beyond this the rows stop being individually meaningful and the card
    /// stops being readable; the rest is summed into one row.
    private let visibleRows = 12

    var body: some View {
        Card(title: "What Is Using the Space", symbol: "chart.pie",
             accessory: accessory, fillsHeight: true) {
            switch model.phase {
            case .idle: intro
            case .running(let progress): running(progress)
            case .done(let breakdown): results(breakdown)
            case .failed: failure
            }
        }
    }

    private var accessory: String? {
        if case .done(let breakdown) = model.phase {
            return "of \(Format.bytes(breakdown.volumeUsed)) used"
        }
        return nil
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("""
            Measures every top-level folder in your home directory, plus \
            Applications, and reports what is left over as system files. This \
            walks the whole disk, so it takes a while and only runs when you \
            ask for it.
            """)
            .font(.note)
            .foregroundStyle(.secondary)

            Button("Analyze Storage") {
                model.analyze(volumeUsed: store.disk?.primary?.used ?? 0)
            }
            .disabled(store.disk?.primary == nil)
            Spacer(minLength: 0)
        }
    }

    private func running(_ progress: StorageProgress) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ProgressView(value: progress.fraction)
            Text("\(progress.completed) of \(progress.total) folders · \(progress.currentName)")
                .font(.note)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Cancel") { model.cancel() }
            Spacer(minLength: 0)
        }
    }

    private var failure: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("The analysis could not be completed.")
                .font(.note)
                .foregroundStyle(.secondary)
            Button("Try Again") {
                model.analyze(volumeUsed: store.disk?.primary?.used ?? 0)
            }
            Spacer(minLength: 0)
        }
    }

    private func results(_ breakdown: StorageBreakdown) -> some View {
        let shown = Array(breakdown.categories.prefix(visibleRows))
        let rest = breakdown.categories.dropFirst(visibleRows).reduce(0) { $0 + $1.bytes }

        return VStack(alignment: .leading, spacing: 7) {
            CompositionBar(
                segments: shown.enumerated().map { index, category in
                    .init(category.id, Double(category.bytes), Self.palette[index % Self.palette.count])
                },
                total: Double(max(breakdown.volumeUsed, breakdown.measured)),
                height: 10
            )

            VStack(spacing: 3) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, category in
                    row(category.name, category.bytes,
                        color: Self.palette[index % Self.palette.count],
                        url: category.url)
                }
                if rest > 0 {
                    row("Everything else", rest, color: Color(nsColor: .quaternaryLabelColor), url: nil)
                }
            }

            Spacer(minLength: 0)
            Button("Rescan") {
                model.analyze(volumeUsed: store.disk?.primary?.used ?? 0)
            }
            .controlSize(.small)
        }
    }

    private func row(_ name: String, _ bytes: Int64, color: Color, url: URL?) -> some View {
        BreakdownRow(name: name, bytes: bytes, color: color, url: url)
    }

    /// Distinct in both appearances, and none of them red: a folder being large
    /// is a fact, not a fault.
    private static let palette: [Color] = [
        .accentColor, .indigo, .teal, .orange, .purple,
        .mint, .blue, .brown, .cyan, .gray,
    ]
}

/// One row of the breakdown. Rows that correspond to a real folder open it in
/// Finder — "41 GB in Projects" invites the obvious next question, and the
/// answer is one click away rather than a path you have to retype.
private struct BreakdownRow: View {
    let name: String
    let bytes: Int64
    let color: Color
    let url: URL?

    @State private var isHovering = false

    var body: some View {
        Button {
            guard let url else { return }
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isHovering && url != nil ? Color.accentColor : .primary)
                if url != nil {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.note)
                        .foregroundStyle(.tertiary)
                        .opacity(isHovering ? 1 : 0)
                }
                Spacer(minLength: 8)
                Text(Format.bytes(bytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.note)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .onHover { isHovering = $0 }
        .help(url?.path ?? "Space not accounted for by any folder listed above")
        .contextMenu {
            if let url {
                Button("Open in Finder") { NSWorkspace.shared.open(url) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }
}
