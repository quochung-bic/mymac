import MyMacCore
import SwiftUI

// MARK: - CPU

struct CPUDetailView: View {
    @Environment(MetricsStore.self) private var store
    private let system = SystemInfo.current

    var body: some View {
        DetailPage(title: "CPU", heroHeight: 178) {
            Card(title: system.chip, symbol: "cpu",
                 accessory: "\(system.coreSummary) · up \(Format.uptime(system.uptime))",
                 fillsHeight: true) {
                if let cpu = store.cpu {
                    CardValue(value: Format.percent(cpu.usage), caption: "in use", size: 30)
                    Sparkline(values: store.cpuHistory, tint: .forUsage(cpu.usage), maximum: 1)
                        .frame(maxHeight: .infinity)
                } else {
                    PlaceholderRows(count: 4)
                }
            }
        } figures: {
            TileCard(title: "Activity", symbol: "waveform.path.ecg", columns: 6, tiles: tiles)
        } extra: {
            HStack(spacing: 12) {
                distribution.frame(width: 250)
                cores
            }
        }
        .metricsScope(.detail, store: store)
    }

    private var tiles: [StatTile] {
        let cpu = store.cpu
        return [
            StatTile(label: "User", value: cpu.map { Format.percent($0.user) } ?? "—"),
            StatTile(label: "System", value: cpu.map { Format.percent($0.system) } ?? "—"),
            StatTile(label: "Idle", value: cpu.map { Format.percent($0.idle) } ?? "—"),
            StatTile(label: "Load 1m", value: cpu.map { String(format: "%.2f", $0.loadAverage.oneMinute) } ?? "—"),
            StatTile(label: "Processes", value: cpu?.taskCount.map(Format.count) ?? "—"),
            StatTile(label: "Threads", value: cpu?.threadCount.map(Format.count) ?? "—"),
        ]
    }

    private var distribution: some View {
        Card(title: "Load Average", symbol: "gauge.with.needle", fillsHeight: true) {
            if let cpu = store.cpu {
                LoadRow(label: "1 min", value: cpu.loadAverage.oneMinute, cores: cpu.coreCount)
                LoadRow(label: "5 min", value: cpu.loadAverage.fiveMinutes, cores: cpu.coreCount)
                LoadRow(label: "15 min", value: cpu.loadAverage.fifteenMinutes, cores: cpu.coreCount)
                Spacer(minLength: 0)
                Text("Runnable threads, not a percentage. Below \(cpu.coreCount) means the machine is keeping up.")
                    .font(.note)
                    .foregroundStyle(.secondary)
            } else {
                PlaceholderRows(count: 3)
            }
        }
    }

    private var cores: some View {
        Card(title: "Cores", symbol: "square.grid.3x3",
             accessory: system.performanceCores > 0 ? "\(system.performanceCores) performance · \(system.efficiencyCores) efficiency" : nil,
             fillsHeight: true) {
            if let cpu = store.cpu, !cpu.perCore.isEmpty {
                CoreBars(usage: cpu.perCore)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PlaceholderRows(count: 2)
            }
        }
    }
}

private struct LoadRow: View {
    let label: String
    let value: Double
    let cores: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            MeterBar(fraction: cores > 0 ? value / Double(cores) : 0,
                     tint: .forUsage(cores > 0 ? value / Double(cores) : 0),
                     height: 5)
            Text(String(format: "%.2f", value))
                .font(.callout)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: - Memory

struct MemoryDetailView: View {
    @Environment(MetricsStore.self) private var store

