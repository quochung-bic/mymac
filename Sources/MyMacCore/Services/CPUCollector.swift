import Darwin
import Foundation

/// Reads CPU tick counters straight from the Mach host port.
///
/// `host_statistics(HOST_CPU_LOAD_INFO)` returns monotonically increasing tick
/// counts per state, so a usage figure is always the delta between two samples
/// — the very first sample therefore has nothing to compare against and is
/// reported as fully idle rather than as a fabricated number.
@MetricsActor
public final class CPUCollector {
    /// Raw tick counters for one sampling point.
    nonisolated struct Ticks: Equatable, Sendable {
        var user: UInt32 = 0
        var system: UInt32 = 0
        var idle: UInt32 = 0
        var nice: UInt32 = 0

        var total: UInt64 {
            UInt64(user) &+ UInt64(system) &+ UInt64(idle) &+ UInt64(nice)
        }
    }

    /// Fractions of the interval spent in each state.
    ///
    /// Split out from `sample()` so the arithmetic — including 32-bit counter
    /// wraparound — can be tested without a live kernel.
    nonisolated static func fractions(current: Ticks, previous: Ticks) -> (user: Double, system: Double, idle: Double, nice: Double) {
        let deltaUser = Double(current.user &- previous.user)
        let deltaSystem = Double(current.system &- previous.system)
        let deltaIdle = Double(current.idle &- previous.idle)
        let deltaNice = Double(current.nice &- previous.nice)
        let total = deltaUser + deltaSystem + deltaIdle + deltaNice
        guard total > 0 else { return (0, 0, 1, 0) }
        return (deltaUser / total, deltaSystem / total, deltaIdle / total, deltaNice / total)
    }

    private var previousAggregate: Ticks?
    private var previousPerCore: [Ticks] = []

    /// Constructible from anywhere; every method that touches state is isolated.
    public nonisolated init() {}

    public func sample() -> CPUStats {
        let coreCount = ProcessInfo.processInfo.activeProcessorCount
        let load = Self.processorSetLoad()
        let aggregate = readAggregate()
        let perCoreTicks = readPerCore()

        var user = 0.0, system = 0.0, idle = 1.0, nice = 0.0
        if let aggregate, let previous = previousAggregate {
            // Tick counters are 32-bit and wrap; `&-` inside `fractions` gives
            // the correct delta across a wrap as long as we sample far more
            // often than 2^32 ticks.
            (user, system, idle, nice) = Self.fractions(current: aggregate, previous: previous)
        }
        if let aggregate { previousAggregate = aggregate }

        var perCore: [Double] = []
        if !previousPerCore.isEmpty, previousPerCore.count == perCoreTicks.count {
            perCore = zip(perCoreTicks, previousPerCore).map { current, previous in
                let busy = Double((current.user &- previous.user)
                    &+ (current.system &- previous.system)
                    &+ (current.nice &- previous.nice))
                let total = Double(current.total &- previous.total)
                return total > 0 ? min(1, max(0, busy / total)) : 0
            }
        } else {
            perCore = Array(repeating: 0, count: perCoreTicks.count)
        }
        if !perCoreTicks.isEmpty { previousPerCore = perCoreTicks }

        return CPUStats(
            user: user,
            system: system,
            idle: idle,
            niceTime: nice,
            perCore: perCore,
            loadAverage: Self.loadAverage(),
            coreCount: coreCount,
            taskCount: load?.tasks,
            threadCount: load?.threads
        )
    }

    private func readAggregate() -> Ticks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(MachHost.host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            Log.metrics.error("host_statistics(HOST_CPU_LOAD_INFO) failed: \(result)")
            return nil
        }
        return Ticks(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )
    }

    private func readPerCore() -> [Ticks] {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(MachHost.host, PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount, &infoArray, &infoCount)
        guard result == KERN_SUCCESS, let infoArray else { return [] }
        defer {
            // host_processor_info hands back vm_allocate'd memory we own.
            let size = vm_size_t(UInt(infoCount) * UInt(MemoryLayout<integer_t>.stride))
            vm_deallocate(MachHost.task, vm_address_t(UInt(bitPattern: infoArray)), size)
        }

        let states = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { core in
            let base = core * states
            return Ticks(
                user: UInt32(bitPattern: infoArray[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: infoArray[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: infoArray[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: infoArray[base + Int(CPU_STATE_NICE)])
            )
        }
    }

    /// Task and thread totals from the default processor set. This is the same
    /// source Activity Monitor uses, and it needs no privileges — unlike
    /// summing per-process thread counts, which the kernel would refuse for
    /// other users' processes.
    private nonisolated static func processorSetLoad() -> (tasks: Int, threads: Int)? {
        var info = processor_set_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<processor_set_load_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                processor_set_statistics(MachHost.defaultProcessorSet, PROCESSOR_SET_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (Int(info.task_count), Int(info.thread_count))
    }

    private static func loadAverage() -> LoadAverage {
        var samples = [Double](repeating: 0, count: 3)
        guard getloadavg(&samples, 3) == 3 else {
            return LoadAverage(oneMinute: 0, fiveMinutes: 0, fifteenMinutes: 0)
        }
        return LoadAverage(oneMinute: samples[0], fiveMinutes: samples[1], fifteenMinutes: samples[2])
    }
}
