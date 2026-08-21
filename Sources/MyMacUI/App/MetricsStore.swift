import AppKit
import MyMacCore
import Observation
import SwiftUI

/// The single source of truth the interface observes.
///
/// Sampling is demand-driven. Nothing is collected unless something on screen
/// needs it, and the interval widens when only the menu bar is watching, so an
/// idle Mac is not woken up once a second for numbers nobody is reading.
@MainActor
@Observable
final class MetricsStore {
    enum Scope: Hashable {
        /// The menu bar title. Cheap, low frequency, always present.
        case menuBar
        /// A visible window showing live charts.
        case detail
        /// A visible process list.
        case processes
        /// Something on screen is showing Wi-Fi radio detail.
        ///
        /// Separate from `.detail` because reading the radio is by far the most
        /// expensive part of a sample — CoreWLAN takes it from 1.1 ms to 4.8 ms
        /// and keeps a chattering XPC connection to `airportd` alive. Only the
        /// Network page shows those figures, but the menu bar popover was
        /// taking `.detail` too, so opening it paid for a reading nothing in it
        /// displays.
        case radio
    }

    private(set) var cpu: CPUStats?
    private(set) var memory: MemoryStats?
    private(set) var disk: DiskStats?
    private(set) var battery: BatteryStats?
    private(set) var network: NetworkStats?
    private(set) var processes: [ProcessSample] = []
    /// Processes behaving unusually, refreshed alongside the process list.
    private(set) var alerts: [ProcessAlert] = []

    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    private(set) var downloadHistory: [Double] = []
    private(set) var uploadHistory: [Double] = []

    /// Roughly five minutes at the fast cadence — enough for a sparkline,
    /// small enough to be irrelevant to the memory footprint.
    private static let historyCapacity = 300

    private var cpuWindow = RollingWindow<Double>(capacity: historyCapacity)
    private var memoryWindow = RollingWindow<Double>(capacity: historyCapacity)
    private var downloadWindow = RollingWindow<Double>(capacity: historyCapacity)
    private var uploadWindow = RollingWindow<Double>(capacity: historyCapacity)

    /// Looked up only while the Network page is open, and cached beyond that.
    private(set) var publicAddress: PublicAddress?
    private(set) var isLookingUpPublicAddress = false
    private(set) var publicAddressUnavailable = false

    private let monitor = SystemMonitor()
    private let publicAddressService = PublicAddressService()
    private var scopes: [Scope: Int] = [:]
    private var loop: Task<Void, Never>?
    private var slowTickCounter = 0
    private var watcher = ProcessWatcher()

    @ObservationIgnored private var lastProcessSample = Date.distantPast

    var isRunning: Bool { loop != nil }

    /// Fast enough to feel live, slow enough to stay invisible in Activity
    /// Monitor. Widened to three seconds when only the menu bar is watching.
    private var interval: Duration {
        let base = scopes[.detail, default: 0] > 0 ? 1.0 : 3.0
        // Read straight from defaults: the settings page and the store then have
        // no wiring between them to keep in step.
        let relaxed = UserDefaults.standard.bool(forKey: SettingsKey.relaxedUpdates)
        return .seconds(base * (relaxed ? 2 : 1))
    }

    private var slowInterval: Int {
        scopes[.detail, default: 0] > 0 ? 15 : 5
    }

    func retain(_ scope: Scope) {
        scopes[scope, default: 0] += 1
        if loop == nil { start() }
    }

    func release(_ scope: Scope) {
        guard let count = scopes[scope], count > 0 else { return }
        if count == 1 { scopes.removeValue(forKey: scope) } else { scopes[scope] = count - 1 }
        if scopes.isEmpty { stop() }
        if scopes[.processes] == nil {
            processes = []
            alerts = []
        }
    }

    private func start() {
        guard loop == nil else { return }
        let monitor = self.monitor
        // The loop itself stays on the main actor (it only reads and writes the
        // store); every actual sample hops to `MetricsActor` and back.
        loop = Task(priority: .utility) { [weak self] in
            await monitor.start()
            while !Task.isCancelled {
                await self?.tick()
                guard let interval = self?.interval else { break }
                try? await Task.sleep(for: interval)
            }
            await monitor.stop()
        }
    }

