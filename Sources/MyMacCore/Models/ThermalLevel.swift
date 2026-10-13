import Foundation

/// macOS's own verdict on whether the machine is being held back by heat.
///
/// This is the system's judgement, not a temperature: it is the same on Intel
/// and Apple Silicon, needs no SMC access, and is what actually explains a Mac
/// that has slowed down.
public enum ThermalLevel: Int, Sendable, Comparable, CaseIterable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Critical"
        }
    }

    public var explanation: String {
        switch self {
        case .nominal:
            "Thermal state: Normal. The Mac is running at full speed."
        case .fair:
            "Thermal state: Warm. The Mac is warmer than usual; fans may be spinning up. Performance is not yet reduced."
        case .serious:
            "Thermal state: Hot. macOS is slowing the processor to cool down. Quitting heavy apps or moving to a cooler spot helps."
        case .critical:
            "Thermal state: Critical. Performance is heavily reduced to protect the hardware. Stop heavy work and let the Mac cool."
        }
    }
}
