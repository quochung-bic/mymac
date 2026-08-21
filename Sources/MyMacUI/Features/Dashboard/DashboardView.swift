import MyMacCore
import SwiftUI

/// The dashboard fits the window. It does not scroll.
///
/// A dashboard that scrolls is not a dashboard — you cannot see the state of
/// the machine at a glance if half of it is below the fold, and the scroll bar
/// itself is a permanent admission that the layout does not fit. Every card
/// shares the height of its row, so the grid stays aligned at any window size.
struct DashboardView: View {
    @Environment(MetricsStore.self) private var store

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                CPUCard()
                MemoryCard()
            }
            .frame(height: 228)

            HStack(spacing: 12) {
                StorageCard()
                NetworkCard()
                if store.battery != nil { BatteryCard() }
            }
            .frame(height: 156)

            // The metric cards keep a fixed height so they never grow empty
            // space; a taller window turns into more processes instead.
            ProcessStripCard()
                .frame(maxHeight: .infinity)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("System Status")
        .metricsScope(.detail, store: store)
        .metricsScope(.processes, store: store)
    }
}

struct CPUCard: View {
    @Environment(MetricsStore.self) private var store

    var body: some View {
        Card(title: "CPU", symbol: "cpu",
             accessory: SystemInfo.current.coreSummary,
             fillsHeight: true,
             onOpen: { AppState.shared.selectSection(.cpu) }) {
            if let cpu = store.cpu {
                CardValue(value: Format.percent(cpu.usage))
                Sparkline(values: store.cpuHistory, tint: .forUsage(cpu.usage), maximum: 1)
                    .frame(maxHeight: .infinity)
                HStack(spacing: 14) {
                    InlineStat(label: "User", value: Format.percent(cpu.user))
                    InlineStat(label: "System", value: Format.percent(cpu.system))
                    InlineStat(label: "Idle", value: Format.percent(cpu.idle))
                }
            } else {
                PlaceholderRows(count: 3)
            }
        }
    }
}

struct MemoryCard: View {
    @Environment(MetricsStore.self) private var store

    private let legendColumns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        Card(title: "Memory", symbol: "memorychip", fillsHeight: true,
             onOpen: { AppState.shared.selectSection(.memory) }) {
            if let memory = store.memory {
                HStack(alignment: .firstTextBaseline) {
                    CardValue(value: Format.bytes(memory.used),
                              caption: "of \(Format.bytes(memory.total))",
                              size: 22)
                    Spacer(minLength: 6)
                    PressureBadge(pressure: memory.pressure)
                }

                // What the memory is being used *for* matters more than how full
                // it is; a percentage cannot tell a machine holding evictable
                // file cache apart from one that is genuinely out of room.
                CompositionBar(
                    segments: [
                        .init("app", Double(memory.app), .memoryApp),
                        .init("wired", Double(memory.wired), .memoryWired),
                        .init("compressed", Double(memory.compressed), .memoryCompressed),
                        .init("cached", Double(memory.cached), .memoryCached),
                    ],
                    total: Double(memory.total)
                )

                LazyVGrid(columns: legendColumns, alignment: .leading, spacing: 6) {
                    LegendTile(color: .memoryApp, label: "App", value: Format.bytes(memory.app))
                    LegendTile(color: .memoryWired, label: "Wired", value: Format.bytes(memory.wired))
                    LegendTile(color: .memoryCompressed, label: "Compressed", value: Format.bytes(memory.compressed))
                    LegendTile(color: .memoryCached, label: "Cached", value: Format.bytes(memory.cached))
                }

                Sparkline(values: store.memoryHistory,
                          tint: .forUsage(memory.usedFraction),
                          maximum: 1,
                          fillOpacity: 0.1)
                    .frame(maxHeight: .infinity)

                if memory.swapTotal > 0 {
                    // Swap filling up is the signal that matters once memory is
                    // tight, so it gets a meter rather than a line of text.
                    let swapFraction = Double(memory.swapUsed) / Double(memory.swapTotal)
                    HStack(spacing: 8) {
                        InlineStat(label: "Swap", value: Format.bytes(memory.swapUsed))
                        MeterBar(fraction: swapFraction, tint: .forUsage(swapFraction), height: 4)
                        Text(Format.percent(swapFraction))
                            .font(.note)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                PlaceholderRows(count: 4)
            }
        }
    }
}

struct StorageCard: View {
    @Environment(MetricsStore.self) private var store

