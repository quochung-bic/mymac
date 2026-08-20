import Foundation

public enum Format {
    /// Base-10 byte sizes, matching Finder and the rest of macOS.
    /// `ByteCountFormatStyle` is a `Sendable` value type, unlike the older
    /// `ByteCountFormatter` object.
    public static func bytes(_ value: Int64) -> String {
        max(0, value).formatted(.byteCount(style: .file, spellsOutZero: false))
    }

    public static func bytes(_ value: UInt64) -> String {
        bytes(Int64(clamping: value))
    }

    public static func throughput(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 1 else { return "0 KB/s" }
        return bytes(Int64(bytesPerSecond)) + "/s"
    }

    /// Percentages are shown without decimals; the underlying signal is noisier
    /// than one tenth of a percent, so extra digits would only imply precision.
    public static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "—" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// Per-process CPU, which is usually a fraction of a percent. Rounding it
    /// to whole numbers turns the whole column into zeros, so small values keep
    /// one decimal and large ones drop it.
    public static func processCPU(_ fraction: Double) -> String {
        guard fraction.isFinite, fraction >= 0 else { return "—" }
        let percent = fraction * 100
        if percent >= 10 { return "\(Int(percent.rounded()))%" }
        if percent < 0.05 { return "0%" }
        return String(format: "%.1f%%", percent)
    }

    public static func duration(_ minutes: Int) -> String {
        guard minutes > 0 else { return "—" }
        let hours = minutes / 60
        let mins = minutes % 60
        if hours == 0 { return "\(mins) min" }
        if mins == 0 { return "\(hours) hr" }
        return "\(hours) hr \(mins) min"
    }

    public static func relativeAge(_ date: Date?, reference: Date = Date()) -> String {
        guard let date else { return "—" }
        let days = Int(reference.timeIntervalSince(date) / 86_400)
        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case 2..<30: return "\(days) days ago"
        case 30..<365: return "\(days / 30) months ago"
        default: return "\(days / 365) years ago"
        }
    }
}
