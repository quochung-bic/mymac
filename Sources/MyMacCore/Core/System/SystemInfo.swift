import Darwin
import Foundation

/// Facts about the machine that never change while it is running.
///
/// Read once at launch: a chip name and a core count are not worth a syscall
/// every second.
public struct SystemInfo: Sendable {
    public let chip: String
    public let model: String
    public let physicalCores: Int
    public let logicalCores: Int
    /// Apple Silicon reports its core clusters as "performance levels".
    /// Both are zero on Intel, where every core is the same.
    public let performanceCores: Int
    public let efficiencyCores: Int
    public let physicalMemory: UInt64
    public let bootTime: Date
    public let operatingSystem: String

    public var uptime: TimeInterval { max(0, Date().timeIntervalSince(bootTime)) }

    public var coreSummary: String {
        guard performanceCores > 0, efficiencyCores > 0 else { return "\(logicalCores) cores" }
        return "\(performanceCores)P + \(efficiencyCores)E"
    }

    public static let current = SystemInfo()

    public init() {
        chip = Sysctl.string("machdep.cpu.brand_string") ?? "Unknown"
        model = Sysctl.string("hw.model") ?? "Mac"
        physicalCores = Int(Sysctl.integer("hw.physicalcpu") ?? 0)
        logicalCores = Int(Sysctl.integer("hw.logicalcpu") ?? 0)
        performanceCores = Int(Sysctl.integer("hw.perflevel0.logicalcpu") ?? 0)
        efficiencyCores = Int(Sysctl.integer("hw.perflevel1.logicalcpu") ?? 0)
        physicalMemory = ProcessInfo.processInfo.physicalMemory
        bootTime = Sysctl.bootTime() ?? Date()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        operatingSystem = "macOS \(version.majorVersion).\(version.minorVersion)"
    }
}

/// Thin, typed wrappers around `sysctlbyname`.
public enum Sysctl {
    public static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let value = String(decoding: bytes, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    /// Handles both 32- and 64-bit sysctls, which are not distinguishable by
    /// name alone.
    public static func integer(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.stride
        if sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int64>.stride {
            return value
        }
        var narrow: Int32 = 0
        var narrowSize = MemoryLayout<Int32>.stride
        guard sysctlbyname(name, &narrow, &narrowSize, nil, 0) == 0 else { return nil }
        return Int64(narrow)
    }

    public static func bootTime() -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value.tv_sec))
    }
}

extension Format {
    /// Uptime reads better in the largest two units that apply.
    public static func uptime(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    public static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    public static func rate(_ perSecond: Double, unit: String) -> String {
        guard perSecond.isFinite, perSecond >= 0.5 else { return "0 \(unit)" }
        return "\(Int(perSecond.rounded()).formatted(.number.grouping(.automatic))) \(unit)"
    }
}