    var body: some View {
        Card(title: "Storage", symbol: "internaldrive",
             accessory: store.disk?.primary?.name,
             fillsHeight: true,
             onOpen: { AppState.shared.selectSection(.storage) }) {
            if let volume = store.disk?.primary, let disk = store.disk {
                CardValue(value: Format.bytes(volume.available), caption: "free", size: 22)
                MeterBar(fraction: volume.usedFraction, tint: .forUsage(volume.usedFraction))
                InlineStat(label: "Used",
                           value: "\(Format.percent(volume.usedFraction)) of \(Format.bytes(volume.total))")
                Spacer(minLength: 0)
                HStack(spacing: 14) {
                    InlineStat(label: "Read", value: Format.throughput(disk.readThroughput))
                    InlineStat(label: "Write", value: Format.throughput(disk.writeThroughput))
                }
            } else {
                PlaceholderRows(count: 3)
            }
        }
    }
}

struct NetworkCard: View {
    @Environment(MetricsStore.self) private var store

    var body: some View {
        Card(title: "Network", symbol: "network",
             accessory: store.network?.interfaceName,
             fillsHeight: true,
             onOpen: { AppState.shared.selectSection(.network) }) {
            if let network = store.network {
                HStack(spacing: 12) {
                    Label(Format.throughput(network.downloadThroughput), systemImage: "arrow.down")
                    Label(Format.throughput(network.uploadThroughput), systemImage: "arrow.up")
                }
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit()

                Sparkline(values: store.downloadHistory, tint: .accentColor)
                    .frame(maxHeight: .infinity)

                InlineStat(label: network.isConnected ? network.interfaceKind : "Offline",
                           value: "↓\(Format.bytes(network.totalReceived))  ↑\(Format.bytes(network.totalSent))")
            } else {
                PlaceholderRows(count: 3)
            }
        }
    }
}

struct BatteryCard: View {
    @Environment(MetricsStore.self) private var store

    var body: some View {
        Card(title: "Battery", symbol: "battery.100", fillsHeight: true,
             onOpen: { AppState.shared.selectSection(.battery) }) {
            if let battery = store.battery {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    CardValue(value: Format.percent(battery.charge), size: 22)
                    Image(systemName: battery.symbolName)
                        .imageScale(.medium)
                        .foregroundStyle(battery.symbolTint)
                    Spacer(minLength: 4)
                }
                MeterBar(fraction: battery.charge,
                         tint: battery.charge < 0.2 && !battery.isCharging ? .red : .accentColor)
                InlineStat(label: "Source", value: battery.powerSource.rawValue)
                Spacer(minLength: 0)
                InlineStat(label: "Status", value: battery.statusDescription)
            } else {
                PlaceholderRows(count: 3)
            }
        }
    }
}

/// Top consumers, two columns, five rows. Enough to answer "what is eating my
/// machine" without turning the dashboard into a process list.
struct ProcessStripCard: View {
    @Environment(MetricsStore.self) private var store

    var body: some View {
        Card(title: "Top Processes", symbol: "list.bullet",
             accessory: store.processes.isEmpty ? nil : "\(store.processes.count) running",
             fillsHeight: true,
             onOpen: { AppState.shared.selectSection(.processes) }) {
            if store.processes.isEmpty {
                PlaceholderRows(count: 4)
            } else {
                GeometryReader { geometry in
                    let rows = max(3, Int((geometry.size.height - 15) / 18))
                    HStack(alignment: .top, spacing: 22) {
                        ProcessMiniList(title: "CPU", key: .cpu, limit: rows)
                        Divider()
                        ProcessMiniList(title: "Memory", key: .memory, limit: rows)
                    }
                }
            }
        }
    }
}

private struct ProcessMiniList: View {
    @Environment(MetricsStore.self) private var store
    let title: String
    let key: ProcessSortKey
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.sectionLabel)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            ForEach(ProcessSorter.sort(store.processes, by: key).prefix(limit)) { process in
                HStack(spacing: 8) {
                    Text(process.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(value(for: process))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.note)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func value(for process: ProcessSample) -> String {
        switch key {
        case .memory: process.memoryFootprint.map(Format.bytes) ?? "—"
        default: process.cpuUsage.map(Format.processCPU) ?? "—"
        }
    }
}

/// Shown for the first second, before the first delta exists. Nothing is
/// invented in the meantime.
struct PlaceholderRows: View {
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .quaternaryLabelColor))
                    .frame(height: 10)
            }
        }
        .padding(.vertical, 4)
        .redacted(reason: .placeholder)
    }
}
