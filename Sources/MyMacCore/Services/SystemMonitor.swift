import Foundation

/// Owns every collector and hands back immutable snapshots.
///
/// Grouping the collectors here means the UI never touches a Mach API, and the
/// sampling work — which is where all the shared mutable state lives — happens
/// on one actor, off the main thread.
@MetricsActor
public final class SystemMonitor {
    public struct FastSample: Sendable {
        public let cpu: CPUStats
        public let memory: MemoryStats
        public let network: NetworkStats
    }

    public struct SlowSample: Sendable {
        public let disk: DiskStats
        public let battery: BatteryStats?
    }

    private let cpu = CPUCollector()
    private let memory = MemoryCollector()
    private let disk = DiskCollector()
    private let battery = BatteryCollector()
    private let network = NetworkCollector()
    private let processes = ProcessCollector()

    /// Constructible from anywhere; every method that touches state is isolated.
    public nonisolated init() {}

    public func start() {
        network.start()
    }

    public func stop() {
        network.stop()
    }

    public func sampleFast(includeRadio: Bool = false) -> FastSample {
        FastSample(cpu: cpu.sample(),
                   memory: memory.sample(),
                   network: network.sample(includeRadio: includeRadio))
    }

    public func sampleSlow() -> SlowSample {
        SlowSample(disk: disk.sample(), battery: battery.sample())
    }

    public func sampleProcesses(applicationNames: [pid_t: String]) -> [ProcessSample] {
        processes.sample(applicationNames: applicationNames)
    }
}
