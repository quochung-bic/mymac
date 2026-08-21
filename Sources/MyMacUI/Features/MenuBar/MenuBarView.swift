import MyMacCore
import SwiftUI

/// The popover behind the menu bar item.
///
/// Kept to a handful of numbers and four actions. It is the surface most users
/// will look at most often, so it opens instantly, never scrolls, and behaves
/// like a real macOS menu: rows highlight on hover and the popover closes as
/// soon as you pick something.
struct MenuBarView: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            gauges
            Divider().padding(.vertical, 6)
            secondary
            if !store.alerts.isEmpty {
                Divider().padding(.vertical, 6)
                attention
            }

            Divider().padding(.vertical, 6)
            actions
        }
        .padding(9)
        .frame(width: 232)
        .metricsScope(.detail, store: store)
        .metricsScope(.processes, store: store)
    }

    private var gauges: some View {
        VStack(spacing: 8) {
            GaugeRow(symbol: "cpu.fill", tint: .accentColor,
                     value: store.cpu?.usage,
                     detail: store.cpu.map { Format.percent($0.usage) })
            GaugeRow(symbol: "memorychip.fill", tint: .memoryWired,
                     value: store.memory?.usedFraction,
                     detail: store.memory.map { Format.percent($0.usedFraction) },
                     badge: store.memory.map { AnyView(PressureBadge(pressure: $0.pressure)) })
            GaugeRow(symbol: "internaldrive.fill", tint: .memoryCompressed,
                     value: store.disk?.primary?.usedFraction,
                     detail: store.disk?.primary.map { Format.percent($0.usedFraction) })
        }
        .padding(.horizontal, 6)
    }

    private var secondary: some View {
        HStack(spacing: 0) {
            if let network = store.network {
                CompactStat(symbol: network.interfaceKind == "Wi-Fi" ? "wifi" : "cable.connector",
                            value: network.isConnected ? network.interfaceKind : "Offline")
                CompactStat(symbol: "arrow.down", value: Format.throughput(network.downloadThroughput))
                CompactStat(symbol: "arrow.up", value: Format.throughput(network.uploadThroughput))
            }
            if let battery = store.battery {
                CompactStat(symbol: battery.symbolName,
                            value: Format.percent(battery.charge),
                            tint: battery.symbolTint)
            }
        }
        .padding(.horizontal, 6)
    }

    /// Only appears when there is something to say. A permanent "all good" row
    /// would be noise, and would make the row easy to stop seeing.
    private var attention: some View {
        Button {
            choose { AppState.shared.requestMainWindow(section: .processes) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.alerts.count == 1
                         ? store.alerts[0].process.name
                         : "\(store.alerts.count) processes")
                        .lineLimit(1)
                    Text(store.alerts.count == 1 ? store.alerts[0].headline : "using unusual resources")
                        .font(.note)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.note)
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var actions: some View {
        VStack(spacing: 1) {
            MenuActionRow(title: "Open Dashboard", symbol: "square.grid.2x2", shortcut: "D") {
                choose { AppState.shared.requestMainWindow(section: .dashboard) }
            }
            MenuActionRow(title: "Clean System…", symbol: "sparkles", shortcut: "K") {
                choose { AppState.shared.requestMainWindow(section: .cleaner) }
            }
            MenuActionRow(title: "Settings…", symbol: "gearshape", shortcut: ",") {
                choose { AppState.shared.requestMainWindow(section: .settings) }
            }
            MenuActionRow(title: "Quit MyMac", symbol: "power", shortcut: "Q") {
                NSApp.terminate(nil)
            }
        }
    }

    /// Close first, then act. The popover's view tree is destroyed on dismiss,
    /// so the action is handed to `AppState` and carried out by the menu bar
    /// label, which outlives it.
    private func choose(_ action: @escaping @MainActor () -> Void) {
        dismiss()
        // One turn of the run loop later, so the popover is fully gone before a
        // window is activated on top of where it used to be.
        Task { @MainActor in action() }
    }
}

/// Icon, meter, value. No words: the symbol carries the meaning, which keeps
/// the whole panel to the width of a menu rather than a window.
private struct GaugeRow: View {
    let symbol: String
    /// Each metric's icon carries its own colour. At this size three grey
    /// outlines are hard to tell apart at a glance, which defeats the point of
    /// replacing the words with symbols.
    var tint: Color = .secondary
    let value: Double?
    let detail: String?
    var badge: AnyView?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .imageScale(.medium)
                .foregroundStyle(tint)
                .frame(width: 17)
            MeterBar(fraction: value ?? 0, tint: .forUsage(value ?? 0), height: 5)
            if let badge { badge }
            Text(detail ?? "—")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

private struct CompactStat: View {
    let symbol: String
    let value: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(tint)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .font(.note)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