    private func stop() {
        loop?.cancel()
        loop = nil
        slowTickCounter = 0
    }

    private func tick() async {
        // Wi-Fi radio detail is only shown on the Network page, and reading it
        // is the most expensive part of a sample.
        let fast = await monitor.sampleFast(includeRadio: scopes[.radio, default: 0] > 0)
        apply(fast)

        if slowTickCounter % slowInterval == 0 {
            let slow = await monitor.sampleSlow()
            disk = slow.disk
            battery = slow.battery
        }
        slowTickCounter += 1

        if scopes[.processes, default: 0] > 0 {
            // The process walk is the most expensive sample by far, so it runs
            // at half the rate of everything else and only while it is visible.
            if Date().timeIntervalSince(lastProcessSample) >= 2 {
                lastProcessSample = Date()
                let names = Self.applicationNames()
                processes = await monitor.sampleProcesses(applicationNames: names)
                alerts = watcher.observe(processes)
            }
        }
    }

    private func apply(_ sample: SystemMonitor.FastSample) {
        cpu = sample.cpu
        memory = sample.memory
        network = sample.network

        cpuWindow.append(sample.cpu.usage)
        memoryWindow.append(sample.memory.usedFraction)
        downloadWindow.append(sample.network.downloadThroughput)
        uploadWindow.append(sample.network.uploadThroughput)

        cpuHistory = cpuWindow.values
        memoryHistory = memoryWindow.values
        downloadHistory = downloadWindow.values
        uploadHistory = uploadWindow.values

        refreshMenuBarText()
    }

    /// Localized application names, which are far friendlier than executable
    /// names. Only GUI apps have them, so everything else keeps its binary name.
    func lookupPublicAddress(force: Bool = false) {
        guard !isLookingUpPublicAddress else { return }
        if publicAddress != nil, !force { return }
        isLookingUpPublicAddress = true
        publicAddressUnavailable = false

        Task { [publicAddressService] in
            let result = try? await publicAddressService.lookup(force: force)
            await MainActor.run {
                self.publicAddress = result ?? self.publicAddress
                self.publicAddressUnavailable = result == nil
                self.isLookingUpPublicAddress = false
            }
        }
    }

    private static func applicationNames() -> [pid_t: String] {
        var result: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let name = app.localizedName else { continue }
            result[app.processIdentifier] = name
        }
        return result
    }

    /// Menu bar readouts, stored rather than computed and only assigned when
    /// the rendered string actually differs.
    ///
    /// A computed property would be re-read on every sample, and every read
    /// that observation sees as a change makes AppKit re-lay out and re-snapshot
    /// the status item — by far the most expensive thing this app does per tick.
    /// Keeping the item a constant width is the renderer's job, not this one's.
    private(set) var menuBarCPUText = "—"
    private(set) var menuBarMemoryText = "—"

    /// Whether the status item is showing live numbers.
    ///
    /// Deliberately *not* tied to the lifetime of the label view: macOS
    /// destroys and recreates the status item's hosted view when the menu bar
    /// auto-hides, when a full-screen app covers it, and when the item overflows
    /// off the edge of a notched display. Sampling has to survive all of that,
    /// so this scope is only released when the user actually turns the readout
    /// off in Settings.
    private(set) var isMenuBarActive = false

    func setMenuBarActive(_ active: Bool) {
        guard active != isMenuBarActive else { return }
        isMenuBarActive = active
        if active { retain(.menuBar) } else { release(.menuBar) }
    }

    private func refreshMenuBarText() {
        let cpuText = cpu.map { Self.paddedPercent($0.usage) } ?? "—"
        let memoryText = memory.map { Self.paddedPercent($0.usedFraction) } ?? "—"
        if cpuText != menuBarCPUText { menuBarCPUText = cpuText }
        if memoryText != menuBarMemoryText { menuBarMemoryText = memoryText }
    }

    private static func paddedPercent(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }
}

extension View {
    /// Keeps a sampling scope alive for exactly as long as the view is on screen.
    func metricsScope(_ scope: MetricsStore.Scope, store: MetricsStore) -> some View {
        task {
            store.retain(scope)
            // Suspends until the view disappears, at which point the task is
            // cancelled and the scope is released.
            defer { store.release(scope) }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }
}
