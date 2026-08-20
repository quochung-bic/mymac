import Darwin
import Foundation

/// Enumerates processes with `sysctl(KERN_PROC_ALL)` and reads per-process CPU
/// time and memory footprint with `proc_pid_rusage`.
///
/// `ri_phys_footprint` is the same number Activity Monitor shows as "Memory",
/// which is why it is preferred over resident size.
///
/// Without additional privileges the kernel refuses `proc_pid_rusage` for
/// processes owned by another user (typically root daemons). Those rows are
/// still listed, with `nil` statistics, instead of being silently dropped or
/// filled with zeros.
@MetricsActor
public final class ProcessCollector {
    private struct CPUTimeSample {
        /// Mach absolute time ticks, not nanoseconds — see `cpuSeconds`.
        var totalTicks: UInt64
        var timestamp: ContinuousClock.Instant
    }

    /// `proc_pid_rusage` reports CPU time in mach absolute time units, despite
    /// the field names suggesting otherwise. On Intel a tick happens to be one
    /// nanosecond, which hides the mistake; on Apple Silicon a tick is 41.67 ns,
    /// so treating ticks as nanoseconds under-reports every process by 24x.
    private nonisolated static func cpuSeconds(ticks: UInt64) -> Double {
        Double(ticks) * MachHost.machTicksToNanoseconds / 1e9
    }

    private var previous: [pid_t: CPUTimeSample] = [:]
    private var nameCache: [pid_t: String] = [:]
    private let clock = ContinuousClock()
    private let currentUID = getuid()

    /// Constructible from anywhere; every method that touches state is isolated.
    public nonisolated init() {}

    /// - Parameter applicationNames: PID → localized name for GUI applications,
    ///   gathered from `NSWorkspace` on the main actor. Passing it in keeps
    ///   AppKit out of this collector entirely.
    public func sample(applicationNames: [pid_t: String] = [:]) -> [ProcessSample] {
        let processes = Self.listProcesses()
        guard !processes.isEmpty else { return [] }

        let now = clock.now
        // Read once, not once per process: this is a sysctl, and the loop below
        // runs across every process on the machine.
        let coreCount = Double(ProcessInfo.processInfo.activeProcessorCount)
        var samples: [ProcessSample] = []
        samples.reserveCapacity(processes.count)
        var seen = Set<pid_t>()
        var nextPrevious: [pid_t: CPUTimeSample] = [:]
        nextPrevious.reserveCapacity(processes.count)

        for entry in processes {
            let pid = entry.kp_proc.p_pid
            guard pid > 0 else { continue }
            seen.insert(pid)

            let uid = entry.kp_eproc.e_ucred.cr_uid
            let name = applicationNames[pid] ?? cachedName(for: pid, fallback: entry)
            let kind: ProcessSample.Kind = applicationNames[pid] != nil
                ? .application
                : (uid == 0 ? .system : .background)

            var cpuUsage: Double?
            var footprint: UInt64?

            if let usage = Self.resourceUsage(pid: pid) {
                let total = usage.ri_user_time &+ usage.ri_system_time
                footprint = usage.ri_phys_footprint
                nextPrevious[pid] = CPUTimeSample(totalTicks: total, timestamp: now)

                if let old = previous[pid] {
                    let duration = now - old.timestamp
                    let elapsed = Double(duration.components.seconds)
                        + Double(duration.components.attoseconds) / 1e18
                    if elapsed > 0.05, total >= old.totalTicks {
                        cpuUsage = Self.cpuSeconds(ticks: total - old.totalTicks) / elapsed
                    }
                } else if let lifetime = Self.lifetimeSeconds(usage: usage), lifetime > 0.5 {
                    // First time we see this process: its average CPU use over
                    // its whole life is a fair answer, and beats showing nothing.
                    cpuUsage = Self.cpuSeconds(ticks: total) / lifetime
                }
            } else if uid == currentUID {
                // Our own process disappeared between the listing and the read.
                continue
            }

            samples.append(ProcessSample(
                id: pid,
                name: name,
                kind: kind,
                cpuUsage: cpuUsage.map { min(coreCount, max(0, $0)) },
                memoryFootprint: footprint,
                isResponding: true
            ))
        }

        previous = nextPrevious
        nameCache = nameCache.filter { seen.contains($0.key) }
        return samples
    }

    private func cachedName(for pid: pid_t, fallback entry: kinfo_proc) -> String {
        if let cached = nameCache[pid] { return cached }
        let resolved = Self.executableName(pid: pid) ?? Self.shortName(from: entry)
        nameCache[pid] = resolved
        return resolved
    }

    /// `p_comm` is truncated to 16 bytes by the kernel, so the executable path
    /// is tried first and this is only the fallback.
    private nonisolated static func shortName(from entry: kinfo_proc) -> String {
        var comm = entry.kp_proc.p_comm
        return withUnsafeBytes(of: &comm) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return bytes.isEmpty ? "Unknown" : String(decoding: bytes, as: UTF8.self)
        }
    }

    private nonisolated static func executableName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        guard !path.isEmpty else { return nil }

        // ".../Foo.app/Contents/MacOS/Foo" reads better as "Foo".
        let url = URL(fileURLWithPath: path)
        if let appIndex = url.pathComponents.lastIndex(where: { $0.hasSuffix(".app") }) {
            return String(url.pathComponents[appIndex].dropLast(4))
        }
        return url.lastPathComponent
    }

    private nonisolated static func resourceUsage(pid: pid_t) -> rusage_info_current? {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        return result == 0 ? usage : nil
    }

    private nonisolated static func lifetimeSeconds(usage: rusage_info_current) -> Double? {
        guard usage.ri_proc_start_abstime > 0 else { return nil }
        let elapsedTicks = mach_absolute_time() &- usage.ri_proc_start_abstime
        let nanoseconds = Double(elapsedTicks) * MachHost.machTicksToNanoseconds
        return nanoseconds / 1e9
    }

    private nonisolated static func listProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        // The table can grow between sizing and reading; ask for some slack and
        // retry once rather than truncating the list.
        for _ in 0..<2 {
            let capacity = size / MemoryLayout<kinfo_proc>.stride + 16
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var length = capacity * MemoryLayout<kinfo_proc>.stride
            let result = buffer.withUnsafeMutableBytes { raw in
                sysctl(&mib, u_int(mib.count), raw.baseAddress, &length, nil, 0)
            }
            if result == 0 {
                return Array(buffer.prefix(length / MemoryLayout<kinfo_proc>.stride))
            }
            guard errno == ENOMEM else { break }
            size = length
        }
        Log.metrics.error("sysctl(KERN_PROC_ALL) failed: \(String(cString: strerror(errno)))")
        return []
    }
}