    var body: some View {
        DetailPage(title: "Memory", heroHeight: 220) {
            MemoryCard()
        } figures: {
            TileCard(title: "Paging", symbol: "arrow.left.arrow.right", columns: 5, tiles: tiles)
        } extra: {
            Card(title: "Largest Consumers", symbol: "list.bullet",
                 accessory: "by memory footprint", fillsHeight: true) {
                if store.processes.isEmpty {
                    PlaceholderRows(count: 5)
                } else {
                    VStack(spacing: 5) {
                        ForEach(ProcessSorter.sort(store.processes, by: .memory).prefix(7)) { process in
                            HStack(spacing: 8) {
                                Text(process.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(verbatim: "\(process.pid)")
                                    .font(.note)
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                                Spacer(minLength: 8)
                                Text(process.memoryFootprint.map(Format.bytes) ?? "—")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .metricsScope(.processes, store: store)
        .metricsScope(.detail, store: store)
    }

    private var tiles: [StatTile] {
        let memory = store.memory
        let swapping = (memory?.swapInRate ?? 0) + (memory?.swapOutRate ?? 0) > 1_000_000
        return [
            StatTile(label: "Swap used", value: memory.map { Format.bytes($0.swapUsed) } ?? "—"),
            StatTile(label: "Swap in", value: memory.map { Format.throughput($0.swapInRate) } ?? "—",
                     tint: swapping ? .orange : nil),
            StatTile(label: "Swap out", value: memory.map { Format.throughput($0.swapOutRate) } ?? "—",
                     tint: swapping ? .orange : nil),
            StatTile(label: "Page ins", value: memory.map { Format.rate($0.pageInRate, unit: "/s") } ?? "—"),
            StatTile(label: "Compression",
                     value: memory.map { $0.compressionRatio > 0 ? String(format: "%.1f×", $0.compressionRatio) : "—" } ?? "—"),
        ]
    }
}

// MARK: - Storage

struct StorageDetailView: View {
    @Environment(MetricsStore.self) private var store

    var body: some View {
        DetailPage(title: "Storage", heroHeight: 166) {
            Card(title: store.disk?.primary?.name ?? "Storage", symbol: "internaldrive",
                 accessory: store.disk?.primary?.fileSystem, fillsHeight: true) {
                if let volume = store.disk?.primary {
                    CardValue(value: Format.bytes(volume.available), caption: "available", size: 28)
                    MeterBar(fraction: volume.usedFraction, tint: .forUsage(volume.usedFraction))
                    HStack(spacing: 18) {
                        InlineStat(label: "Used", value: "\(Format.bytes(volume.used)) · \(Format.percent(volume.usedFraction))")
                        InlineStat(label: "Capacity", value: Format.bytes(volume.total))
                    }
                    Spacer(minLength: 0)
                    Text("Available space includes content macOS can purge on demand, which is why it exceeds plain free space.")
                        .font(.note)
                        .foregroundStyle(.secondary)
                } else {
                    PlaceholderRows(count: 4)
                }
            }
        } figures: {
            TileCard(title: "Activity", symbol: "arrow.up.arrow.down", columns: 5, tiles: tiles)
        } extra: {
            HStack(spacing: 12) {
                Card(title: "Volumes", symbol: "externaldrive", fillsHeight: true) {
                    if let volumes = store.disk?.volumes, !volumes.isEmpty {
                        ScrollView {
                            VStack(spacing: 9) {
                                ForEach(volumes) { volume in
                                    VolumeRow(volume: volume)
                                }
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    } else {
                        PlaceholderRows(count: 2)
                    }
                }
                .frame(width: 262)

                StorageBreakdownCard()
            }
        }
        .metricsScope(.detail, store: store)
    }

    private var tiles: [StatTile] {
        let disk = store.disk
        return [
            StatTile(label: "Purgeable", value: disk?.primary.map { Format.bytes($0.purgeable) } ?? "—"),
            StatTile(label: "Read", value: disk.map { Format.throughput($0.readThroughput) } ?? "—"),
            StatTile(label: "Write", value: disk.map { Format.throughput($0.writeThroughput) } ?? "—"),
            StatTile(label: "Read ops", value: disk.map { Format.rate($0.readOperations, unit: "/s") } ?? "—"),
            StatTile(label: "Write ops", value: disk.map { Format.rate($0.writeOperations, unit: "/s") } ?? "—"),
        ]
    }
}

private struct VolumeRow: View {
    let volume: VolumeStats

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: volume.isRemovable ? "externaldrive" : "internaldrive")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(volume.name).lineLimit(1)
                if let fileSystem = volume.fileSystem {
                    Text(fileSystem)
                        .font(.note)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Text("\(Format.bytes(volume.available)) free of \(Format.bytes(volume.total))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            MeterBar(fraction: volume.usedFraction, tint: .forUsage(volume.usedFraction), height: 4)
        }
    }
}

// MARK: - Network

struct NetworkDetailView: View {
    @Environment(MetricsStore.self) private var store

    var body: some View {
        DetailPage(title: "Network", heroHeight: 176, figuresHeight: 96) {
            throughput
        } figures: {
            addresses
        } extra: {
            HStack(spacing: 12) {
                if store.network?.wifi != nil { wifi.frame(width: 268) }
                connection
            }
        }
        .metricsScope(.detail, store: store)
        // The only outbound request the app makes, and only while this page is
        // on screen. The answer is cached for fifteen minutes after that.
        .task { store.lookupPublicAddress() }
    }

    private var throughput: some View {
        Card(title: "Throughput", symbol: "network",
             accessory: store.network.map { $0.isConnected ? $0.interfaceKind : "Offline" },
             fillsHeight: true) {
            if let network = store.network {
                HStack(spacing: 20) {
                    CardValue(value: Format.throughput(network.downloadThroughput), caption: "down", size: 22)
                    CardValue(value: Format.throughput(network.uploadThroughput), caption: "up", size: 22)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        InlineStat(label: "Peak ↓", value: Format.throughput(store.downloadHistory.max() ?? 0))
                        InlineStat(label: "Peak ↑", value: Format.throughput(store.uploadHistory.max() ?? 0))
                    }
                }
                ZStack {
                    Sparkline(values: store.downloadHistory, tint: .accentColor)
                    Sparkline(values: store.uploadHistory, tint: .teal, fillOpacity: 0)
                }
                .frame(maxHeight: .infinity)
            } else {
                PlaceholderRows(count: 4)
            }
        }
    }

    /// Addresses are the values people copy out of a network panel, so they get
    /// their own row with copy buttons rather than sitting in a plain tile grid.
    private var addresses: some View {
        Card(title: "Addresses", symbol: "number", fillsHeight: true) {
            // Three columns, not six: an IPv4 address needs real width, and a
            // truncated address is useless to the person trying to copy it.
            HStack(alignment: .top, spacing: 18) {
                CopyableTile(label: "Local", value: store.network?.addresses.first ?? "—")
                CopyableTile(label: "Router", value: store.network?.router ?? "—")
                publicAddressTile
            }
        }
    }

    @ViewBuilder
    private var publicAddressTile: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Public")
                    .font(.note)
                    .foregroundStyle(.secondary)
                if store.isLookingUpPublicAddress {
                    ProgressView().controlSize(.mini).scaleEffect(0.6)
                } else {
                    Button {
                        store.lookupPublicAddress(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise").imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Ask \(PublicAddressService.endpointName) again")
                }
            }
            if let address = store.publicAddress {
                CopyableValue(value: address.ip)
                Text(address.country.map { "\($0) · via \(PublicAddressService.endpointName)" }
                     ?? "via \(PublicAddressService.endpointName)")
                    .font(.note)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text(store.publicAddressUnavailable ? "Unavailable" : "Looking up…")
                    .font(.tileValue)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Radio conditions. Signal strength alone is a poor guide — a strong signal
    /// in a noisy room is still a bad link — so the noise floor and the gap
    /// between them are given equal billing.
    @ViewBuilder
    private var wifi: some View {
        if let signal = store.network?.wifi {
            Card(title: "Wi-Fi Signal", symbol: "wifi", accessory: signal.quality, fillsHeight: true) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    CardValue(value: "\(signal.rssi)", caption: "dBm", size: 24)
                    Spacer()
                    Text("\(Int(signal.transmitRate.rounded())) Mbps")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                MeterBar(fraction: signal.strengthFraction,
                         tint: signal.rssi > -70 ? .accentColor : .orange)
                InlineStat(label: "Noise", value: "\(signal.noise) dBm")
                InlineStat(label: "Signal-to-noise", value: "\(signal.signalToNoise) dB")
                InlineStat(label: "Channel",
                           value: "\(signal.channel) · \(signal.band)"
                               + (signal.channelWidth > 0 ? " · \(signal.channelWidth) MHz" : ""))
                Spacer(minLength: 0)
                Text("The network name needs Location access, which this app does not ask for.")
                    .font(.note)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var connection: some View {
        Card(title: "Connection", symbol: "point.3.connected.trianglepath.dotted", fillsHeight: true) {
            if let network = store.network {
                HStack(spacing: 16) {
                    InlineStat(label: "Interface", value: network.interfaceName ?? "—")
                    InlineStat(label: "Link", value: network.linkSpeed > 0 ? "\(network.linkSpeed / 1_000_000) Mbps" : "—")
                    InlineStat(label: "MTU", value: "\(network.mtu)")
                    InlineStat(label: "Packets", value: "\(Int(network.packetsInRate))/\(Int(network.packetsOutRate))")
                    Spacer(minLength: 0)
                }
                if !network.dnsServers.isEmpty {
                    HStack(spacing: 6) {
                        Text("DNS").font(.note).foregroundStyle(.secondary)
                        CopyableValue(value: network.dnsServers.prefix(2).joined(separator: ", "),
                                      font: .note)
                        Spacer(minLength: 0)
                    }
                }
                InlineStat(label: "Since boot",
                           value: "↓\(Format.bytes(network.lifetimeReceived))  ↑\(Format.bytes(network.lifetimeSent))")
                InlineStat(label: "This session",
                           value: "↓\(Format.bytes(network.totalReceived))  ↑\(Format.bytes(network.totalSent))")
                InlineStat(label: "Errors · drops",
                           value: "\(network.errorsIn + network.errorsOut) · \(network.drops)")

                if network.usesVPN || network.isExpensive || network.isConstrained {
                    HStack(spacing: 6) {
                        if network.usesVPN { Badge(text: "VPN", symbol: "lock.shield") }
                        if network.isExpensive { Badge(text: "Metered", symbol: "dollarsign.circle") }
                        if network.isConstrained { Badge(text: "Low Data", symbol: "tortoise") }
                    }
                    .padding(.top, 2)
                }

                if !network.interfaces.isEmpty {
                    Divider().padding(.vertical, 3)
                    ForEach(network.interfaces.prefix(4)) { interface in
                        HStack(spacing: 8) {
                            Text(interface.name).monospaced()
                            if interface.isPrimary {
                                Text("primary").font(.note).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text("↓\(Format.throughput(interface.download))  ↑\(Format.throughput(interface.upload))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.note)
                    }
                }
                Spacer(minLength: 0)
            } else {
                PlaceholderRows(count: 4)
            }
        }
    }
}

private struct Badge: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.badge)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
    }
}

// MARK: - Battery

struct BatteryDetailView: View {
    @Environment(MetricsStore.self) private var store

    var body: some View {
        if store.battery == nil {
            DetailPage(title: "Battery", heroHeight: 166) {
                Card(title: "No Battery", symbol: "powerplug", fillsHeight: true) {
                    Text("This Mac runs on wall power only, so there is nothing to report here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } figures: {
                EmptyView()
            } extra: {
                EmptyView()
            }
            .metricsScope(.detail, store: store)
        } else {
            page
        }
    }

    private var page: some View {
        DetailPage(title: "Battery", heroHeight: 166, figuresHeight: 112) {
            Card(title: "Charge", symbol: "battery.100",
                 accessory: store.battery?.isLowPowerMode == true ? "Low Power Mode" : nil,
                 fillsHeight: true) {
                if let battery = store.battery {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        CardValue(value: Format.percent(battery.charge), size: 30)
                        Image(systemName: battery.symbolName)
                            .imageScale(.large)
                            .foregroundStyle(battery.symbolTint)
                        Spacer()
                        Text(battery.statusDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    MeterBar(fraction: battery.charge,
                             tint: battery.charge < 0.2 && !battery.isCharging ? .red : .accentColor,
                             height: 8)
                    Spacer(minLength: 0)
                    if let name = battery.adapterName {
                        InlineStat(label: "Adapter", value: name)
                    } else {
                        InlineStat(label: "Power source", value: battery.powerSource.rawValue)
                    }
                } else {
                    PlaceholderRows(count: 3)
                }
            }
        } figures: {
            TileCard(title: "Health", symbol: "heart.text.square", columns: 4, tiles: tiles)
        } extra: {
            Card(title: "About These Figures", symbol: "info.circle", fillsHeight: true) {
                Text("""
                Capacity compares what the battery holds now against what it held when new; \
                macOS considers a battery worth replacing below roughly 80 %. Power is measured \
                at the battery terminals, so it reads zero when the Mac runs on the adapter \
                without charging — nothing is flowing in or out.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .metricsScope(.detail, store: store)
    }

    private var tiles: [StatTile] {
        let battery = store.battery
        let health = battery?.healthFraction
        return [
            StatTile(label: "Cycles", value: battery?.cycleCount.map(Format.count) ?? "—"),
            StatTile(label: "Capacity vs new", value: health.map { Format.percent($0) } ?? "—",
                     tint: (health ?? 1) < 0.8 ? .orange : nil),
            StatTile(label: "Condition", value: battery?.conditionLabel ?? "—",
                     tint: battery?.conditionLabel == "Normal" ? nil : .orange),
            StatTile(label: "Power source", value: battery?.powerSource.rawValue ?? "—"),
            StatTile(label: "Charge", value: battery?.currentCapacity.map { "\($0) mAh" } ?? "—"),
            StatTile(label: "Design", value: battery?.designCapacity.map { "\($0) mAh" } ?? "—"),
            StatTile(label: "Voltage", value: battery?.voltage.map { String(format: "%.2f V", $0) } ?? "—"),
            StatTile(label: "Power", value: battery?.powerDraw.map { String(format: "%.1f W", $0) } ?? "—"),
        ]
    }
}
