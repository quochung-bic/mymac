import Darwin
import Foundation

/// Something worth a second look about a running process.
public struct ProcessAlert: Sendable, Identifiable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// Mean CPU over the observation window, as a fraction of one core.
        case sustainedCPU(average: Double, seconds: Int)
        /// Footprint grew by this much across the window and now stands here.
        case growingMemory(growth: UInt64, current: UInt64)
    }

    public let id: pid_t
    public let process: ProcessSample
    public let reason: Reason

    public var headline: String {
        switch reason {
        case .sustainedCPU(let average, let seconds):
            "Using \(Format.processCPU(average)) of a core for \(seconds)s"
        case .growingMemory(let growth, let current):
            "Grew by \(Format.bytes(growth)), now \(Format.bytes(current))"
        }
    }

    public var advice: String {
        switch reason {
        case .sustainedCPU:
            "Busy work looks the same as a stuck loop from the outside. If the app is doing something you asked for, leave it."
        case .growingMemory:
            "Steady growth can be a leak, or simply a large task in progress."
        }
    }
}

/// Watches process samples over time and flags the ones behaving unusually.
///
/// Deliberately conservative. An app is only flagged after sustaining the
/// behaviour for a while, because a burst of CPU is what a computer is *for* —
/// flagging every spike would train the user to ignore the whole feature.
///
/// What this cannot do is detect a beachballed app. macOS exposes no public API
/// for it: `kinfo_proc.p_stat` reports every process as "running" on current
/// systems, a hung app is indistinguishable from an idle one by CPU time, and
/// the call Activity Monitor uses is private. Claiming otherwise would mean
/// guessing, so this reports only what it can actually observe.
public struct ProcessWatcher: Sendable {
    public struct Thresholds: Sendable {
        /// Fraction of one core. 0.8 means "most of a core, continuously".
        public var sustainedCPU: Double = 0.8
        /// How many consecutive samples must agree before anything is said.
        public var minimumSamples: Int = 8
        /// Growth across the window that counts as unusual.
        public var memoryGrowth: UInt64 = 1_000_000_000
        /// Below this, growth is not worth mentioning however fast it is.
        public var memoryFloor: UInt64 = 3_000_000_000

        public init() {}
    }

    private struct History {
        var cpu: [Double] = []
        var memory: [UInt64] = []
        var name: String = ""
    }

    public let thresholds: Thresholds
    /// Samples kept per process. At the two-second process cadence this is
    /// roughly half a minute of history.
    private let windowLength = 15
    private var histories: [pid_t: History] = [:]

    public init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    /// - Parameter interval: seconds between samples, used to describe how long
    ///   the behaviour has gone on.
    public mutating func observe(_ processes: [ProcessSample], interval: Double = 2) -> [ProcessAlert] {
        var seen = Set<pid_t>()

        for process in processes {
            seen.insert(process.id)
            var history = histories[process.id] ?? History()
            history.name = process.name
            if let cpu = process.cpuUsage {
                history.cpu.append(cpu)
                if history.cpu.count > windowLength { history.cpu.removeFirst() }
            }
            if let memory = process.memoryFootprint {
                history.memory.append(memory)
                if history.memory.count > windowLength { history.memory.removeFirst() }
            }
            histories[process.id] = history
        }
        // A process that exited takes its history with it; keeping it would let
        // a recycled PID inherit someone else's behaviour.
        histories = histories.filter { seen.contains($0.key) }

        var alerts: [ProcessAlert] = []
        for process in processes {
            guard let history = histories[process.id] else { continue }
            if let alert = cpuAlert(process, history, interval: interval) {
                alerts.append(alert)
                continue
            }
            if let alert = memoryAlert(process, history) {
                alerts.append(alert)
            }
        }
        return alerts.sorted { $0.process.cpuUsage ?? 0 > $1.process.cpuUsage ?? 0 }
    }

    private func cpuAlert(_ process: ProcessSample, _ history: History, interval: Double) -> ProcessAlert? {
        guard history.cpu.count >= thresholds.minimumSamples else { return nil }
        let window = history.cpu.suffix(thresholds.minimumSamples)
        // Every sample in the window has to agree, not just the average: one
        // long spike inside an otherwise quiet window is not "sustained".
        guard window.allSatisfy({ $0 >= thresholds.sustainedCPU }) else { return nil }
        let average = window.reduce(0, +) / Double(window.count)
        return ProcessAlert(
            id: process.id,
            process: process,
            reason: .sustainedCPU(average: average, seconds: Int(Double(window.count) * interval))
        )
    }

    private func memoryAlert(_ process: ProcessSample, _ history: History) -> ProcessAlert? {
        guard history.memory.count >= thresholds.minimumSamples,
              let first = history.memory.first, let latest = history.memory.last,
              latest >= thresholds.memoryFloor, latest > first,
              latest - first >= thresholds.memoryGrowth
        else { return nil }
        return ProcessAlert(
            id: process.id,
            process: process,
            reason: .growingMemory(growth: latest - first, current: latest)
        )
    }
}
