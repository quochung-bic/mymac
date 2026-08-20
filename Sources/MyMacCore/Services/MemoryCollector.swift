import Darwin
import Foundation

/// Memory figures from `host_statistics64(HOST_VM_INFO64)` plus the swap and
/// pressure sysctls, interpreted the way macOS itself does.
@MetricsActor
public final class MemoryCollector {
    private struct Counters {
        var swapIns: UInt64
        var swapOuts: UInt64
        var pageIns: UInt64
        var pageOuts: UInt64
    }

    private let pageSize = MachHost.pageSize
    private let totalMemory = ProcessInfo.processInfo.physicalMemory
    private var previous: Counters?
    private var previousTimestamp: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    /// Constructible from anywhere; every method that touches state is isolated.
    public nonisolated init() {}

    public func sample() -> MemoryStats {
        guard let vm = Self.vmStatistics() else {
            return MemoryStats(total: totalMemory, app: 0, wired: 0, compressed: 0,
                               cached: 0, free: totalMemory, swapUsed: 0, swapTotal: 0,
                               pressure: .low)
        }

        // `internal_page_count` is anonymous memory owned by processes; the
        // purgeable slice of it is reclaimable on demand, so Activity Monitor
        // subtracts it from "App Memory" and counts it as cache instead.
        let purgeable = UInt64(vm.purgeable_count) * pageSize
        let internalPages = UInt64(vm.internal_page_count) * pageSize
        let app = internalPages > purgeable ? internalPages - purgeable : 0
        let wired = UInt64(vm.wire_count) * pageSize
        let compressed = UInt64(vm.compressor_page_count) * pageSize
        let external = UInt64(vm.external_page_count) * pageSize
        let cached = external + purgeable
        let free = UInt64(vm.free_count &- vm.speculative_count) * pageSize

        let swap = Self.swapUsage()

        // These kernel counters only ever increase; the interesting figure is
        // the rate, so it is derived from the delta between two samples.
        let counters = Counters(swapIns: vm.swapins, swapOuts: vm.swapouts,
                                pageIns: vm.pageins, pageOuts: vm.pageouts)
        let now = clock.now
        var swapInRate = 0.0, swapOutRate = 0.0, pageInRate = 0.0, pageOutRate = 0.0
        if let old = previous, let previousTimestamp {
            let duration = now - previousTimestamp
            let elapsed = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
            if elapsed > 0.05 {
                swapInRate = Double(counters.swapIns &- old.swapIns) * Double(pageSize) / elapsed
                swapOutRate = Double(counters.swapOuts &- old.swapOuts) * Double(pageSize) / elapsed
                pageInRate = Double(counters.pageIns &- old.pageIns) / elapsed
                pageOutRate = Double(counters.pageOuts &- old.pageOuts) / elapsed
            }
        }
        previous = counters
        previousTimestamp = now

        let ratio = vm.compressor_page_count > 0
            ? Double(vm.total_uncompressed_pages_in_compressor) / Double(vm.compressor_page_count)
            : 0

        return MemoryStats(
            total: totalMemory,
            app: app,
            wired: wired,
            compressed: compressed,
            cached: cached,
            free: free,
            swapUsed: swap?.xsu_used ?? 0,
            swapTotal: swap?.xsu_total ?? 0,
            pressure: Self.pressure(compressed: compressed, wired: wired, total: totalMemory),
            swapInRate: max(0, swapInRate),
            swapOutRate: max(0, swapOutRate),
            pageInRate: max(0, pageInRate),
            pageOutRate: max(0, pageOutRate),
            compressionRatio: ratio
        )
    }

    private static func vmStatistics() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(MachHost.host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            Log.metrics.error("host_statistics64(HOST_VM_INFO64) failed: \(result)")
            return nil
        }
        return stats
    }

    private static func swapUsage() -> xsw_usage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage
    }

    /// The kernel publishes its own pressure level; that is the number the OS
    /// acts on, so it beats any ratio we could invent. If the sysctl is
    /// unavailable we fall back to the share of RAM that is wired or compressed,
    /// which is what actually forces the kernel to start swapping.
    private static func pressure(compressed: UInt64, wired: UInt64, total: UInt64) -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.stride
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0,
           let pressure = MemoryPressure(rawValue: Int(level)) {
            return pressure
        }
        return derivedPressure(compressed: compressed, wired: wired, total: total)
    }

    /// Fallback used only when the kernel's own pressure level is unreadable.
    /// Wired and compressed pages are the ones the kernel cannot simply drop,
    /// so their share of RAM is what forces swapping.
    nonisolated static func derivedPressure(compressed: UInt64, wired: UInt64, total: UInt64) -> MemoryPressure {
        guard total > 0 else { return .low }
        let ratio = Double(compressed &+ wired) / Double(total)
        switch ratio {
        case ..<0.55: return .low
        case ..<0.80: return .moderate
        default: return .high
        }
    }
}
